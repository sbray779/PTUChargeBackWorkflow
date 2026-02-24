# ChargeBack Logic App Deployment

This repository contains an automated deployment solution for an Azure Logic App (Standard) that generates daily chargeback reports from API Management LLM usage logs.

It is assumed that there is an existing APIM instance being used as an AI Gateway and that LLM logging has been enabled on desired APIs which are sending prompt/response logs to an existing Log Analytics workspace. This solution is designed to do the following:

1. Query the target Log Analytics workspace and summarize token utilization by product/subscription
2. Summarize the data into CSV format
3. Send the data to blob storage for later retrieval

By default, the workflow is triggered every 24 hours.

## Overview

The solution uses **Bicep templates** and **PowerShell** to deploy a complete infrastructure including:
- **Logic App (Standard)** — Workflow engine with user-assigned managed identity
- **User-Assigned Managed Identity** — Centrally managed identity for all authentication
- **API Connections** — Azure Monitor Logs and Azure Blob Storage (V2) with managed identity authentication
- **Storage Accounts** — Separate accounts for Logic App internal storage and report output
- **Log Analytics Workspace** — Error logging and monitoring
- **Data Collection Rule/Endpoint** — Custom log ingestion for workflow errors
- **RBAC Assignments** — All necessary permissions configured automatically

## Workflow Overview

The `CreateChargeBackReport` workflow uses a **time-chunked query pattern** to avoid Log Analytics memory limits (5GB) on large datasets. Instead of running a single 24-hour query, it splits the time range into **12 x 2-hour chunks** and writes each chunk's results to a separate blob file:

1. **Initialize_Time_Chunks** — Creates an array of 12 time chunks, each covering 2 hours with a `blobName` property (e.g., `chargeBack-chunk-01-21h-23h.csv`)
2. **Process_Time_Chunks** (ForEach loop, sequential) — For each chunk:
   - **Submit_Chunk_Query** — Sends KQL query with `Prefer: wait=0` for async execution
   - **Check_Chunk_Sync_Or_Async** — Branches on HTTP 200 (sync) vs 202 (async):
     - **200 path**: `Set_Chunk_Sync_Results` captures inline results
     - **202 path**: `Get_Poll_Location` → `Wait_Before_Poll` → `Poll_Chunk_Results` loop
   - **Get_Chunk_Results** — Selects final results from whichever path completed
   - **Transform_Chunk_To_Objects** — Converts columnar query results to named objects
   - **Create_Chunk_CSV** — Converts chunk results to CSV format
   - **Delete_Existing_Blob** — Removes existing blob (allows overwrite)
   - **Write_Chunk_Blob** — Creates new blob with chunk data

**Output Files** — 12 separate CSV files per run:
- `chargeBack-chunk-01-21h-23h.csv` through `chargeBack-chunk-12-19h-21h.csv`
- Each file contains pre-aggregated data for its 2-hour window
- Files are overwritten on each subsequent run

**Error Handlers** (run on failure/timeout of upstream actions):
- **Handle_Query_Failure** — Logs query errors to a custom Log Analytics table via Data Collection Rules
- **Handle_Blob_Write_Failure** — Logs blob write errors to the same custom table

### Why Time Chunking + Separate Blobs?

Log Analytics queries have a 5GB memory limit for joins. With high-volume APIM traffic, joining `ApiManagementGatewayLogs` with `ApiManagementGatewayLlmLog` over 24 hours can exceed this limit, resulting in error `-2133196799`. By splitting into 2-hour chunks:
- Each chunk stays under the memory limit
- The `hint.strategy=shuffle` hint distributes join processing across nodes
- Each chunk is pre-aggregated in KQL before writing to blob
- Downstream consumers can aggregate across chunk files as needed

This approach is a pure Logic App solution with no external dependencies on Azure Functions or JavaScript code actions, ensuring compatibility with .NET-based Logic App Standard runtimes

## Prerequisites

- **Azure CLI** installed and authenticated (`az login`)
- **Bicep CLI** installed (included with Azure CLI or install via `az bicep install`)
- **Azure Functions Core Tools** installed (`func`) - for workflow deployment
- **PowerShell 7.0 or later**
- **Contributor access** to the target Azure subscription
- An **existing Log Analytics workspace** containing `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog` tables

## Deployment (Full — New Infrastructure)

This deploys everything from scratch: infrastructure, API connections, RBAC, and the workflow.

### Step 1: Configure Parameters

Edit `deploy-infrastructure.bicepparam` and replace the placeholder values:

```bicep
using './deploy-infrastructure.bicep'

param resourceGroupName = '<your-resource-group-name>'
param location = '<your-azure-region>'
param sourceLogAnalyticsWorkspace = '<your-log-analytics-workspace-name>'
param sourceWorkspaceResourceGroup = '<your-source-workspace-resource-group>'
```

| Parameter | Description | Example |
|-----------|-------------|---------|
| `resourceGroupName` | Target resource group for all deployed resources | `rg-chargeback-prod` |
| `location` | Azure region for deployment | `eastus2`, `westus2`, `centralus` |
| `sourceLogAnalyticsWorkspace` | Name of the existing Log Analytics workspace containing APIM LLM logs | `MyLLMLogsWorkspace` |
| `sourceWorkspaceResourceGroup` | Resource group containing the source Log Analytics workspace | `MyLLMLogsResourceGroup` |

### Step 2: Run Deployment Script

```powershell
.\Deploy-ChargeBackLogicApp-v2.ps1
```

The script executes 8 steps automatically:

| Step | Action |
|------|--------|
| 1 | Create or verify resource group |
| 2 | Deploy infrastructure via Bicep (Logic App, storage, identity, DCR/DCE, RBAC) |
| 3 | Create API connections (Azure Monitor Logs + Azure Blob) with managed identity access policies |
| 4 | Retrieve connection runtime URLs |
| 5 | Assign RBAC roles (Website Contributor, Log Analytics Reader, Reader on source workspace) |
| 6 | Substitute `{{placeholders}}` in `workflow.json` and `connections.json` with deployment values |
| 7 | Deploy workflow to Logic App via `func azure functionapp publish` |
| 8 | Restart Logic App to apply permissions |

### Step 3: Verify

1. Navigate to the Logic App in the Azure Portal → Workflows → `CreateChargeBackReport`
2. Verify workflow health shows **Healthy**
3. Click **Run Trigger** to test, or trigger via CLI:
   ```powershell
   # Check workflow health
   az rest --method GET `
     --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.Web/sites/{logicAppName}/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2024-04-01"

   # Trigger a manual run
   az rest --method POST `
     --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.Web/sites/{logicAppName}/hostruntime/runtime/webhooks/workflow/api/management/workflows/CreateChargeBackReport/triggers/Recurrence/run?api-version=2024-04-01"
   ```
4. Check run history for success/failure
5. Verify the 12 chunk CSV files appear in storage: `rptcb{suffix}/reportoutput/chargeBack-chunk-*.csv`

## Deployment (Workflow Only — Existing Logic App)

If you already have a Logic App deployed and only need to update the workflow (e.g., after modifying the KQL query or workflow logic), follow these steps.

### Prerequisites

- The target Logic App must already exist and have:
  - A user-assigned managed identity configured
  - The `LOG_ANALYTICS_WORKSPACE_ID` app setting populated
  - API connections (`azuremonitorlogs`, `azureblob`) already created

### Step 1: Update Placeholders

The `workflow.json` and `connections.json` files contain `{{placeholder}}` tokens that must be replaced with your deployment values before publishing:

| Placeholder | Description | Where to find the value |
|-------------|-------------|------------------------|
| `{{USER_MANAGED_IDENTITY_ID}}` | Full resource ID of the user-assigned managed identity | `az identity show --name <name> --resource-group <rg> --query id -o tsv` |
| `{{DCE_ENDPOINT}}` | Data Collection Endpoint ingestion URL | `az monitor data-collection endpoint show --name <name> --resource-group <rg> --query logsIngestion.endpoint -o tsv` |
| `{{DCR_IMMUTABLE_ID}}` | Data Collection Rule immutable ID | `az monitor data-collection rule show --name <name> --resource-group <rg> --query immutableId -o tsv` |
| `{{AZURE_MONITOR_LOGS_RUNTIME_URL}}` | Azure Monitor Logs API connection runtime URL | Azure Portal → API Connections → azuremonitorlogs → Properties |
| `{{AZURE_BLOB_RUNTIME_URL}}` | Azure Blob API connection runtime URL | Azure Portal → API Connections → azureblob → Properties |

Replace placeholders using PowerShell:

```powershell
# Set your values
$identityId = "<your-managed-identity-resource-id>"
$dceEndpoint = "<your-dce-endpoint-url>"
$dcrImmutableId = "<your-dcr-immutable-id>"
$monitorLogsUrl = "<your-azuremonitorlogs-runtime-url>"
$blobUrl = "<your-azureblob-runtime-url>"

# Replace in workflow.json
$wf = Get-Content .\CreateChargeBackReport\workflow.json -Raw
$wf = $wf -replace '\{\{USER_MANAGED_IDENTITY_ID\}\}', $identityId `
          -replace '\{\{DCE_ENDPOINT\}\}', $dceEndpoint `
          -replace '\{\{DCR_IMMUTABLE_ID\}\}', $dcrImmutableId
$wf | Set-Content .\CreateChargeBackReport\workflow.json -Encoding UTF8

# Replace in connections.json
$conn = Get-Content .\connections.json -Raw
$conn = $conn -replace '\{\{USER_MANAGED_IDENTITY_ID\}\}', $identityId `
              -replace '\{\{AZURE_MONITOR_LOGS_RUNTIME_URL\}\}', $monitorLogsUrl `
              -replace '\{\{AZURE_BLOB_RUNTIME_URL\}\}', $blobUrl
$conn | Set-Content .\connections.json -Encoding UTF8
```

### Step 2: Publish the Workflow

```powershell
func azure functionapp publish <your-logic-app-name>
```

### Step 3: Restart the Logic App

```powershell
az logicapp restart --name <your-logic-app-name> --resource-group <your-resource-group>
```

> **Important:** If you encounter stale workflow definitions after publishing (e.g., the portal still shows old action definitions), you may need to stop the Logic App, delete the backing storage account's content share, and redeploy the full infrastructure. Logic App Standard caches workflow definitions in the Azure Files share, and file-level deployments may not always clear the cache.

## What Gets Deployed

### Infrastructure Resources (via Bicep)

| Resource | Name Pattern | Purpose |
|----------|-------------|---------|
| App Service Plan (Logic App) | `asp-chargeback-{suffix}` | WS1 SKU for Logic Apps Standard |
| User-Assigned Managed Identity | `id-chargeback-{suffix}` | Centralized authentication for all services |
| Logic App | `logic-chargeback-{suffix}` | Workflow engine |
| Logic App Storage | `lacb{suffix}` | Internal runtime storage (key-based auth required) |
| Report Storage | `rptcb{suffix}` | CSV report output (managed identity only, no keys) |
| Blob Container | `reportoutput` | Container for 12 daily chunk CSV reports |
| Log Analytics Workspace | `law-chargeback-{suffix}` | Error logging |
| Custom Table | `WorkflowFailures_CL` | Schema for workflow error records |
| Data Collection Endpoint | `dce-chargeback-{suffix}` | Log ingestion endpoint |
| Data Collection Rule | `dcr-chargeback-{suffix}` | Routes errors to custom table |

### API Connections (via PowerShell)

- **azuremonitorlogs** - V2 connection with managed identity authentication
- **azureblob** - V2 connection with managed identity authentication
- Both connections configured with access policies granting user-assigned managed identity access

### RBAC Role Assignments

All RBAC roles are assigned to the **user-assigned managed identity** (`id-chargeback-{suffix}`):

| Role | Scope | Purpose | Assigned By |
|------|-------|---------|-------------|
| Storage Blob Data Contributor | Report storage account | Write CSV reports | Bicep |
| Monitoring Metrics Publisher | Data Collection Rule | Ingest error logs | Bicep |
| Monitoring Metrics Publisher | Data Collection Endpoint | Send logs to DCE | Bicep |
| Log Analytics Reader | Source workspace | Query LLM logs | Bicep + PowerShell |
| Reader | Source workspace | Read workspace metadata | PowerShell |
| Website Contributor | Logic App resource | Dynamic schema retrieval | PowerShell |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Resource Group                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐                                                  │
│  │  User-Assigned   │◀─── Used by Logic App & API Connections          │
│  │ Managed Identity │                                                  │
│  └────────┬─────────┘                                                  │
│           │                                                             │
│           ▼                                                             │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Logic App (Standard)                                           │    │
│  │                                                                │    │
│  │  ┌─ CreateChargeBackReport ─────────────────────────────────┐  │    │
│  │  │ Recurrence Trigger (every 24h)                           │  │    │
│  │  │        │                                                 │  │    │
│  │  │        ▼                                                 │  │    │
│  │  │ Initialize_Time_Chunks (12 x 2-hour chunks w/ blobName)  │  │    │
│  │  │        │                                                 │  │    │
│  │  │        ▼                                                 │  │    │
│  │  │ ┌─ Process_Time_Chunks (ForEach, sequential) ─────────┐  │  │    │
│  │  │ │                                                     │  │  │    │
│  │  │ │  Submit_Chunk_Query (HTTP POST, Prefer: wait=0)     │  │  │    │
│  │  │ │         │                                           │  │  │    │
│  │  │ │     ┌───┴───┐                                       │  │  │    │
│  │  │ │   200?    202?                                      │  │  │    │
│  │  │ │     │       │                                       │  │  │    │
│  │  │ │   Sync   Poll_Chunk_Results (Until loop)            │  │  │    │
│  │  │ │   Path   (15s intervals, max 60 iterations)         │  │  │    │
│  │  │ │     │       │                                       │  │  │    │
│  │  │ │     └───┬───┘                                       │  │  │    │
│  │  │ │         ▼                                           │  │  │    │
│  │  │ │  Get_Chunk_Results                                  │  │  │    │
│  │  │ │         │                                           │  │  │    │
│  │  │ │         ▼                                           │  │  │    │
│  │  │ │  Transform_Chunk_To_Objects (Select)                │  │  │    │
│  │  │ │         │                                           │  │  │    │
│  │  │ │         ▼                                           │  │  │    │
│  │  │ │  Create_Chunk_CSV (Table)                           │  │  │    │
│  │  │ │         │                                           │  │  │    │
│  │  │ │         ▼                                           │  │  │    │
│  │  │ │  Delete_Existing_Blob → Write_Chunk_Blob            │  │  │    │
│  │  │ │         │               (one per chunk)             │  │  │    │
│  │  │ │         ▼                                           │  │  │    │
│  │  │ │  ───────────────────────────────────────────        │  │  │    │
│  │  │ │  Output: chargeBack-chunk-{NN}-{start}h-{end}h.csv  │  │  │    │
│  │  │ └─────────────────────────────────────────────────────┘  │  │    │
│  │  └──────────────────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────────────────┘    │
│           │                                                            │
│           ▼                                                            │
│  ┌──────────────────┐  ┌────────────────────────────────────┐         │
│  │ Storage (lacb*)  │  │ Storage (rptcb*)                   │         │
│  │ Internal/Runtime │  │ reportoutput/                      │         │
│  │ (Key Auth)       │  │   chargeBack-chunk-01-21h-23h.csv  │         │
│  └──────────────────┘  │   chargeBack-chunk-02-23h-01h.csv  │         │
│                        │   ...                               │         │
│                        │   chargeBack-chunk-12-19h-21h.csv  │         │
│                        │ (Managed ID Only, 12 files/run)    │         │
│                        └────────────────────────────────────┘         │
│                                                                        │
│  ┌──────────────────┐  ┌──────────────────┐                           │
│  │ DCE/DCR          │─▶│ Error Workspace  │                           │
│  │ Error Logging    │  │ WorkflowFailures │                           │
│  └──────────────────┘  │ _CL              │                           │
│                        └──────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────┐
│ Source Log Analytics             │
│ (External Resource Group)        │
│ ApiManagementGatewayLogs         │
│ ApiManagementGatewayLlmLog       │
│ CognitiveServicesInventory_CL    │
└──────────────────────────────────┘
```

## KQL Query

The workflow executes this optimized query against the source Log Analytics workspace for each 2-hour time chunk:

```kql
// Pre-aggregate LLM log data before joining (reduces memory usage)
let llmAgg = ApiManagementGatewayLlmLog 
| where TimeGenerated >= ago({hoursAgo}h) and TimeGenerated < ago({hoursUntil}h)
| where SequenceNumber == 0 
| summarize 
    TotalTokens = sum(TotalTokens), 
    CompletionTokens = sum(CompletionTokens), 
    PromptTokens = sum(PromptTokens) 
    by CorrelationId;

// Main query with shuffle hint for distributed join processing
ApiManagementGatewayLogs 
| where TimeGenerated >= ago({hoursAgo}h) and TimeGenerated < ago({hoursUntil}h)
| where IsRequestSuccess 
| join hint.strategy=shuffle kind=inner llmAgg on CorrelationId 
| extend ParsedUrl = parse_url(BackendUrl) 
| extend ExtractedEndpoint = strcat(tostring(ParsedUrl.Scheme), '://', tostring(ParsedUrl.Host), '/') 
| extend DeploymentFromUrl = extract('/openai/deployments/([^/]+)/', 1, BackendUrl) 
| extend 
    Luma = extract('^([0-9]{6})', 1, ApimSubscriptionId), 
    Workspace = extract('^[0-9]{6}-(.+)$', 1, ApimSubscriptionId) 
| join kind=leftouter (
    CognitiveServicesInventory_CL 
    | summarize arg_max(TimeGenerated, *) by AccountEndpoint, DeploymentName 
    | project 
        AccountEndpoint, 
        CogSvcDeploymentName = DeploymentName,
        CogSvcModelName = ModelName,
        CogSvcSkuName = SkuName,
        CogSvcSkuCapacity = SkuCapacity,
        CogSvcAccountName = AccountName,
        CogSvcSubscriptionId = SubscriptionId
) on $left.ExtractedEndpoint == $right.AccountEndpoint, 
   $left.DeploymentFromUrl == $right.CogSvcDeploymentName 
| summarize 
    TotalTokens = sum(TotalTokens), 
    CompletionTokens = sum(CompletionTokens), 
    PromptTokens = sum(PromptTokens), 
    FirstSeen = min(TimeGenerated), 
    LastSeen = max(TimeGenerated), 
    Regions = strcat_array(make_set(Region, 8), '; '), 
    CallerIpAddresses = strcat_array(make_set(CallerIpAddress, 8), '; '), 
    Calls = count() 
    by ProductId, DeploymentFromUrl, ExtractedEndpoint, BackendId, 
       CogSvcModelName, CogSvcSkuName, CogSvcSkuCapacity, CogSvcAccountName, 
       CogSvcSubscriptionId, Luma, Workspace 
| project 
    ProductId, Luma, Workspace, 
    DeploymentName = DeploymentFromUrl, 
    ModelName = CogSvcModelName, 
    AccountName = CogSvcAccountName, 
    SubscriptionId = CogSvcSubscriptionId, 
    SkuName = CogSvcSkuName, 
    SkuCapacity = CogSvcSkuCapacity, 
    BackendId, 
    Endpoint = ExtractedEndpoint, 
    PromptTokens, CompletionTokens, TotalTokens, Calls, 
    FirstSeen, LastSeen, Regions, CallerIpAddresses 
| order by ProductId asc, TotalTokens desc
```

### Query Optimizations

1. **Pre-aggregation** (`let llmAgg = ...`) — Aggregates token counts by CorrelationId BEFORE the join, reducing the dataset size at join time
2. **Shuffle hint** (`hint.strategy=shuffle`) — Distributes join processing across cluster nodes for better parallelism
3. **CognitiveServicesInventory_CL join** — Enriches data with Azure OpenAI deployment metadata (model name, SKU, capacity)
4. **Luma/Workspace extraction** — Parses subscription ID patterns for organizational attribution
5. **strcat_array for set fields** — Converts `make_set()` arrays to semicolon-delimited strings for CSV compatibility

The `Transform_Chunk_To_Objects` action maps the columnar result to named fields using positional indexes that match the `project` clause order:

| Index | Column | Description |
|-------|--------|-------------|
| 0 | ProductId | APIM Product ID |
| 1 | Luma | 6-digit org code extracted from subscription ID |
| 2 | Workspace | Workspace name extracted from subscription ID |
| 3 | DeploymentName | Azure OpenAI deployment name from URL |
| 4 | ModelName | Model name from CognitiveServicesInventory_CL |
| 5 | AccountName | Azure OpenAI account name |
| 6 | SubscriptionId | Azure subscription containing the OpenAI resource |
| 7 | SkuName | SKU name (Standard, etc.) |
| 8 | SkuCapacity | Provisioned capacity (PTU/TPM) |
| 9 | BackendId | APIM backend identifier |
| 10 | Endpoint | Azure OpenAI endpoint URL |
| 11 | PromptTokens | Total prompt tokens consumed |
| 12 | CompletionTokens | Total completion tokens generated |
| 13 | TotalTokens | Sum of prompt + completion tokens |
| 14 | Calls | Number of API calls |
| 15 | FirstSeen | Earliest request timestamp |
| 16 | LastSeen | Latest request timestamp |
| 17 | Regions | Semicolon-delimited list of Azure regions (max 8) |
| 18 | CallerIpAddresses | Semicolon-delimited list of caller IPs (max 8) |

> **Important:** If you modify the `project` clause in the KQL query, you must also update the positional indexes in `Transform_Chunk_To_Objects` in `workflow.json` to match.

## Post-Deployment

### Monitor

- **Report Output**: Check blob storage container `reportoutput` for 12 chunk files (`chargeBack-chunk-*.csv`)
- **Workflow Runs**: View run history in Logic App portal → Workflows → CreateChargeBackReport
- **Error Logs**: Query `WorkflowFailures_CL` table in error workspace:

```kql
WorkflowFailures_CL
| where TimeGenerated >= ago(7d)
| project TimeGenerated, WorkflowName, FailureType, ActionName, ErrorCode, ErrorMessage, Severity
| order by TimeGenerated desc
```

## Troubleshooting

### Connection Errors

If connections show as "Invalid" or "Forbidden":
1. Verify the user-assigned managed identity resource exists: `id-chargeback-{suffix}`
2. Check that the Logic App has the identity configured in its Identity settings
3. Verify RBAC role assignments on the managed identity
4. Wait 30–60 seconds for permissions to propagate
5. Restart the Logic App:
   ```powershell
   az logicapp restart --name <logic-app-name> --resource-group <rg>
   ```

### Query Failures (InsufficientAccessError)

- Verify the source workspace name and resource group are correct in `deploy-infrastructure.bicepparam`
- Confirm the managed identity has both **Log Analytics Reader** and **Reader** roles on the source workspace
- Ensure `ApiManagementGatewayLogs`, `ApiManagementGatewayLlmLog`, and `CognitiveServicesInventory_CL` tables exist in the workspace
- Restart the Logic App after RBAC changes

### Query Failures (Memory Limit Error -2133196799)

If you see error code `-2133196799` with message about exceeding memory limits:

1. **Reduce chunk size**: Change from 2-hour to 1-hour chunks in `Initialize_Time_Chunks` (will result in 24 chunks)
2. **Add row limits**: Add `| take 10000` to the KQL query to limit results per chunk
3. **Verify pre-aggregation**: Ensure the `let llmAgg = ...` pattern is being used to aggregate before joining
4. **Check shuffle hint**: Ensure `hint.strategy=shuffle` is present on the join

The 5GB memory limit applies to intermediate results during query execution. Pre-aggregating the LLM log data before joining significantly reduces memory usage.

### Blob Write Failures

- Verify the report storage account has `allowSharedKeyAccess: false` (managed identity only)
- Check **Storage Blob Data Contributor** role assignment on the report storage account
- Ensure the `reportoutput` container exists

### Stale Workflow Definitions After Deploy

If the portal shows old action definitions after publishing:
1. **Stop** the Logic App
2. **Delete** the Logic App's backing storage account (`lacb{suffix}`)
3. **Delete** the Logic App itself
4. Re-run the full deployment script (`Deploy-ChargeBackLogicApp-v2.ps1`)

This happens because Logic App Standard stores workflow definitions in an Azure Files share, and file-level deployments may not always clear the cache.

### Service Unavailable in Portal

If the portal shows "Service Unavailable" but the workflow runs successfully via CLI:
- This is typically a transient portal issue after a fresh deployment
- Trigger the workflow via CLI to verify it works
- The portal usually recovers after a few minutes

## Customization

### Modify Query

Edit the `query` field in the `Submit_Chunk_Query` action in [CreateChargeBackReport/workflow.json](CreateChargeBackReport/workflow.json). If you change the `project` columns, you must also update the positional indexes in `Transform_Chunk_To_Objects` to match (see column index table above).

### Change Time Chunk Size

To use smaller or larger time chunks, edit the `Initialize_Time_Chunks` action. For example, to use 1-hour chunks (24 total):
```json
"value": [
  { "chunkId": 1, "hoursAgo": 24, "hoursUntil": 23, "blobName": "chargeBack-chunk-01.csv" },
  { "chunkId": 2, "hoursAgo": 23, "hoursUntil": 22, "blobName": "chargeBack-chunk-02.csv" },
  ...
]
```

Smaller chunks reduce memory usage per query but increase total execution time and the number of output blobs.

### Enable Parallel Chunk Processing

By default, chunks are processed **sequentially** (one at a time) to avoid overloading log Analytics. This is controlled by the `runtimeConfiguration` on the `Process_Time_Chunks` ForEach loop:

```json
"runtimeConfiguration": {
  "concurrency": {
    "repetitions": 1
  }
}
```

To enable parallel processing, increase the `repetitions` value in [CreateChargeBackReport/workflow.json](CreateChargeBackReport/workflow.json):

| Setting | Behavior | Run Time (approx) |
|---------|----------|-------------------|
| `repetitions: 1` | Sequential (default) | 6-12 minutes |
| `repetitions: 4` | 4 concurrent chunks | 2-3 minutes |
| `repetitions: 6` | 6 concurrent chunks | 1-2 minutes |
| `repetitions: 12` | All 12 concurrent | <1 minute (risky) |

**Considerations before enabling parallelization:**

1. **Log Analytics Concurrent Query Limit** — Each workspace supports ~10 concurrent queries. Running all 12 chunks in parallel may cause throttling (HTTP 429) or query failures.

2. **Managed Identity Token Acquisition** — High concurrency can cause token acquisition contention. The workflow uses `Prefer: wait=0` (async) which helps, but rapid parallel requests may still encounter brief delays.

3. **Retry Behavior** — If a chunk fails due to throttling, it will not automatically retry in the current workflow. Consider adding retry policies if enabling high parallelism.

4. **Blob Write Conflicts** — Each chunk writes to a unique blob, so there are no write conflicts. However, if the workflow fails mid-run with parallelism enabled, you may have partial results (some blobs updated, others stale).

5. **Cost** — Logic App Standard is billed per action execution. Parallelism doesn't change the number of actions, but faster runs may allow more frequent scheduling if needed.

**Recommended approach:** Start with `repetitions: 4` for a ~3x speedup with minimal risk, then increase if stable.

### Configure Report Time Window

By default, the report covers 9pm the previous evening to 9pm the evening before that (24 hours ending at 9pm yesterday). This is controlled by the `REPORT_END_HOUR` app setting.

**Change the report end hour:**
```powershell
# Set report to end at midnight (covers midnight-to-midnight)
az webapp config appsettings set --name logic-chargeback-xxx --resource-group rg-xxx \
  --settings REPORT_END_HOUR=0

# Set report to end at 5pm (covers 5pm-to-5pm)
az webapp config appsettings set --name logic-chargeback-xxx --resource-group rg-xxx \
  --settings REPORT_END_HOUR=17
```

| REPORT_END_HOUR | Report Window (when run today) |
|-----------------|-------------------------------|
| 0 (midnight) | Midnight yesterday to midnight day before |
| 9 (9am) | 9am yesterday to 9am day before |
| 17 (5pm) | 5pm yesterday to 5pm day before |
| 21 (9pm, default) | 9pm yesterday to 9pm day before |

**Note:** The report always covers the 24 hours ending at the specified hour **yesterday**. This ensures complete data even if the workflow runs late.

### Change Schedule

Edit `Recurrence` trigger:
```json
"recurrence": {
  "interval": 24,
  "frequency": "Hour",
  "timeZone": "Central Standard Time"
}
```

### Modify Blob Naming

Each chunk's blob name is defined in the `Initialize_Time_Chunks` array. To change the naming pattern, edit the `blobName` property for each chunk:
```json
{
  "chunkId": 1,
  "hoursAgo": 24,
  "hoursUntil": 22,
  "blobName": "chargeBack-chunk-01-21h-23h.csv"
}
```

The naming convention uses the time window (relative to the report end hour) in the filename to make it easy to identify each chunk's coverage period.

## Files

```
PTUChargeBackWorkflow/
├── Deploy-ChargeBackLogicApp-v2.ps1       # Full deployment script (8 steps)
├── deploy-infrastructure.bicep            # Bicep template for all infrastructure
├── deploy-infrastructure.bicepparam       # Deployment parameters (edit before deploying)
├── modules/
│   └── logAnalyticsRbac.bicep             # Cross-resource-group RBAC module
├── connections.json                       # API connection definitions ({{placeholders}})
├── host.json                              # Logic App host configuration
├── local.settings.json                    # Local development settings
├── parameters.json                        # ARM parameters (legacy)
├── CreateChargeBackReport/
│   └── workflow.json                      # Workflow definition ({{placeholders}})
├── workflow-designtime/
│   ├── host.json                          # Design-time host config
│   └── local.settings.json               # Design-time local settings
└── README.md                              # This file
```

## Important Notes

1. **Placeholder Tokens**: The `workflow.json` and `connections.json` files contain `{{placeholder}}` tokens (e.g., `{{USER_MANAGED_IDENTITY_ID}}`) that are replaced at deployment time by Step 6 of the deployment script. Do not commit files with hardcoded deployment values.

2. **User-Assigned Managed Identity**: The solution uses a user-assigned managed identity (`id-chargeback-{suffix}`) instead of system-assigned. This provides better lifecycle management and allows the identity to persist independently of the Logic App.

3. **Async Query Pattern**: The workflow uses the Log Analytics REST API with `Prefer: wait=0` rather than the managed API connector, enabling asynchronous query execution to avoid HTTP timeouts on large datasets.

4. **Time Chunking with Separate Blobs**: To avoid the 5GB memory limit on Log Analytics joins, the workflow splits queries into 12 x 2-hour chunks. Each chunk's results are written to a separate blob file. Downstream consumers aggregate the 12 files as needed. This approach avoids complex in-Logic-App aggregation and ensures .NET runtime compatibility.

5. **Pre-Aggregation in KQL**: The KQL query pre-aggregates the `ApiManagementGatewayLlmLog` table before joining, and uses `strcat_array(make_set(...), '; ')` to produce string fields for Regions and CallerIpAddresses, ensuring CSV compatibility.

6. **Positional Column Mapping**: `Transform_Chunk_To_Objects` uses `@item()[N]` positional indexes rather than column-name lookups, because Logic App Standard expression language does not support `where()`/`first()`/`indexOf()` functions on arrays.

7. **Storage Cache**: Logic App Standard stores workflow definitions in an Azure Files share. When redeploying, if old definitions persist, delete both the Logic App and its backing storage account before redeploying.

8. **Resource Naming**: All resource names include a deterministic suffix generated by `uniqueString(resourceGroup().id)` to ensure uniqueness across Azure.

9. **Pure Logic App Solution**: This workflow runs entirely within Logic App Standard with no external dependencies on Azure Functions or JavaScript code actions, ensuring full compatibility with .NET-based runtimes.

## License

Internal Microsoft use only.

## Support

For issues or questions, contact the Logic Apps development team.
