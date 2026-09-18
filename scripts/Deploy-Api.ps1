<#
.SYNOPSIS
	Publishes the GraphQL API and deploys it to the REST API App Service.

.DESCRIPTION
	Configures the App Service for .NET 10 (64-bit, Always On, HTTPS only), sets the
	managed-identity based connection string to the source database, then performs a
	zip deployment of a Release publish output.

.EXAMPLE
	.\Deploy-Api.ps1
#>
[CmdletBinding()]
param(
	[string] $ResourceGroup = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $WebAppName    = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $SqlServerFqdn = 'nyc-dohmh-adf-graphql-to-sql.database.windows.net',
	[string] $SourceDatabase = 'nyc-dohmh-adf-graphql-to-sql-1',
	[switch] $SkipConfig
)

$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot 'src\GraphQlApi\NycDohmh.GraphQlApi.csproj'
$publishDir  = Join-Path $repoRoot 'artifacts\publish'
$zipPath     = Join-Path $repoRoot 'artifacts\NycDohmh.GraphQlApi.zip'

if (-not $SkipConfig) {
	Write-Host 'Configuring App Service...' -ForegroundColor Cyan

	# The API authenticates to Azure SQL with the App Service system-assigned managed identity.
	# No password or secret is ever stored in configuration.
	$connectionString = "Server=tcp:$SqlServerFqdn,1433;Database=$SourceDatabase;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connect Timeout=60;"

	az webapp config connection-string set `
		--resource-group $ResourceGroup `
		--name $WebAppName `
		--connection-string-type SQLAzure `
		--settings "SourceDatabase=$connectionString" `
		--output none
	if ($LASTEXITCODE -ne 0) { throw 'Failed to set the connection string.' }

	az webapp config set `
		--resource-group $ResourceGroup `
		--name $WebAppName `
		--net-framework-version 'v10.0' `
		--use-32bit-worker-process false `
		--always-on true `
		--http20-enabled true `
		--min-tls-version '1.2' `
		--output none
	if ($LASTEXITCODE -ne 0) { throw 'Failed to update the site configuration.' }

	az webapp update `
		--resource-group $ResourceGroup `
		--name $WebAppName `
		--https-only true `
		--output none
	if ($LASTEXITCODE -ne 0) { throw 'Failed to enforce HTTPS only.' }
}

Write-Host 'Publishing...' -ForegroundColor Cyan
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
dotnet publish $projectPath -c Release -o $publishDir --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

Write-Host 'Packaging...' -ForegroundColor Cyan
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -Force -WarningAction SilentlyContinue

Write-Host 'Deploying...' -ForegroundColor Cyan
# Kudu occasionally drops the upload; a retry is cheaper than re-running the whole script.
for ($attempt = 1; $attempt -le 4; $attempt++) {
	az webapp deploy `
		--resource-group $ResourceGroup `
		--name $WebAppName `
		--src-path $zipPath `
		--type zip `
		--output none

	if ($LASTEXITCODE -eq 0) { break }
	if ($attempt -eq 4) { throw 'Zip deployment failed.' }

	Write-Host "  deploy attempt $attempt failed; retrying..." -ForegroundColor Yellow
	Start-Sleep -Seconds 20
}

$hostName = az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName -o tsv
Write-Host "Deployed. GraphQL endpoint: https://$hostName/graphql" -ForegroundColor Green
