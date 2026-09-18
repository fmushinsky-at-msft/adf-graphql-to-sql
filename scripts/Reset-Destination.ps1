<#
.SYNOPSIS
	Empties the destination target table and rewinds the watermark.

.DESCRIPTION
	Calls etl.usp_ResetRestaurantTarget so the next pipeline run behaves like a first-time full
	load. Use this to clean up between test runs.

.EXAMPLE
	.\Reset-Destination.ps1
#>
[CmdletBinding()]
param(
	[string] $Database = 'nyc-dohmh-adf-graphql-to-sql-2'
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Invoke-SqlScript.ps1') -Database $Database -Query @'
EXEC etl.usp_ResetRestaurantTarget;

SELECT
	TargetRows      = (SELECT COUNT_BIG(1) FROM dbo.Restaurant),
	StagingRows     = (SELECT COUNT_BIG(1) FROM stg.Restaurant),
	StagingKeyRows  = (SELECT COUNT_BIG(1) FROM stg.RestaurantKey),
	WatermarkValue  = (SELECT CONVERT(CHAR(23), WatermarkValue, 126) FROM dbo.WatermarkControl WHERE TableName = N'demo.Restaurant');
'@

Write-Host 'Destination reset.' -ForegroundColor Green
