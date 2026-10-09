<#
.SYNOPSIS
	Runs the full test suite for the incremental GraphQL -> Azure SQL sync.

.DESCRIPTION
	Exercises every behaviour the pipeline is supposed to have, asserting the result of each
	stage and cleaning the destination up afterwards:

	  1. Full load        - empty destination, expect all source rows inserted.
	  2. Idempotent re-run - nothing changed at the source, expect the delta read to return
							 zero rows and nothing to be written. This is the regression test
							 for watermark precision: if a single millisecond is lost anywhere
							 the newest row is re-read on every run.
	  3. Incremental change - 3 rows updated and 2 inserted at the source; expect
							 exactly 2 inserted / 3 updated. The source never deletes rows,
							 so there is no delete scenario.

	After every pipeline run the destination is fingerprinted against the source
	(SHA2-256 over all columns, including millisecond timestamps) so "it ran" is never
	mistaken for "it is correct".

	The source table and the destination table are both restored at the end.

.EXAMPLE
	.\Test-EndToEnd.ps1

.EXAMPLE
	.\Test-EndToEnd.ps1 -KeepSourceChanges
#>
[CmdletBinding()]
param(
	[string] $SourceDatabase      = 'nyc-dohmh-adf-graphql-to-sql-1',
	[string] $DestinationDatabase = 'nyc-dohmh-adf-graphql-to-sql-2',

	# Leaves the mutated source data in place, for manual inspection after the run.
	[switch] $KeepSourceChanges
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sql  = Join-Path (Split-Path -Parent $here) 'sql'

$failures = [System.Collections.Generic.List[string]]::new()

function Write-Stage {
	param([string] $Text)
	Write-Host ''
	Write-Host ('=' * 78) -ForegroundColor DarkCyan
	Write-Host "  $Text" -ForegroundColor Cyan
	Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Assert-Value {
	param(
		[string] $What,
		$Expected,
		$Actual
	)

	if ($Expected -eq $Actual) {
		Write-Host ("  PASS  {0,-22} = {1}" -f $What, $Actual) -ForegroundColor Green
	}
	else {
		Write-Host ("  FAIL  {0,-22} = {1}  (expected {2})" -f $What, $Actual, $Expected) -ForegroundColor Red
		$failures.Add("$What was $Actual, expected $Expected")
	}
}

function Assert-Integrity {
	& (Join-Path $here 'Test-SyncIntegrity.ps1') `
		-SourceDatabase $SourceDatabase `
		-DestinationDatabase $DestinationDatabase

	if ($LASTEXITCODE -eq 0) {
		Write-Host '  PASS  integrity             = destination matches source' -ForegroundColor Green
	}
	else {
		Write-Host '  FAIL  integrity             = destination does NOT match source' -ForegroundColor Red
		$failures.Add('Destination did not match the source.')
	}
}

function Invoke-Sync {
	& (Join-Path $here 'Invoke-PipelineRun.ps1') | Select-Object -Last 1
}

function Reset-Destination {
	& (Join-Path $here 'Reset-Destination.ps1') -Database $DestinationDatabase | Out-Null
}

function Invoke-Sql {
	param([string] $Database, [string] $Path)
	& (Join-Path $here 'Invoke-SqlScript.ps1') -Database $Database -Path $Path | Out-Null
}

# --------------------------------------------------------------------------- test 1 --
Write-Stage 'TEST 1 - full load into an empty destination'
Reset-Destination
$run = Invoke-Sync
Assert-Value -What 'rows inserted'  -Expected 75 -Actual $run.RowsInserted
Assert-Value -What 'rows updated'   -Expected 0  -Actual $run.RowsUpdated
Assert-Value -What 'destination rows' -Expected 75 -Actual $run.TargetRowCount
Assert-Value -What 'delta rows read' -Expected 75 -Actual $run.DeltaRowsRead
Assert-Integrity

# --------------------------------------------------------------------------- test 2 --
Write-Stage 'TEST 2 - re-run with no source changes (must be a true no-op)'
$run = Invoke-Sync
Assert-Value -What 'delta rows read' -Expected 0 -Actual $run.DeltaRowsRead
Assert-Value -What 'rows inserted'  -Expected 0  -Actual $run.RowsInserted
Assert-Value -What 'rows updated'   -Expected 0  -Actual $run.RowsUpdated
Assert-Value -What 'destination rows' -Expected 75 -Actual $run.TargetRowCount
Assert-Integrity

# --------------------------------------------------------------------------- test 3 --
Write-Stage 'TEST 3 - incremental change: 3 updated, 2 inserted'
Invoke-Sql -Database $SourceDatabase -Path (Join-Path $sql '05-source-changes.sql')
$run = Invoke-Sync
Assert-Value -What 'rows inserted'  -Expected 2 -Actual $run.RowsInserted
Assert-Value -What 'rows updated'   -Expected 3 -Actual $run.RowsUpdated
Assert-Value -What 'destination rows' -Expected 77 -Actual $run.TargetRowCount
Assert-Value -What 'delta rows read' -Expected 5 -Actual $run.DeltaRowsRead
Assert-Integrity

# ----------------------------------------------------------------------------- tidy --
if (-not $KeepSourceChanges) {
	Write-Stage 'CLEANUP - restoring the source table and emptying the destination'
	Invoke-Sql -Database $SourceDatabase -Path (Join-Path $sql '01-source-schema.sql')
	Reset-Destination
	Write-Host '  source restored to 75 rows; destination emptied and watermark rewound.' -ForegroundColor Gray
}

Write-Stage 'RESULT'
if ($failures.Count -eq 0) {
	Write-Host '  ALL TESTS PASSED' -ForegroundColor Green
	exit 0
}

Write-Host "  $($failures.Count) FAILURE(S)" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
exit 1
