<#
.SYNOPSIS
	Verifies that the destination table is an exact copy of the source table.

.DESCRIPTION
	Computes a SHA2-256 fingerprint over every row of demo.Restaurant in the source database and
	over dbo.Restaurant in the destination database, using an identical column list and an
	identical millisecond-precision timestamp format. If the two fingerprints match, the sync is
	byte-for-byte correct - including audit timestamps.

	Also reports any keys that are missing from, or extra in, the destination.

.EXAMPLE
	.\Test-SyncIntegrity.ps1
#>
[CmdletBinding()]
param(
	[string] $Server             = 'nyc-dohmh-adf-graphql-to-sql.database.windows.net',
	[string] $SourceDatabase     = 'nyc-dohmh-adf-graphql-to-sql-1',
	[string] $DestinationDatabase = 'nyc-dohmh-adf-graphql-to-sql-2'
)

$ErrorActionPreference = 'Stop'

$transientErrorNumbers = @(40613, 40501, 40197, 49918, 49919, 49920, 4060, 10928, 10929, 11001, 233, -2)

function Invoke-Scalar {
	param(
		[string] $Database,
		[string] $Sql
	)

	for ($attempt = 1; $attempt -le 10; $attempt++) {
		try {
			$token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
			$connection = New-Object System.Data.SqlClient.SqlConnection
			$connection.ConnectionString = "Server=tcp:$Server,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"
			$connection.AccessToken = $token
			$connection.Open()
			try {
				$command = $connection.CreateCommand()
				$command.CommandText = $Sql
				$command.CommandTimeout = 120

				$adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
				$table = New-Object System.Data.DataTable
				[void]$adapter.Fill($table)
				# The unary comma stops PowerShell from unrolling the DataTable into DataRows.
				return , $table
			}
			finally { $connection.Dispose() }
		}
		catch {
			$sqlException = $_.Exception
			while ($sqlException -and -not ($sqlException -is [System.Data.SqlClient.SqlException])) {
				$sqlException = $sqlException.InnerException
			}
			$number = if ($sqlException) { $sqlException.Number } else { 0 }
			if ($transientErrorNumbers -notcontains $number -or $attempt -ge 10) { throw }
			Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
		}
	}
}

# CONCAT_WS skips NULLs, so NULL markers are made explicit to avoid two different rows hashing
# to the same value. Timestamps use ISO-8601 style 126 to keep millisecond precision.
$projection = @'
		CONCAT_WS(N'|',
			RestaurantId,
			Name,
			Borough,
			Cuisine,
			ISNULL(InspectionGrade, N'<null>'),
			ISNULL(CONVERT(NVARCHAR(20), InspectionScore), N'<null>'),
			SeatingCapacity,
			CONVERT(TINYINT, IsActive),
			CONVERT(CHAR(23), CreateDateTime, 126),
			CONVERT(CHAR(23), LastUpdatedDateTime, 126))
'@

$fingerprintSql = @"
SELECT
	RowCountTotal = COUNT_BIG(1),
	Fingerprint   = CONVERT(CHAR(64), HASHBYTES('SHA2_256',
						STRING_AGG(CONVERT(NVARCHAR(MAX), $projection), N'~')
							WITHIN GROUP (ORDER BY RestaurantId)), 2)
FROM {0};
"@

$keysSql = 'SELECT RestaurantId FROM {0} ORDER BY RestaurantId;'

Write-Host 'Fingerprinting source...' -ForegroundColor Cyan
$source = Invoke-Scalar -Database $SourceDatabase -Sql ($fingerprintSql -f 'demo.Restaurant')

Write-Host 'Fingerprinting destination...' -ForegroundColor Cyan
$destination = Invoke-Scalar -Database $DestinationDatabase -Sql ($fingerprintSql -f 'dbo.Restaurant')

$sourceRows = [int]$source.Rows[0].RowCountTotal
$destRows   = [int]$destination.Rows[0].RowCountTotal
$sourceHash = [string]$source.Rows[0].Fingerprint
$destHash   = [string]$destination.Rows[0].Fingerprint

Write-Host ''
Write-Host ("  source      : {0,4} row(s)  {1}" -f $sourceRows, $sourceHash)
Write-Host ("  destination : {0,4} row(s)  {1}" -f $destRows, $destHash)
Write-Host ''

if ($sourceHash -eq $destHash -and $sourceRows -eq $destRows) {
	Write-Host 'MATCH - destination is an exact copy of the source.' -ForegroundColor Green
	exit 0
}

Write-Host 'MISMATCH - investigating key differences...' -ForegroundColor Red

$sourceKeys = (Invoke-Scalar -Database $SourceDatabase -Sql ($keysSql -f 'demo.Restaurant')).Rows | ForEach-Object { [int]$_.RestaurantId }
$destKeys   = (Invoke-Scalar -Database $DestinationDatabase -Sql ($keysSql -f 'dbo.Restaurant')).Rows | ForEach-Object { [int]$_.RestaurantId }

$missing = $sourceKeys | Where-Object { $destKeys -notcontains $_ }
$extra   = $destKeys   | Where-Object { $sourceKeys -notcontains $_ }

if ($missing) { Write-Host "  missing from destination : $($missing -join ', ')" -ForegroundColor Red }
if ($extra)   { Write-Host "  stale in destination     : $($extra -join ', ')"   -ForegroundColor Red }
if (-not $missing -and -not $extra) {
	Write-Host '  key sets match, so one or more column values differ.' -ForegroundColor Red
}

exit 1
