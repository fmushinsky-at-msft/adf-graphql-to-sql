<#
.SYNOPSIS
	Deploys the Azure Data Factory linked services, datasets and pipeline in this repository.

.DESCRIPTION
	Each file under adf\ is in the same shape that Azure Data Factory Studio exports
	({ "name": ..., "properties": ... }). This script PUTs the "properties" object to the
	Data Factory management API, which is the most faithful way to deploy those artifacts.

	Artifacts are deployed in dependency order: linked services, then datasets, then pipelines.

.EXAMPLE
	.\Deploy-Adf.ps1
#>
[CmdletBinding()]
param(
	[string] $SubscriptionId = '19c0c420-bf90-4cb3-80cf-6479a48dd6a3',
	[string] $ResourceGroup  = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $FactoryName    = 'nyc-dohmh-adf-graphql-to-sql',
	[string] $ApiVersion     = '2018-06-01'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$adfRoot  = Join-Path $repoRoot 'adf'
$tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) "adf-deploy-$([Guid]::NewGuid().ToString('N'))"

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

function Publish-AdfArtifact {
	param(
		[string] $Kind,          # linkedservices | datasets | pipelines
		[string] $DisplayKind,
		[string] $FilePath
	)

	$artifact = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
	$name = $artifact.name
	if ([string]::IsNullOrWhiteSpace($name)) {
		$name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
	}

	# The management API expects only the properties object; the name comes from the URL.
	$payloadPath = Join-Path $tempDir "$name.json"
	@{ properties = $artifact.properties } |
		ConvertTo-Json -Depth 100 -Compress |
		Set-Content -Path $payloadPath -Encoding utf8 -NoNewline

	$url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
		   "/providers/Microsoft.DataFactory/factories/$FactoryName/$Kind/$name" +
		   "?api-version=$ApiVersion"

	Write-Host "  $DisplayKind : $name" -ForegroundColor Gray

	# management.azure.com intermittently fails to resolve or refuses connections from this
	# network, which would otherwise abort a deployment half-finished. Retry transient failures.
	$maxAttempts = 6
	for ($attempt = 1; ; $attempt++) {
		$result = az rest --method put --url $url --headers "Content-Type=application/json" --body "@$payloadPath" 2>&1
		if ($LASTEXITCODE -eq 0) { return }

		$text = $result | Out-String
		$isTransient = $text -match 'getaddrinfo failed|NameResolutionError|Max retries exceeded|ConnectionError|Connection aborted|timed out|ServiceUnavailable|BadGateway|\b50[0234]\b'

		if (-not $isTransient -or $attempt -ge $maxAttempts) {
			Write-Host $text -ForegroundColor Red
			throw "Failed to deploy $DisplayKind '$name'."
		}

		$delay = [Math]::Min(30, $attempt * 5)
		Write-Host "    attempt $attempt failed (transient); retrying in ${delay}s..." -ForegroundColor DarkYellow
		Start-Sleep -Seconds $delay
	}
}

Write-Host "Deploying Data Factory artifacts to '$FactoryName'..." -ForegroundColor Cyan

Write-Host 'Linked services' -ForegroundColor Cyan
Get-ChildItem -Path (Join-Path $adfRoot 'linkedService') -Filter *.json |
	ForEach-Object { Publish-AdfArtifact -Kind 'linkedservices' -DisplayKind 'linked service' -FilePath $_.FullName }

Write-Host 'Datasets' -ForegroundColor Cyan
Get-ChildItem -Path (Join-Path $adfRoot 'dataset') -Filter *.json |
	ForEach-Object { Publish-AdfArtifact -Kind 'datasets' -DisplayKind 'dataset' -FilePath $_.FullName }

Write-Host 'Pipelines' -ForegroundColor Cyan
Get-ChildItem -Path (Join-Path $adfRoot 'pipeline') -Filter *.json |
	ForEach-Object { Publish-AdfArtifact -Kind 'pipelines' -DisplayKind 'pipeline' -FilePath $_.FullName }

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Data Factory deployment complete.' -ForegroundColor Green
