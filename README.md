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

The `CreateChargeBackReport` workflow uses a **time-chunked query + Log Analytics intermediate staging** pattern to avoid Log Analytics memory limits (5GB) on large datasets and to produce a clean, single daily report with no duplication.

Instead of running a single 24-hour query, it splits the time range into **12 x 2-hour chunks**, stages the results in a custom Log Analytics table (`ChargeBackChunks_CL`), and then re-aggregates them into one daily CSV:

### Phase 1 — Chunk Queries (Per-Chunk Loop)

1. **Initialize_Time_Chunks** — Creates an array of 12 time chunks (2 hours each)
2. **Initialize_Report_Date** / **Initialize_Workflow_Run_Id** / **Initialize_Expected_Chunk_Count** / **Initialize_Chunk_Batch_Offset** / **Initialize_Batch_Write_Failed** — Set up run-scoped variables
3. **Process_Time_Chunks** (ForEach loop, sequential) — For each chunk:
   - **Submit_Chunk_Query** — Sends KQL query against the source APIM workspace with `Prefer: wait=60` (allows synchronous return for queries completing under 60s, avoiding unnecessary async polling)
   - **Check_Chunk_Sync_Or_Async** — Branches on HTTP 200 (sync) vs 202 (async; polls until complete)
   - **Get_Chunk_Results** — Selects final results from whichever path completed
   - **Transform_Chunk_To_Objects** — Converts columnar query results to named objects
   - **Enrich_Chunk_Rows** — Adds `ReportDate`, `WorkflowRunId`, and `ChunkId` to every row
   - **Write_Chunk_To_Logs_If_Has_Rows** (If condition):
     - **true**: `Reset_Batch_Offset` → `Post_Chunk_Batches` (Until loop, 500 rows per POST to stay under the Logs Ingestion API 1MB limit) → `Increment_Expected_Chunk_Count`
     - If any batch POST fails after all retries, `Set_Batch_Write_Failed` flags the failure and `Advance_Batch_Offset` still advances to prevent the loop from hanging
     - **false**: no-op (skips empty chunks to avoid 400 errors)
4. **Fail_If_Batch_Write_Failed** — If any batch POST failed during `Process_Time_Chunks`, terminates the workflow with a `BatchWriteFailed` error to prevent an incomplete report from being treated as complete

### Phase 2 — Ingestion Polling

5. **Wait_Before_Ingestion_Poll** — 30-second initial pause
6. **Poll_For_Ingestion** (Until loop) — Polls `ChargeBackChunks_CL` every 30 seconds until `dcount(ChunkId) >= ExpectedChunkCount` (i.e., all written chunks are queryable). Times out after 20 minutes and continues regardless.

### Phase 3 — Daily Aggregation

7. **Submit_Daily_Query** — Queries `ChargeBackChunks_CL` (error workspace), filtered by `WorkflowRunId` and `ReportDate`, to re-aggregate all 12 chunks into a single daily summary (uses `Prefer: wait=60`)
8. **Check_Daily_Sync_Or_Async** — Async polling pattern (same as chunk queries)
9. **Get_Daily_Results** → **Transform_Daily_To_Objects** → **Create_Daily_CSV**
10. **Write_Daily_Report_Blob** — Writes one CSV to blob storage with a date-time-stamped filename: `chargeBack-daily-YYYY-MM-DD-HHmmss.csv`

**Output** — One CSV file per run:
- `reportoutput/chargeBack-daily-YYYY-MM-DD-HHmmss.csv`
- Contains fully aggregated daily data (all 2-hour windows combined)
- Each run produces a unique file; previous runs are preserved

**Error Handlers** (run on failure/timeout of upstream actions):
- **Handle_Query_Failure** — Logs query errors to `WorkflowFailures_CL` via Data Collection Rules
- **Handle_Blob_Write_Failure** — Logs blob write errors to the same table

### Why Time Chunking + Intermediate Staging?

Log Analytics queries have a 5GB memory limit for joins. With high-volume APIM traffic, joining `ApiManagementGatewayLogs` with `ApiManagementGatewayLlmLog` over 24 hours can exceed this limit, resulting in error `-2133196799`. By splitting into 2-hour chunks and staging in `ChargeBackChunks_CL`:
- Each chunk query stays under the memory limit
- The `hint.strategy=shuffle` hint distributes join processing across nodes
- All chunks are re-aggregated in a single final KQL query — no fan-out merge required in the Logic App
- `WorkflowRunId` tagging enables idempotent re-runs: re-running on the same day produces a new timestamped file without corrupting previous runs
- The Logs Ingestion API ingestion step is fault-tolerant: if ingestion is slow, the poll loop waits up to 20 minutes before proceeding

### Fault Tolerance

- **500-row batching** — Each chunk's enriched rows are sent to the Logs Ingestion API in batches of 500 rows via a `Post_Chunk_Batches` Until loop. This prevents HTTP 430 `ContentLengthLimitExceeded` errors (1 MB per-request API limit).
- **BatchWriteFailed safety** — If any batch POST fails after all retries, a `BatchWriteFailed` flag is set and the batch offset still advances (preventing the loop from hanging at PT15M timeout). After all chunks complete, `Fail_If_Batch_Write_Failed` terminates the workflow with a descriptive error rather than producing an incomplete report.
- **Orphaned RBAC cleanup** — The deploy script removes role assignments with no valid principal before running Bicep, preventing `RoleAssignmentUpdateNotPermitted` errors when identity resources are recreated.
- **Temp-directory staging** — Placeholder substitution happens in a temp directory; source files (`workflow.json`, `connections.json`) are never modified by the deploy script.

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

The script executes 9 steps automatically:

| Step | Action |
|------|--------|
| 1 | Create or verify resource group |
| 2 | Clean up orphaned role assignments (prevents `RoleAssignmentUpdateNotPermitted` errors when identity is recreated) |
| 3 | Deploy infrastructure via Bicep (Logic App, storage, identity, DCR/DCE, RBAC) |
| 4 | Create API connections (Azure Monitor Logs + Azure Blob) with managed identity access policies |
| 5 | Retrieve connection runtime URLs |
| 6 | Assign RBAC roles (Website Contributor, Log Analytics Reader, Reader on source workspace) |
| 7 | Stage `workflow.json` and `connections.json` into a temp directory, substitute `{{placeholders}}` with deployment values (source files are never modified) |
| 8 | Deploy workflow to Logic App via `func azure functionapp publish` from the staged temp directory |
| 9 | Restart Logic App to apply permissions |

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
| `{{AZURE_MONITOR_LOGS_RUNTIME_URL}}` | Azure Monitor Logs API connection runtime URL (in `connections.json`) | Azure Portal → API Connections → azuremonitorlogs → Properties |
| `{{AZURE_BLOB_RUNTIME_URL}}` | Azure Blob API connection runtime URL (in `connections.json`) | Azure Portal → API Connections → azureblob → Properties |

> **Note:** The full deployment script (`Deploy-ChargeBackLogicApp-v2.ps1`) handles all placeholder substitution automatically using a temp-directory staging approach — source files are never overwritten. Manual replacement is only needed for workflow-only deployments.

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
| Blob Container | `reportoutput` | Container for daily CSV reports |
| Log Analytics Workspace | `law-chargeback-{suffix}` | Error logging and chunk staging |
| Custom Table | `WorkflowFailures_CL` | Schema for workflow error records |
| Custom Table | `ChargeBackChunks_CL` | Intermediate staging for 12 chunk results per run |
| Data Collection Endpoint | `dce-chargeback-{suffix}` | Log ingestion endpoint |
| Data Collection Rule | `dcr-chargeback-{suffix}` | Routes errors + chunk data to custom tables |

### API Connections (via PowerShell)

- **azuremonitorlogs** - V2 connection with managed identity authentication
- **azureblob** - V2 connection with managed identity authentication
- Both connections configured with access policies granting user-assigned managed identity access

### RBAC Role Assignments

All RBAC roles are assigned to the **user-assigned managed identity** (`id-chargeback-{suffix}`):

| Role | Scope | Purpose | Assigned By |
|------|-------|---------|-------------|
| Storage Blob Data Contributor | Report storage account | Write CSV reports | Bicep |
| Monitoring Metrics Publisher | Data Collection Rule | Ingest error logs and chunk data | Bicep |
| Monitoring Metrics Publisher | Data Collection Endpoint | Send logs to DCE | Bicep |
| Log Analytics Reader | Source workspace | Query LLM logs | Bicep + PowerShell |
| Log Analytics Reader | Error workspace | Query `ChargeBackChunks_CL` for ingestion polling and daily aggregation | Bicep |
| Reader | Source workspace | Read workspace metadata | PowerShell |
| Website Contributor | Logic App resource | Dynamic schema retrieval | PowerShell |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Resource Group                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────┐                                                       │
│  │  User-Assigned   │◀─── Used by Logic App & API Connections               │
│  │ Managed Identity │                                                       │
│  └────────┬─────────┘                                                       │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Logic App (Standard)                                                │   │
│  │  ┌─ CreateChargeBackReport ──────────────────────────────────────┐  │   │
│  │  │ Recurrence Trigger (every 24h)                                │  │   │
│  │  │   │                                                           │  │   │
│  │  │   ▼  Initialize_Time_Chunks / ReportDate / WorkflowRunId /    │  │   │
│  │  │      ExpectedChunkCount                                       │  │   │
│  │  │   │                                                           │  │   │
│  │  │   ▼                                                           │  │   │
│  │  │ ┌─ Process_Time_Chunks (ForEach, sequential) ──────────────┐  │  │   │
│  │  │ │  Submit_Chunk_Query (Prefer: wait=60)                    │  │  │   │
│  │  │ │    │ 200 (sync) / 202 (async → Poll_Chunk_Results)       │  │  │   │
│  │  │ │  Get_Chunk_Results → Transform_Chunk_To_Objects          │  │  │   │
│  │  │ │  Enrich_Chunk_Rows (adds ReportDate/WorkflowRunId/Chunk) │  │  │   │
│  │  │ │  Write_Chunk_To_Logs_If_Has_Rows                         │  │  │   │
│  │  │ │    ├─[has rows]─▶ Post_Chunk_Batches (500 rows/batch)    │  │  │   │
│  │  │ │    │               + Increment_Expected_Chunk_Count      │  │  │   │
│  │  │ │    └─[empty]────▶ (no-op)                                │  │  │   │
│  │  │ └─────────────────────────────────────────────────────────┘  │  │   │
│  │  │   │                                                           │  │   │
│  │  │   ▼ Fail_If_Batch_Write_Failed (terminates if any POST failed)│  │   │
│  │  │   ▼ Wait_Before_Ingestion_Poll (30s)                          │  │   │
│  │  │   ▼ Poll_For_Ingestion (Until dcount(ChunkId)>=Expected,      │  │   │
│  │  │                         30s interval, 20min timeout)          │  │   │
│  │  │   │                                                           │  │   │
│  │  │   ▼ Submit_Daily_Query (ChargeBackChunks_CL, by WorkflowRunId)│  │   │
│  │  │   ▼ Check_Daily_Sync_Or_Async → Get_Daily_Results            │  │   │
│  │  │   ▼ Transform_Daily_To_Objects → Create_Daily_CSV            │  │   │
│  │  │   ▼ Write_Daily_Report_Blob                                  │  │   │
│  │  │     Output: chargeBack-daily-YYYY-MM-DD-HHmmss.csv           │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│           │                                                                │
│  ┌────────┴───────┐  ┌────────────────────────────────────────┐           │
│  │ Storage (lacb*)│  │ Storage (rptcb*)                       │           │
│  │ Internal       │  │ reportoutput/                          │           │
│  │ (Key Auth)     │  │   chargeBack-daily-2026-03-09-143022.csv│           │
│  └────────────────┘  │ (Managed ID Only, 1 file per run)     │           │
│                      └────────────────────────────────────────┘           │
│                                                                            │
│  ┌────────────────┐  ┌────────────────────────────────────────┐           │
│  │ DCE/DCR        │─▶│ Error Workspace (law-chargeback-*)      │           │
│  │ (two streams)  │  │  WorkflowFailures_CL  (error logs)     │           │
│  └────────────────┘  │  ChargeBackChunks_CL  (chunk staging)  │           │
│                      └────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────────────┘
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

## KQL Queries

### Chunk Query (Source Workspace — runs 12 times per workflow execution)

Executed against the **source Log Analytics workspace** (APIM logs) for each 2-hour time chunk. Results are staged into `ChargeBackChunks_CL` via the Logs Ingestion API:

```kql
// Compute time window: covers 24h ending at REPORT_END_HOUR yesterday
let reportEnd = datetime_add('hour', int(REPORT_END_HOUR), startofday(now() - 1d));
let chunkStart = datetime_add('hour', -hoursAgo, reportEnd);
let chunkEnd   = datetime_add('hour', -hoursUntil, reportEnd);

// Pre-aggregate LLM log data before joining (reduces memory usage)
let llmAgg = ApiManagementGatewayLlmLog
| where TimeGenerated >= chunkStart and TimeGenerated < chunkEnd
| where SequenceNumber == 0
| summarize
    TotalTokens       = sum(TotalTokens),
    CompletionTokens  = sum(CompletionTokens),
    PromptTokens      = sum(PromptTokens)
    by CorrelationId;

// Main query with shuffle hint for distributed join processing
ApiManagementGatewayLogs
| where TimeGenerated >= chunkStart and TimeGenerated < chunkEnd
| where IsRequestSuccess
| join hint.strategy=shuffle kind=inner llmAgg on CorrelationId
| extend ParsedUrl = parse_url(BackendUrl)
| extend ExtractedEndpoint = strcat(tostring(ParsedUrl.Scheme), '://', tostring(ParsedUrl.Host), '/')
| extend DeploymentFromUrl = extract('/openai/deployments/([^/]+)/', 1, BackendUrl)
| extend
    Luma      = extract('^([0-9]{6})', 1, ApimSubscriptionId),
    Workspace = extract('^[0-9]{6}-(.+)$', 1, ApimSubscriptionId)
| join kind=leftouter (
    CognitiveServicesInventory_CL
    | summarize arg_max(TimeGenerated, *) by AccountEndpoint, DeploymentName
    | project
        AccountEndpoint,
        CogSvcDeploymentName  = DeploymentName,
        CogSvcModelName       = ModelName,
        CogSvcSkuName         = SkuName,
        CogSvcSkuCapacity     = SkuCapacity,
        CogSvcAccountName     = AccountName,
        CogSvcSubscriptionId  = SubscriptionId,
        CogSvcAccountId       = AccountId
) on $left.ExtractedEndpoint == $right.AccountEndpoint,
   $left.DeploymentFromUrl   == $right.CogSvcDeploymentName
| summarize
    TotalTokens      = sum(TotalTokens),
    CompletionTokens = sum(CompletionTokens),
    PromptTokens     = sum(PromptTokens),
    FirstSeen        = min(TimeGenerated),
    LastSeen         = max(TimeGenerated),
    Regions          = strcat_array(make_set(Region, 8), '; '),
    CallerIpAddresses = strcat_array(make_set(CallerIpAddress, 8), '; '),
    Calls = count()
    by ProductId, DeploymentFromUrl, ExtractedEndpoint, BackendId,
       CogSvcModelName, CogSvcSkuName, CogSvcSkuCapacity, CogSvcAccountName,
       CogSvcSubscriptionId, CogSvcAccountId, Luma, Workspace
| project
    ProductId,
    Luma,
    Workspace,
    DeploymentName = DeploymentFromUrl,
    ModelName      = CogSvcModelName,
    AccountName    = CogSvcAccountName,
    SubscriptionId = CogSvcSubscriptionId,
    ResourceID     = CogSvcAccountId,
    SkuName        = CogSvcSkuName,
    SkuCapacity    = CogSvcSkuCapacity,
    BackendId,
    Endpoint       = ExtractedEndpoint,
    PromptTokens, CompletionTokens, TotalTokens, Calls,
    FirstSeen, LastSeen, Regions, CallerIpAddresses
| order by ProductId asc, TotalTokens desc
```

### Daily Aggregation Query (Error Workspace — runs once per workflow execution)

Executed against the **error workspace** (`ChargeBackChunks_CL`) after all chunks have been ingested. Combines all 12 chunk summaries into a single daily total per ProductId + Deployment, filtered by `WorkflowRunId` to prevent duplication on re-runs:

```kql
let runId = '<WorkflowRunId>';
let reportDate = '<ReportDate>';
union isfuzzy=true ChargeBackChunks_CL
| where ReportDate == reportDate and WorkflowRunId == runId
| summarize
    TotalTokens      = sum(TotalTokens),
    CompletionTokens = sum(CompletionTokens),
    PromptTokens     = sum(PromptTokens),
    FirstSeen        = min(FirstSeen),
    LastSeen         = max(LastSeen),
    Regions          = strcat_array(make_set(Regions), '; '),
    CallerIpAddresses = strcat_array(make_set(CallerIpAddresses), '; '),
    Calls            = sum(Calls)
    by ProductId, Luma, Workspace, DeploymentName, ModelName, AccountName,
       SubscriptionId, ResourceID, SkuName, SkuCapacity, BackendId, Endpoint
| project ProductId, Luma, Workspace, DeploymentName, ModelName, AccountName,
          SubscriptionId, ResourceID, SkuName, SkuCapacity, BackendId, Endpoint,
          PromptTokens, CompletionTokens, TotalTokens, Calls,
          FirstSeen, LastSeen, Regions, CallerIpAddresses
| order by ProductId asc, TotalTokens desc
```

`isfuzzy=true` is used to handle the case where `ChargeBackChunks_CL` does not yet exist or has not propagated on the first run.

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
| 7 | ResourceID | Azure resource ID of the Cognitive Services account |
| 8 | SkuName | SKU name (e.g., ProvisionedManaged) |
| 9 | SkuCapacity | Provisioned capacity (PTU/TPM) |
| 10 | BackendId | APIM backend identifier |
| 11 | Endpoint | Azure OpenAI endpoint URL |
| 12 | PromptTokens | Total prompt tokens consumed |
| 13 | CompletionTokens | Total completion tokens generated |
| 14 | TotalTokens | Sum of prompt + completion tokens |
| 15 | Calls | Number of API calls |
| 16 | FirstSeen | Earliest request timestamp |
| 17 | LastSeen | Latest request timestamp |
| 18 | Regions | Semicolon-delimited list of Azure regions (max 8) |
| 19 | CallerIpAddresses | Semicolon-delimited list of caller IPs (max 8) |

> **Important:** If you modify the `project` clause in the KQL query, you must also update the positional indexes in `Transform_Chunk_To_Objects` in `workflow.json` to match.

## Post-Deployment

### Monitor

- **Report Output**: Check blob storage container `reportoutput` for daily files (`chargeBack-daily-*.csv`). Each workflow run produces one file with a unique date-time stamp, preserving history across re-runs
- **Workflow Runs**: View run history in Logic App portal → Workflows → CreateChargeBackReport- **Chunk Staging**: Query `ChargeBackChunks_CL` in the error workspace to inspect staged data per run:

```kql
ChargeBackChunks_CL
| summarize Chunks = dcount(ChunkId), Rows = count() by WorkflowRunId, ReportDate
| order by ReportDate desc
```
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
- Confirm the managed identity has both **Log Analytics Reader** and **Reader** roles on the **source workspace**
- Confirm the managed identity has **Log Analytics Reader** on the **error workspace** (`law-chargeback-{suffix}`) — required for `Poll_For_Ingestion` and `Submit_Daily_Query`
- Ensure `ApiManagementGatewayLogs`, `ApiManagementGatewayLlmLog`, and `CognitiveServicesInventory_CL` tables exist in the source workspace
- Restart the Logic App after RBAC changes

### Ingestion Polling Timeout

If `Poll_For_Ingestion` times out (20 minutes) without seeing all expected chunks:
- Check `Check_Ingestion_Count` action outputs in the run history — the response body will show the `IngestedChunks` count vs. `ExpectedChunkCount`
- Verify `Write_Chunk_To_Logs` succeeded for each chunk (if a chunk write failed, `ExpectedChunkCount` will not include it)
- First-time ingestion into a new `ChargeBackChunks_CL` table can take up to 30 minutes. Subsequent runs are typically 2–5 minutes
- `Submit_Daily_Query` still runs after timeout (`runAfter: [Succeeded, TimedOut]`) and will succeed once data has landed
- To query manually: `ChargeBackChunks_CL | summarize dcount(ChunkId) by WorkflowRunId` in the error workspace

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

The daily output filename is built in the `Write_Daily_Report_Blob` action:
```
chargeBack-daily-@{variables('ReportDate')}-@{formatDateTime(utcNow(), 'HHmmss')}.csv
```

Each run produces a unique file. Previous runs are preserved. To change the pattern, edit the `name` field in the `queries` block of `Write_Daily_Report_Blob` in `CreateChargeBackReport/workflow.json`.

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

4. **Time Chunking with Intermediate Staging**: To avoid the 5GB memory limit on Log Analytics joins, the workflow splits queries into 12 x 2-hour chunks. Each chunk is written to `ChargeBackChunks_CL` (error workspace) via the Logs Ingestion API, then re-aggregated by a single KQL query into one daily CSV. A smart polling loop waits up to 20 minutes for all chunks to become queryable before running the final aggregation. `WorkflowRunId` tagging makes re-runs idempotent — each run writes a uniquely named output file.

5. **Pre-Aggregation in KQL**: The KQL query pre-aggregates the `ApiManagementGatewayLlmLog` table before joining, and uses `strcat_array(make_set(...), '; ')` to produce string fields for Regions and CallerIpAddresses, ensuring CSV compatibility.

6. **Positional Column Mapping**: `Transform_Chunk_To_Objects` uses `@item()[N]` positional indexes rather than column-name lookups, because Logic App Standard expression language does not support `where()`/`first()`/`indexOf()` functions on arrays.

7. **Storage Cache**: Logic App Standard stores workflow definitions in an Azure Files share. When redeploying, if old definitions persist, delete both the Logic App and its backing storage account before redeploying.

8. **Resource Naming**: All resource names include a deterministic suffix generated by `uniqueString(resourceGroup().id)` to ensure uniqueness across Azure.

9. **Pure Logic App Solution**: This workflow runs entirely within Logic App Standard with no external dependencies on Azure Functions or JavaScript code actions, ensuring full compatibility with .NET-based runtimes.

## License

Internal Microsoft use only.

## Support

For issues or questions, contact the Logic Apps development team.
