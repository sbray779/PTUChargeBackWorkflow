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

The `CreateChargeBackReport` workflow uses an **asynchronous query pattern** against the Log Analytics REST API to avoid HTTP timeouts on long-running queries:

1. **Submit_Async_Query** — Sends the KQL query to the Log Analytics REST API with `Prefer: wait=0` header, which returns immediately with either a `200` (results ready) or `202` (query accepted, poll for results)
2. **Check_If_Query_Completed_Synchronously** — Branches based on the HTTP status code:
   - **200 path**: Results returned inline → `Set_Sync_Results`
   - **202 path**: Captures the `Location` header → waits 10 seconds → enters polling loop
3. **Poll_For_Query_Results** — An Until loop that polls the Location URL every 15 seconds (up to 60 iterations / 30 minutes) via `Check_Query_Status` until the query completes with HTTP 200
4. **Merge_Query_Results** — Selects the final result body from whichever path was taken
5. **Transform_Query_Results_To_Rows** — Converts the columnar Log Analytics response (`tables[0].rows`) into named objects using positional array indexes matching the KQL `project` clause
6. **Create_CSV_table** — Converts the row objects to CSV format
7. **Create_blob_(V2)** — Uploads the CSV to blob storage at `reportoutput/dailyChargeBackReport.csv`

**Error Handlers** (run on failure/timeout of upstream actions):
- **Handle_Query_Failure** — Logs query errors to a custom Log Analytics table via Data Collection Rules
- **Handle_Blob_Write_Failure** — Logs blob write errors to the same custom table

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
5. Verify the CSV appears in storage: `rptcb{suffix}/reportoutput/dailyChargeBackReport.csv`

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
| App Service Plan | `asp-chargeback-{suffix}` | WS1 SKU for Logic Apps Standard |
| User-Assigned Managed Identity | `id-chargeback-{suffix}` | Centralized authentication for all services |
| Logic App | `logic-chargeback-{suffix}` | Workflow engine |
| Logic App Storage | `lacb{suffix}` | Internal runtime storage (key-based auth required) |
| Report Storage | `rptcb{suffix}` | CSV report output (managed identity only, no keys) |
| Blob Container | `reportoutput` | Container for daily CSV reports |
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
┌─────────────────────────────────────────────────────────────────┐
│ Resource Group                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐                                          │
│  │  User-Assigned   │◀─── Used by Logic App & API Connections  │
│  │ Managed Identity │                                          │
│  └────────┬─────────┘                                          │
│           │                                                     │
│           ▼                                                     │
│  ┌──────────────────────────────────────────────┐              │
│  │ Logic App (Standard)                         │              │
│  │                                              │              │
│  │  ┌─ CreateChargeBackReport ───────────────┐  │              │
│  │  │ Recurrence Trigger (every 24h)         │  │              │
│  │  │        │                               │  │              │
│  │  │        ▼                               │  │              │
│  │  │ Submit_Async_Query (HTTP POST)         │  │              │
│  │  │ Prefer: wait=0                        │  │              │
│  │  │        │                               │  │              │
│  │  │    ┌───┴───┐                           │  │              │
│  │  │  200?    202?                          │  │              │
│  │  │    │       │                           │  │              │
│  │  │  Sync   Poll_For_Query_Results         │  │              │
│  │  │  Path   (Until loop, 15s intervals)    │  │              │
│  │  │    │       │                           │  │              │
│  │  │    └───┬───┘                           │  │              │
│  │  │        ▼                               │  │              │
│  │  │ Merge_Query_Results                    │  │              │
│  │  │        ▼                               │  │              │
│  │  │ Transform_Query_Results_To_Rows        │  │              │
│  │  │ (Select: @item()[0]..@item()[11])      │  │              │
│  │  │        ▼                               │  │              │
│  │  │ Create_CSV_table → Create_blob_(V2)    │  │              │
│  │  └────────────────────────────────────────┘  │              │
│  └──────────────────────────────────────────────┘              │
│           │                            │                       │
│           ▼                            ▼                       │
│  ┌──────────────────┐  ┌──────────────────┐                   │
│  │ Storage (lacb*)  │  │ Storage (rptcb*) │                   │
│  │ Internal/Runtime │  │ reportoutput/    │                   │
│  │ (Key Auth)       │  │ dailyChargeback  │                   │
│  └──────────────────┘  │ Report.csv       │                   │
│                        │ (Managed ID Only)│                   │
│                        └──────────────────┘                   │
│                                                                │
│  ┌──────────────────┐  ┌──────────────────┐                   │
│  │ DCE/DCR          │─▶│ Error Workspace  │                   │
│  │ Error Logging    │  │ WorkflowFailures │                   │
│  └──────────────────┘  │ _CL              │                   │
│                        └──────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────┐
│ Source Log Analytics         │
│ (External Resource Group)    │
│ ApiManagementGatewayLogs     │
│ ApiManagementGatewayLlmLog   │
└──────────────────────────────┘
```

## KQL Query

The workflow executes this query against the source Log Analytics workspace:

```kql
ApiManagementGatewayLogs 
| where TimeGenerated >= ago(24h) 
| join kind=inner ApiManagementGatewayLlmLog on CorrelationId 
| where SequenceNumber == 0 and IsRequestSuccess 
| summarize 
    TotalTokens = sum(TotalTokens), 
    CompletionTokens = sum(CompletionTokens), 
    PromptTokens = sum(PromptTokens), 
    FirstSeen = min(TimeGenerated), 
    LastSeen = max(TimeGenerated), 
    Regions = make_set(Region, 8), 
    CallerIpAddresses = make_set(CallerIpAddress, 8), 
    Caches = make_set(Cache, 8), 
    BackendIds = make_set(BackendId, 8), 
    Calls = count() 
    by ProductId, ModelName 
| project ProductId, ModelName, PromptTokens, CompletionTokens, TotalTokens, Calls, FirstSeen, LastSeen, Regions, CallerIpAddresses, Caches, BackendIds 
| order by TotalTokens desc
```

The `Transform_Query_Results_To_Rows` action maps the columnar result to named fields using positional indexes that match the `project` clause order:

| Index | Column |
|-------|--------|
| 0 | ProductId |
| 1 | ModelName |
| 2 | PromptTokens |
| 3 | CompletionTokens |
| 4 | TotalTokens |
| 5 | Calls |
| 6 | FirstSeen |
| 7 | LastSeen |
| 8 | Regions |
| 9 | CallerIpAddresses |
| 10 | Caches |
| 11 | BackendIds |

> **Important:** If you modify the `project` clause in the KQL query, you must also update the positional indexes in `Transform_Query_Results_To_Rows` in `workflow.json` to match.

## Post-Deployment

### Monitor

- **Report Output**: Check blob storage container `reportoutput` for `dailyChargeBackReport.csv`
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
- Ensure `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog` tables exist in the workspace
- Restart the Logic App after RBAC changes

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

Edit the `query` field in the `Submit_Async_Query` action in [CreateChargeBackReport/workflow.json](CreateChargeBackReport/workflow.json). If you change the `project` columns, you must also update the positional indexes in `Transform_Query_Results_To_Rows` to match (see column index table above).

### Change Schedule

Edit `Recurrence` trigger:
```json
"recurrence": {
  "interval": 24,
  "frequency": "Hour",
  "timeZone": "Central Standard Time"
}
```

### Modify Report Name/Path

Edit `Create_blob_(V2)` action `queries`:
```json
"queries": {
  "folderPath": "reportoutput",
  "name": "dailyChargeBackReport.csv",
  "queryParametersSingleEncoded": true
}
```

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

4. **Positional Column Mapping**: `Transform_Query_Results_To_Rows` uses `@item()[N]` positional indexes rather than column-name lookups, because Logic App Standard expression language does not support `where()`/`first()`/`indexOf()` functions on arrays.

5. **Storage Cache**: Logic App Standard stores workflow definitions in an Azure Files share. When redeploying, if old definitions persist, delete both the Logic App and its backing storage account before redeploying.

6. **Resource Naming**: All resource names include a deterministic suffix generated by `uniqueString(resourceGroup().id)` to ensure uniqueness across Azure.

## License

Internal Microsoft use only.

## Support

For issues or questions, contact the Logic Apps development team.
