# Azure Local LENS Workbook Deploy

Automation scripts and an Azure DevOps pipeline for fetching, caching, and deploying the [Azure Local LENS Workbook](https://github.com/Azure/AzureLocal-LENS-Workbook) to Azure Monitor in your own subscription.

## What this does

1. **Fetches** the latest workbook JSON from the upstream GitHub repository.
2. **Caches** it locally and opens a pull request when the cache changes (so updates are reviewed before they reach your environment).
3. **Splits** the workbook into a main and a capacity child workbook when the payload exceeds the Azure Monitor Workbooks API limit (~600 KB), and pre-generates the split cache files.
4. **Deploys** both workbooks (or a single workbook if within the size limit) to Azure Monitor via the REST API.

---

## Repository structure

```
├── scripts/
│   ├── DeployAzureLocalLENSWorkbook.ps1               # Entry point: validates, splits, and deploys
│   ├── FetchCacheAndUpdateAzureLocalLENSWorkbook.ps1  # Downloads from GitHub, manages cache & PRs
│   ├── Invoke-WorkbookDeploy.ps1                      # Thin wrapper around az rest PUT
│   ├── Split-LENSWorkbook.ps1                         # Splits oversized workbook into two resources
│   └── cache/
│       └── AzureLocal-LENS-Workbook/
│           ├── AzureLocal-LENS-Workbook.json          # Full cached workbook (auto-updated by pipeline)
│           ├── AzureLocal-LENS-Workbook-main.json     # Pre-split: main workbook (auto-generated)
│           └── AzureLocal-LENS-Workbook-capacity.json # Pre-split: capacity child workbook (auto-generated)
└── pipeline/
    └── DeployAzureLocalLENSWorkbook.yml               # Azure DevOps pipeline definition
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure CLI (`az`) | Authenticated against the target subscription |
| PowerShell 7+ (`pwsh`) | Cross-platform; used by both the pipeline and local runs |
| Azure DevOps service connection | Named after the subscription ID (e.g. `00000000-0000-0000-0000-000000000000`) |
| Resource group contributor | The pipeline identity needs permissions to create resource groups and workbooks |
| `Allow scripts to access the OAuth token` | Required in the pipeline job to create cache-update PRs |

---

## Azure DevOps pipeline

Import `pipeline/DeployAzureLocalLENSWorkbook.yml` into your Azure DevOps project as a pipeline. The pipeline is **manually triggered** (`trigger: none`) and also runs on a daily schedule.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `subscriptionId` | `00000000-0000-0000-0000-000000000000` | Target subscription — must also match the Azure DevOps service connection name |
| `resourceGroupName` | `rg-monitoring-shared` | Resource group for workbook deployment (created if missing) |
| `location` | `westeurope` | Azure region |
| `workbookDisplayName` | `Azure Local LENS Workbook` | Display name shown in the Azure Portal |
| `workbookResourceName` | `azure-local-lens-workbook` | Azure resource name (converted to a deterministic GUID internally) |
| `capacityWorkbookResourceName` | `azure-local-lens-workbook-capacity` | Resource name for the capacity child workbook; leave empty to disable split deployment |
| `cachePath` | `scripts/cache/AzureLocal-LENS-Workbook/AzureLocal-LENS-Workbook.json` | Repo-relative path to the cached workbook |
| `githubWorkbookUrl` | *(upstream raw URL)* | URL to the workbook JSON in the upstream GitHub repo |
| `createCacheUpdatePullRequest` | `true` | Whether to open a PR when the cache is updated |
| `cacheUpdateBranch` | `autoupdate/azurelocal-lens-workbook-cache` | Branch used for cache update commits |
| `cacheUpdateTargetBranch` | `main` | Target branch for cache update PRs |

---

## Running scripts locally

You can run the scripts without the pipeline for testing or one-off deployments.

### Fetch and update cache

```powershell
cd scripts
  -CachePath "cache/AzureLocal-LENS-Workbook/AzureLocal-LENS-Workbook.json" `
  -GitHubWorkbookUrl "https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/main/AzureLocal-LENS-Workbook.json" `
  -CreateCacheUpdatePullRequest $false `
  -CacheUpdateBranch "autoupdate/azurelocal-lens-workbook-cache" `
  -CacheUpdateTargetBranch "main"
```

### Deploy workbook

```powershell
# Authenticate first
az login
az account set --subscription "00000000-0000-0000-0000-000000000000"

cd scripts
  -SubscriptionId    "00000000-0000-0000-0000-000000000000" `
  -ResourceGroupName "rg-monitoring-shared" `
  -Location          "westeurope" `
  -WorkbookDisplayName "Azure Local LENS Workbook" `
  -WorkbookResourceName "azure-local-lens-workbook" `
  -WorkbookJsonPath  "cache/AzureLocal-LENS-Workbook/AzureLocal-LENS-Workbook.json" `
  -CapacityWorkbookResourceName "azure-local-lens-workbook-capacity"
```

---

## How the split deployment works

The Azure Monitor Workbooks REST API has a hard payload limit of approximately 600 KB. The LENS workbook frequently exceeds this limit.

When the workbook is larger than 500 KB (conservative threshold), the scripts:

1. Extract the `capacity-tab-group` from the workbook into a standalone **capacity child workbook**.
2. Rewrite the Capacity tab in the main workbook to open the child workbook via a `WorkbookTemplate` link.
3. Store both JSON files as pre-split cache (`*-main.json` and `*-capacity.json`) so the deploy step can skip re-parsing.

The capacity child workbook is deployed first, followed by the main workbook.

---

## License

MIT
