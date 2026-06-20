<#
.SYNOPSIS
Fetches Azure Local LENS workbook from GitHub, manages local cache, and creates/updates pull requests.

.DESCRIPTION
This script performs the following operations:
1. Downloads the Azure Local LENS workbook JSON from GitHub
2. Falls back to local cache if download fails
3. Compares cache with downloaded file (SHA256)
4. Commits changes and creates a PR if cache was updated
5. Sets output variables for deployment (LENS_WORKBOOK_PATH, LENS_WORKBOOK_SOURCE)
6. Checks workbook payload size; if it exceeds the Azure Monitor Workbooks API limit (~600 KB),
   generates pre-split cache files (*-main.json and *-capacity.json) and sets
   LENS_MAIN_WORKBOOK_PATH / LENS_CAPACITY_WORKBOOK_PATH for the deploy step

.PARAMETER CachePath
The relative path from the repository root to the cached workbook file.

.PARAMETER GitHubWorkbookUrl
The URL to the Azure Local LENS workbook JSON file on GitHub.

.PARAMETER CreateCacheUpdatePullRequest
Whether to create a pull request when the cache is updated.

.PARAMETER CacheUpdateBranch
The branch name to use for cache update commits.

.PARAMETER CacheUpdateTargetBranch
The target branch for cache update pull requests.

.EXAMPLE
& ".\FetchCacheAndUpdateAzureLocalLENSWorkbook.ps1" `
  -CachePath "cache/AzureLocal-LENS-Workbook/AzureLocal-LENS-Workbook.json" `
  -GitHubWorkbookUrl "https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/main/src/Workbooks/AzureLocalOverview.json" `
  -CreateCacheUpdatePullRequest $true `
  -CacheUpdateBranch "azure-local-lens-cache-update" `
  -CacheUpdateTargetBranch "main"
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$CachePath,

  [Parameter(Mandatory = $true)]
  [string]$GitHubWorkbookUrl,

  [Parameter(Mandatory = $true)]
  [bool]$CreateCacheUpdatePullRequest,

  [Parameter(Mandatory = $true)]
  [string]$CacheUpdateBranch,

  [Parameter(Mandatory = $true)]
  [string]$CacheUpdateTargetBranch
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Split-LENSWorkbook.ps1"

$repoRoot = if ($env:Build_SourcesDirectory) { $env:Build_SourcesDirectory } else { Get-Location }
$tempDir = if ($env:Agent_TempDirectory) { $env:Agent_TempDirectory } else { [System.IO.Path]::GetTempPath() }
$cacheFilePath = Join-Path $repoRoot $CachePath
$cacheDirectory = Split-Path -Path $cacheFilePath -Parent
$tempFilePath = Join-Path $tempDir "AzureLocal-LENS-Workbook.json"

New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null

try {
  Invoke-WebRequest -Uri $GitHubWorkbookUrl -OutFile $tempFilePath -UseBasicParsing
  if (-not (Test-Path $tempFilePath)) {
    throw "Downloaded workbook file was not created."
  }

  if ((Get-Item $tempFilePath).Length -lt 1000) {
    throw "Downloaded workbook file appears invalid (too small)."
  }

  $downloadedFromGithub = $true
  Write-Host "Successfully downloaded workbook from GitHub."
}
catch {
  Write-Warning "Could not download workbook from GitHub. Falling back to cached file. Error: $($_.Exception.Message)"
}

if (-not $downloadedFromGithub -and -not (Test-Path $cacheFilePath)) {
  throw "GitHub download failed and no cached workbook exists at '$CachePath'."
}

if ($downloadedFromGithub) {
  $newHash = (Get-FileHash -Path $tempFilePath -Algorithm SHA256).Hash
  $oldHash = $null
  if (Test-Path $cacheFilePath) {
    $oldHash = (Get-FileHash -Path $cacheFilePath -Algorithm SHA256).Hash
  }

  Copy-Item -Path $tempFilePath -Destination $cacheFilePath -Force
  $cacheChanged = ($newHash -ne $oldHash)

  if ($cacheChanged) {
    Write-Host "Cached workbook was updated from GitHub."
  }
  else {
    Write-Host "Cached workbook is already up to date."
  }
}
else {
  Write-Host "Using cached workbook at '$CachePath'."
}

$workbookSource = if ($downloadedFromGithub) { "github" } else { "cache" }
Write-Host "##vso[task.setvariable variable=LENS_WORKBOOK_PATH]$cacheFilePath"
Write-Host "##vso[task.setvariable variable=LENS_WORKBOOK_SOURCE]$workbookSource"

# --- Payload size check and pre-split cache generation ---
# The Azure Monitor Workbooks REST API has a hard payload limit (~600 KB).
# If the workbook exceeds the safe threshold, split it into a main workbook and a
# capacity child workbook so each can be deployed independently.
$splitPayloadThresholdBytes = 500000  # 500 KB — conservative to account for JSON-in-JSON wrapping
$mainCacheRelPath      = $null
$capacityCacheRelPath  = $null

$fullWorkbookJson = Get-Content -Path $cacheFilePath -Raw
$fullWorkbookSizeKB = [math]::Round($fullWorkbookJson.Length / 1KB, 1)
Write-Host "Cached workbook raw size: $fullWorkbookSizeKB KB"

if ($fullWorkbookJson.Length -gt $splitPayloadThresholdBytes) {
  Write-Host "Workbook ($fullWorkbookSizeKB KB) exceeds $([math]::Round($splitPayloadThresholdBytes/1KB)) KB threshold. Generating pre-split cache files..."

  try {
    # Use a placeholder resource ID — the deploy step replaces it with the real Azure resource ID.
    $split = Split-LENSWorkbook -WorkbookJson $fullWorkbookJson -CapacityResourceId 'LENS_CAPACITY_RESOURCE_ID_PLACEHOLDER'

    $cacheBaseDir  = Split-Path -Path $CachePath -Parent
    $cacheBaseName = [System.IO.Path]::GetFileNameWithoutExtension($CachePath)
    $mainCacheRelPath     = "$cacheBaseDir/$cacheBaseName-main.json"
    $capacityCacheRelPath = "$cacheBaseDir/$cacheBaseName-capacity.json"
    $mainCacheFullPath     = Join-Path $repoRoot $mainCacheRelPath
    $capacityCacheFullPath = Join-Path $repoRoot $capacityCacheRelPath

    $split.MainJson     | Out-File -FilePath $mainCacheFullPath     -Encoding UTF8 -NoNewline
    $split.CapacityJson | Out-File -FilePath $capacityCacheFullPath -Encoding UTF8 -NoNewline

    $mainKB = [math]::Round((Get-Item $mainCacheFullPath).Length / 1KB, 1)
    $capKB  = [math]::Round((Get-Item $capacityCacheFullPath).Length / 1KB, 1)
    Write-Host "Pre-split cache written: main=$mainKB KB, capacity=$capKB KB"

    Write-Host "##vso[task.setvariable variable=LENS_MAIN_WORKBOOK_PATH]$mainCacheFullPath"
    Write-Host "##vso[task.setvariable variable=LENS_CAPACITY_WORKBOOK_PATH]$capacityCacheFullPath"
  }
  catch {
    Write-Warning "Workbook split failed: $($_.Exception.Message). Single workbook deployment may fail due to payload size."
    $mainCacheRelPath     = $null
    $capacityCacheRelPath = $null
  }
}
else {
  Write-Host "Workbook is within size limit ($fullWorkbookSizeKB KB). Split not required."
}

# Proceed to PR creation only when the workbook or split files have changed, and PR creation is enabled.
$missingSplitFiles = $mainCacheRelPath -and (
  -not (Test-Path (Join-Path $repoRoot $mainCacheRelPath)) -or
  -not (Test-Path (Join-Path $repoRoot $capacityCacheRelPath))
)
if ((-not $cacheChanged -and -not $missingSplitFiles) -or -not $CreateCacheUpdatePullRequest) {
  return
}

if ([string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
  throw "SYSTEM_ACCESSTOKEN is not available. Enable OAuth token access for the pipeline to create pull requests."
}

$branchName = $CacheUpdateBranch
$targetBranch = $CacheUpdateTargetBranch
$sourceRef = "refs/heads/$branchName"
$targetRef = "refs/heads/$targetBranch"

& git -C $repoRoot config user.email "azure-pipelines@local"
if ($LASTEXITCODE -ne 0) { throw "git config user.email failed." }

& git -C $repoRoot config user.name "Azure Pipelines"
if ($LASTEXITCODE -ne 0) { throw "git config user.name failed." }

& git -C $repoRoot checkout -B $branchName
if ($LASTEXITCODE -ne 0) { throw "git checkout branch '$branchName' failed." }

& git -C $repoRoot add -- $CachePath
if ($LASTEXITCODE -ne 0) { throw "git add for '$CachePath' failed." }

if ($mainCacheRelPath) {
  & git -C $repoRoot add -- $mainCacheRelPath -- $capacityCacheRelPath
  if ($LASTEXITCODE -ne 0) { Write-Warning "git add for split cache files failed — split files may be missing from PR." }
}

git -C $repoRoot diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
  Write-Host "No staged cache changes detected after add. Skipping PR creation."
  return
}
elseif ($LASTEXITCODE -ne 1) {
  throw "git diff --cached --quiet failed."
}

& git -C $repoRoot commit -m "chore: update Azure Local LENS workbook cache"
if ($LASTEXITCODE -ne 0) { throw "git commit failed." }

& git -C $repoRoot push origin $branchName --force
if ($LASTEXITCODE -ne 0) { throw "git push failed." }

$collectionUri = $env:SYSTEM_COLLECTIONURI
$projectName   = $env:SYSTEM_TEAMPROJECT
$repositoryId  = $env:BUILD_REPOSITORY_ID
$baseApi = "$collectionUri$projectName/_apis/git/repositories/$repositoryId"
$apiVersion = "7.1-preview.1"
$headers = @{
  Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)"
  "Content-Type" = "application/json"
}

$existingPrUrl = "$baseApi/pullrequests?searchCriteria.status=active&searchCriteria.sourceRefName=$([uri]::EscapeDataString($sourceRef))&searchCriteria.targetRefName=$([uri]::EscapeDataString($targetRef))&api-version=$apiVersion"
$existingPrResponse = Invoke-RestMethod -Method Get -Uri $existingPrUrl -Headers $headers

if ($existingPrResponse.count -gt 0) {
  $existingPrId = $existingPrResponse.value[0].pullRequestId
  Write-Host "Cache update PR already exists (#$existingPrId)."
  return
}

$prPayload = @{
  sourceRefName = $sourceRef
  targetRefName = $targetRef
  title = "chore: update Azure Local LENS workbook cache"
  description = "Automated cache refresh from upstream https://github.com/Azure/AzureLocal-LENS-Workbook."
} | ConvertTo-Json -Depth 10

$createPrUrl = "$baseApi/pullrequests?api-version=$apiVersion"
$createdPr = Invoke-RestMethod -Method Post -Uri $createPrUrl -Headers $headers -Body $prPayload

Write-Host "Cache update PR created (#$($createdPr.pullRequestId))."
