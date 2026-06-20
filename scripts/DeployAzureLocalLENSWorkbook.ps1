<#
.SYNOPSIS
Deploys the Azure Local LENS workbook to Azure Monitor.

.DESCRIPTION
This script performs the following operations:
1. Validates the workbook JSON file exists
2. Creates the resource group if it does not exist
3. If CapacityWorkbookResourceName is provided, performs a split deployment:
   a. Uses pre-split cache files from the Fetch step (LENS_MAIN_WORKBOOK_PATH /
      LENS_CAPACITY_WORKBOOK_PATH pipeline variables) when available, or splits
      the full workbook in-memory as a fallback
   b. Deploys the capacity child workbook first, then the main workbook
4. Otherwise deploys the workbook as a single resource (warns if payload is large)

.PARAMETER SubscriptionId
Azure subscription ID.

.PARAMETER ResourceGroupName
Resource group for workbook deployment.

.PARAMETER Location
Azure region (e.g. westeurope).

.PARAMETER WorkbookDisplayName
Human-readable display name shown inside the Azure Portal.

.PARAMETER WorkbookResourceName
Azure resource name for the main workbook.

.PARAMETER WorkbookSourceId
Workbook sourceId property. Defaults to /subscriptions/{SubscriptionId}.

.PARAMETER WorkbookJsonPath
Path to the full workbook JSON file (set by the Fetch step via LENS_WORKBOOK_PATH).

.PARAMETER CapacityWorkbookResourceName
When provided, the workbook is split into two resources to stay under the Azure Monitor
Workbooks API payload limit (~600 KB). The capacity tab content is deployed as an
independent child workbook with this resource name, and the main workbook's Capacity tab
opens it via a WorkbookTemplate link.

.EXAMPLE
& ".\DeployAzureLocalLENSWorkbook.ps1" `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -ResourceGroupName "rg-monitoring-shared" `
  -Location "westeurope" `
  -WorkbookDisplayName "Azure Local LENS Workbook" `
  -WorkbookResourceName "azure-local-lens-workbook" `
  -WorkbookJsonPath  "$(LENS_WORKBOOK_PATH)" `
  -CapacityWorkbookResourceName "azure-local-lens-workbook-capacity"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$WorkbookDisplayName,

    [Parameter(Mandatory = $true)]
    [string]$WorkbookResourceName,

    [Parameter(Mandatory = $false)]
    [string]$WorkbookSourceId,

    [Parameter(Mandatory = $true)]
    [string]$WorkbookJsonPath,

    # When provided, the workbook is split into two resources to stay under the
    # Azure Monitor Workbooks API payload limit (~600 KB).
    [Parameter(Mandatory = $false)]
    [string]$CapacityWorkbookResourceName
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Invoke-WorkbookDeploy.ps1"
. "$PSScriptRoot/Split-LENSWorkbook.ps1"

# ── Prerequisites ──────────────────────────────────────────────────────────────

if (-not (Test-Path -Path $WorkbookJsonPath -PathType Leaf)) {
    throw "Workbook JSON file was not found at '$WorkbookJsonPath'."
}

if ([string]::IsNullOrWhiteSpace($WorkbookSourceId)) {
    $WorkbookSourceId = "/subscriptions/$SubscriptionId"
}

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription context to '$SubscriptionId'."
}

$rgExists = az group exists --name $ResourceGroupName --subscription $SubscriptionId
if ($rgExists -eq "false") {
    Write-Host "Creating resource group '$ResourceGroupName' in location '$Location'..."
    az group create --name $ResourceGroupName --location $Location --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$ResourceGroupName'."
    }
}

# ── Deployment ─────────────────────────────────────────────────────────────────

$fullWorkbookJson = Get-Content -Path $WorkbookJsonPath -Raw
if ([string]::IsNullOrWhiteSpace($fullWorkbookJson)) {
    throw "Workbook JSON file '$WorkbookJsonPath' is empty."
}

if (-not [string]::IsNullOrWhiteSpace($CapacityWorkbookResourceName)) {
    # Resolve to GUID (same logic as Invoke-WorkbookDeploy) so the link target in the main
    # workbook matches the actual deployed resource name.
    $capacityGuidName = $CapacityWorkbookResourceName
    if (-not [System.Guid]::TryParse($CapacityWorkbookResourceName, [ref][System.Guid]::Empty)) {
        $bytes            = [System.Text.Encoding]::UTF8.GetBytes($CapacityWorkbookResourceName)
        $hash             = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $hex              = [System.BitConverter]::ToString($hash).Replace('-', '').ToLower()
        $capacityGuidName = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)
    }
    $capacityResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks/$capacityGuidName"

    # Prefer pre-split cache files produced by the Fetch step (avoids redundant JSON parsing).
    $preSplitMainPath     = $env:LENS_MAIN_WORKBOOK_PATH
    $preSplitCapacityPath = $env:LENS_CAPACITY_WORKBOOK_PATH
    $hasPreSplitFiles     = (
        -not [string]::IsNullOrWhiteSpace($preSplitMainPath)     -and (Test-Path $preSplitMainPath) -and
        -not [string]::IsNullOrWhiteSpace($preSplitCapacityPath) -and (Test-Path $preSplitCapacityPath)
    )

    if ($hasPreSplitFiles) {
        Write-Host "Using pre-split cache files from Fetch step."
        $mainWorkbookJson     = (Get-Content -Path $preSplitMainPath     -Raw) -replace 'LENS_CAPACITY_RESOURCE_ID_PLACEHOLDER', $capacityResourceId
        $capacityWorkbookJson =  Get-Content -Path $preSplitCapacityPath -Raw
    }
    else {
        Write-Host "Pre-split cache files not available. Splitting full workbook in-memory..."
        $split                = Split-LENSWorkbook -WorkbookJson $fullWorkbookJson -CapacityResourceId $capacityResourceId
        $mainWorkbookJson     = $split.MainJson
        $capacityWorkbookJson = $split.CapacityJson
    }

    Write-Host "Deploying capacity child workbook '$CapacityWorkbookResourceName'..."
    Invoke-WorkbookDeploy `
        -SubscriptionId    $SubscriptionId      -ResourceGroupName $ResourceGroupName `
        -Location          $Location            -DisplayName       "$WorkbookDisplayName - Capacity" `
        -ResourceName      $CapacityWorkbookResourceName           -SourceId $WorkbookSourceId `
        -SerializedData    $capacityWorkbookJson

    Write-Host "Deploying main workbook '$WorkbookResourceName'..."
    Invoke-WorkbookDeploy `
        -SubscriptionId    $SubscriptionId      -ResourceGroupName $ResourceGroupName `
        -Location          $Location            -DisplayName       $WorkbookDisplayName `
        -ResourceName      $WorkbookResourceName                   -SourceId $WorkbookSourceId `
        -SerializedData    $mainWorkbookJson
}
else {
    $sizeKB = [math]::Round($fullWorkbookJson.Length / 1KB, 1)
    if ($fullWorkbookJson.Length -gt 500000) {
        Write-Warning "Workbook is $sizeKB KB and may exceed the Azure Monitor Workbooks API payload limit. Set -CapacityWorkbookResourceName to enable split deployment."
    }

    Write-Host "Deploying workbook '$WorkbookResourceName' ($sizeKB KB)..."
    Invoke-WorkbookDeploy `
        -SubscriptionId    $SubscriptionId      -ResourceGroupName $ResourceGroupName `
        -Location          $Location            -DisplayName       $WorkbookDisplayName `
        -ResourceName      $WorkbookResourceName                   -SourceId $WorkbookSourceId `
        -SerializedData    $fullWorkbookJson
}
