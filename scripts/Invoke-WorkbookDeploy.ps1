<#
.SYNOPSIS
Deploys an Azure Monitor Workbook via the Azure REST API.

.DESCRIPTION
Wraps the az rest PUT call for a Microsoft.Insights/workbooks resource.
Caller must already be authenticated and have the correct subscription set.

.PARAMETER SubscriptionId
Azure subscription ID.

.PARAMETER ResourceGroupName
Resource group to deploy the workbook into.

.PARAMETER Location
Azure region (e.g. westeurope).

.PARAMETER DisplayName
Human-readable display name shown inside the Azure Portal.

.PARAMETER ResourceName
Azure resource name for the workbook (used as the resource ID segment).

.PARAMETER SourceId
Workbook sourceId property. Typically /subscriptions/{id} or a resource ID.

.PARAMETER SerializedData
The workbook JSON content (serialized workbook definition string).
#>
function Invoke-WorkbookDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]  [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]  [string]$Location,
        [Parameter(Mandatory = $true)]  [string]$DisplayName,
        [Parameter(Mandatory = $true)]  [string]$ResourceName,
        [Parameter(Mandatory = $true)]  [string]$SourceId,
        [Parameter(Mandatory = $true)]  [string]$SerializedData
    )

    # Azure Monitor Workbooks requires the resource name to be a GUID.
    # If a human-readable name is supplied, derive a stable deterministic GUID from it.
    $guidResourceName = $ResourceName
    if (-not [System.Guid]::TryParse($ResourceName, [ref][System.Guid]::Empty)) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResourceName)
        $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $hex   = [System.BitConverter]::ToString($hash).Replace('-', '').ToLower()
        $guidResourceName = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)
        Write-Host "  Resource name '$ResourceName' → GUID $guidResourceName (deterministic)"
    }

    $sizeKB = [math]::Round($SerializedData.Length / 1KB, 1)
    Write-Host "  Payload size: $sizeKB KB"

    $requestBody = @{
        location   = $Location
        kind       = "shared"
        properties = @{
            category       = "workbook"
            displayName    = $DisplayName
            sourceId       = $SourceId
            serializedData = $SerializedData
        }
    } | ConvertTo-Json -Depth 20 -Compress

    # az CLI is a Python app; force UTF-8 at both the Python and PowerShell console level
    # to prevent cp1252 "Unable to encode" warnings on Windows pipeline agents.
    $prevOutputEncoding = [Console]::OutputEncoding
    $prevPythonUtf8     = $env:PYTHONUTF8
    $env:PYTHONUTF8     = '1'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $tempBodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $requestBody | Out-File -FilePath $tempBodyFile -Encoding UTF8 -NoNewline

        $resourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks/$guidResourceName"
        $uri          = "$resourcePath`?api-version=2023-06-01"

        $response = az rest --method PUT --uri $uri --body "@$tempBodyFile" --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Workbook deployment failed. Response: $response"
        }

        Write-Host "Workbook '$DisplayName' deployed as '$ResourceName' in '$ResourceGroupName'."
    }
    finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $env:PYTHONUTF8     = $prevPythonUtf8
        if (Test-Path -Path $tempBodyFile) { Remove-Item -Path $tempBodyFile -Force }
    }
}
