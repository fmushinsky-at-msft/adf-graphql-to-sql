<#
.SYNOPSIS
	Executes a T-SQL script (or inline query) against an Azure SQL database using the
	signed-in Azure CLI identity (Microsoft Entra authentication).

.DESCRIPTION
	The demo databases are serverless with auto-pause enabled, so the first connection after
	an idle period fails with a transient "database is not currently available" error while the
	database resumes. This helper retries those transient failures automatically.

.EXAMPLE
	.\Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-1' -Path ..\sql\01-source-schema.sql

.EXAMPLE
	.\Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-2' -Query 'SELECT COUNT(*) FROM dbo.Restaurant;'
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
	[Parameter(Mandatory)]
	[string] $Database,

	[Parameter(Mandatory, ParameterSetName = 'File')]
	[string] $Path,

	[Parameter(Mandatory, ParameterSetName = 'Query')]
	[string] $Query,

	[string] $Server = 'nyc-dohmh-adf-graphql-to-sql.database.windows.net',

	[int] $CommandTimeout = 180,

	[int] $MaxAttempts = 12
)

$ErrorActionPreference = 'Stop'

# Transient Azure SQL error numbers. 40613 is the one raised while a serverless database resumes.
$transientErrorNumbers = @(40613, 40501, 40197, 49918, 49919, 49920, 4060, 10928, 10929, 11001, 233, -2)

function Get-SqlAccessToken {
	$token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
		throw 'Unable to acquire a Microsoft Entra access token. Run "az login" first.'
	}
	return $token
}

function Split-SqlBatches {
	param([string] $Script)

	$batches = [System.Collections.Generic.List[string]]::new()
	$current = [System.Text.StringBuilder]::new()

	foreach ($line in ($Script -split "`r?`n")) {
		if ($line.Trim() -match '^GO(\s+\d+)?$') {
			$batches.Add($current.ToString())
			$current = [System.Text.StringBuilder]::new()
		}
		else {
			[void]$current.AppendLine($line)
		}
	}
	$batches.Add($current.ToString())

	return $batches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Invoke-Batch {
	param(
		[string] $Sql,
		[string] $AccessToken
	)

	$connectionString = "Server=tcp:$Server,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"
	$connection = New-Object System.Data.SqlClient.SqlConnection
	$connection.ConnectionString = $connectionString
	$connection.AccessToken = $AccessToken

	try {
		$connection.Open()

		$command = $connection.CreateCommand()
		$command.CommandText = $Sql
		$command.CommandTimeout = $CommandTimeout

		# SqlDataAdapter fills every result set in one go. DataTable.Load() advances the reader
		# itself, which makes manual NextResult() loops silently skip result sets.
		$adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
		$dataSet = New-Object System.Data.DataSet
		[void]$adapter.Fill($dataSet)

		foreach ($table in $dataSet.Tables) {
			if ($table.Rows.Count -gt 0) {
				$table | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
			}
		}
	}
	finally {
		$connection.Dispose()
	}
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
	$resolved = Resolve-Path -Path $Path
	$script = Get-Content -Path $resolved -Raw
	Write-Host "Executing '$resolved' against [$Database]..." -ForegroundColor Cyan
}
else {
	$script = $Query
	Write-Host "Executing inline query against [$Database]..." -ForegroundColor Cyan
}

$batches = @(Split-SqlBatches -Script $script)
$token = Get-SqlAccessToken

for ($i = 0; $i -lt $batches.Count; $i++) {
	$batch = $batches[$i]
	$attempt = 0

	while ($true) {
		$attempt++
		try {
			Invoke-Batch -Sql $batch -AccessToken $token
			break
		}
		catch {
			$sqlException = $_.Exception
			while ($sqlException -and -not ($sqlException -is [System.Data.SqlClient.SqlException])) {
				$sqlException = $sqlException.InnerException
			}

			$number = if ($sqlException) { $sqlException.Number } else { 0 }
			$isTransient = $transientErrorNumbers -contains $number

			if (-not $isTransient -or $attempt -ge $MaxAttempts) {
				Write-Host "Batch $($i + 1) of $($batches.Count) failed." -ForegroundColor Red
				throw
			}

			$delay = [Math]::Min(30, 5 * $attempt)
			Write-Host "  Transient error $number (attempt $attempt/$MaxAttempts). The serverless database may be resuming. Retrying in ${delay}s..." -ForegroundColor Yellow
			Start-Sleep -Seconds $delay
			$token = Get-SqlAccessToken
		}
	}
}

Write-Host "Completed $($batches.Count) batch(es) against [$Database]." -ForegroundColor Green
