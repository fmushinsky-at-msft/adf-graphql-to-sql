<#
.SYNOPSIS
	Triggers the incremental sync pipeline and waits for it to finish.

.DESCRIPTION
	Starts PL_Sync_Restaurants_GraphQL_To_Sql, polls until the run reaches a terminal state,
	then prints a per-activity summary plus the insert/update counts returned by
	etl.usp_ApplyRestaurantSync. The same counts are emitted as an object so callers can
	assert on them.

.EXAMPLE
	.\Invoke-PipelineRun.ps1
#>
[CmdletBinding()]
param(
	[string] $ResourceGroup = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $FactoryName   = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $PipelineName  = 'PL_Sync_Restaurants_GraphQL_To_Sql',
	[int]    $TimeoutMinutes = 25
)

$ErrorActionPreference = 'Stop'

<#
	The management endpoint intermittently drops connections ('Failed to establish a new
	connection', 'Connection reset by peer'). Every az call therefore goes through one retry
	helper - otherwise a healthy pipeline run gets reported as a failure.
#>
function Invoke-AzJson {
	param(
		[Parameter(Mandatory)][string[]] $Arguments,
		[string] $What      = 'Azure CLI call',
		[int]    $MaxAttempts = 6,
		[switch] $Raw
	)

	for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
		$output = & az @Arguments 2>$null

		if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
			if ($Raw) { return ($output | Select-Object -First 1) }
			try { return ($output | ConvertFrom-Json) } catch { }
		}

		if ($attempt -eq $MaxAttempts) { throw "$What failed after $MaxAttempts attempt(s)." }

		Write-Host "  $What attempt $attempt failed; retrying..." -ForegroundColor Yellow
		Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
	}
}

$startedAt = (Get-Date).ToUniversalTime().AddMinutes(-5)

Write-Host "Starting '$PipelineName'..." -ForegroundColor Cyan

$runId = Invoke-AzJson -Raw -What 'pipeline start' -Arguments @(
	'datafactory', 'pipeline', 'create-run',
	'--resource-group', $ResourceGroup,
	'--factory-name', $FactoryName,
	'--name', $PipelineName,
	'--query', 'runId', '-o', 'tsv')

Write-Host "Run id: $runId" -ForegroundColor Gray

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = 'Queued'

while ((Get-Date) -lt $deadline) {
	Start-Sleep -Seconds 15

	$run = Invoke-AzJson -What 'run status' -Arguments @(
		'datafactory', 'pipeline-run', 'show',
		'--resource-group', $ResourceGroup,
		'--factory-name', $FactoryName,
		'--run-id', $runId, '-o', 'json')

	$status = $run.status
	Write-Host "  status: $status" -ForegroundColor Gray

	if ($status -in @('Succeeded', 'Failed', 'Cancelled')) { break }
}

$finishedAt = (Get-Date).ToUniversalTime().AddMinutes(5)

Write-Host ''
Write-Host 'Activity summary' -ForegroundColor Cyan

$activities = Invoke-AzJson -What 'activity runs' -Arguments @(
	'datafactory', 'activity-run', 'query-by-pipeline-run',
	'--resource-group', $ResourceGroup,
	'--factory-name', $FactoryName,
	'--run-id', $runId,
	'--last-updated-after', $startedAt.ToString('o'),
	'--last-updated-before', $finishedAt.ToString('o'),
	'-o', 'json')

$activities.value |
	Sort-Object activityRunStart |
	ForEach-Object {
		[pscustomobject]@{
			Activity = $_.activityName
			Type     = $_.activityType
			Status   = $_.status
			Rows     = if ($null -ne $_.output.rowsCopied) { $_.output.rowsCopied } else { '' }
		}
	} | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$failed = $activities.value | Where-Object { $_.status -eq 'Failed' }
foreach ($f in $failed) {
	Write-Host "FAILED: $($f.activityName)" -ForegroundColor Red
	Write-Host ($f.error | ConvertTo-Json -Depth 6) -ForegroundColor Red
}

$apply = $activities.value |
	Where-Object { $_.activityName -eq 'ApplySync' -and $null -ne $_.output.firstRow } |
	Sort-Object activityRunEnd |
	Select-Object -Last 1

if ($apply) {
	Write-Host 'Merge result' -ForegroundColor Cyan
	$apply.output.firstRow | Format-List | Out-String | Write-Host
}

if ($status -ne 'Succeeded') { throw "Pipeline run finished with status '$status'." }
if (-not $apply) { throw 'The run succeeded but no ApplySync result was returned; the activity log is incomplete.' }

Write-Host "Pipeline run succeeded." -ForegroundColor Green

$deltaRows = $activities.value |
	Where-Object { $_.activityName -eq 'CopyDeltaPage' -and $_.status -eq 'Succeeded' } |
	Measure-Object -Property { $_.output.rowsCopied } -Sum

[pscustomobject]@{
	RunId          = $runId
	Status         = $status
	RowsInserted   = [int] $apply.output.firstRow.RowsInserted
	RowsUpdated    = [int] $apply.output.firstRow.RowsUpdated
	TargetRowCount = [int] $apply.output.firstRow.TargetRowCount
	NewWatermark   = [string] $apply.output.firstRow.NewWatermark
	DeltaRowsRead  = [int] $deltaRows.Sum
}
