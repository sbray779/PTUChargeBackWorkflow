# ChargeBack Logic App Deployment

This repository contains an automated deployment solution for an Azure Logic App (Standard) that generates daily chargeback reports from API Management LLM usage logs.

It is assumed that there is an existing APIM instance being used as an AI Gateway and that LLM logging has been enabled on desired APIs which are sending prompt/response logs to an existing
log analytics workspace.  This solution is designed to do the following:

1) Query the target log analytics workspace, summarize token utilization by product/subscritpin
2) Summarize the data into CSV format
3) Send the data to blob storage for later retrieval

By default, the workflow is triggered daily.

## Overview

The solution uses **Bicep templates** and **PowerShell** to deploy a complete infrastructure including:
- **Logic App (Standard)** - Workflow engine with system-assigned managed identity
- **API Connections** - Azure Monitor Logs and Azure Blob Storage (V2) with managed identity authentication
- **Storage Accounts** - Separate accounts for Logic App internal storage and report output
- **Log Analytics Workspace** - Error logging and monitoring
- **Data Collection Rule/Endpoint** - Custom log ingestion for workflow errors
- **RBAC Assignments** - All necessary permissions configured automatically

## Workflow Features

The deployed workflow:
1. **Queries Log Analytics** daily for LLM token usage from ApiManagementGatewayLogs and ApiManagementGatewayLlmLog
2. **Aggregates data** by ProductId and ModelName with token counts, call counts, and metadata (regions, IPs, caches, backends)
3. **Generates CSV report** and uploads to blob storage container
4. **Error Handling** - Logs query failures and blob write failures to custom Log Analytics table via Data Collection Rules
5. **Managed Identity** - All authentication uses system-assigned managed identity (no keys/secrets)

## Prerequisites

- **Azure CLI** installed and authenticated (`az login`)
- **Bicep CLI** installed (included with Azure CLI or install via `az bicep install`)
- **Azure Functions Core Tools** installed (`func`) - for workflow deployment
- **PowerShell 7.0 or later**
- **Contributor access** to the target Azure subscription
- An **existing Log Analytics workspace** containing `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog` tables

## Deployment

### Step 1: Configure Parameters
### Ensure that the sourceLogAnalyticsWorkspace and sourceWorkspaceResourceGroup parameters point to 
### the existing log analytics workspace to which LLM logs are being sent from the APIM AI Gateway
Edit the `deploy-infrastructure.bicepparam` file:

```bicep
using './deploy-infrastructure.bicep'

param resourceGroupName = 'rg-chargeback-prod'
param location = 'eastus2'
param sourceLogAnalyticsWorkspace = 'MyLLMLogsWorkspace'
param sourceWorkspaceResourceGroup = 'MyLLMLogsWorkspace-RG'
```

### Step 2: Run Deployment Script

```powershell
.\Deploy-ChargeBackLogicApp-v2.ps1
```

The script will automatically:
1. Create or verify the resource group
2. Deploy infrastructure using Bicep
3. Create API connections with access policies
4. Retrieve connection runtime URLs
5. Assign all required RBAC roles
6. Update workflow with deployment-specific values
7. Deploy workflow to Logic App
8. Restart Logic App to apply permissions

### Parameters (in bicepparam file)

| Parameter | Required | Description | Example |
|-----------|----------|-------------|---------|
| `resourceGroupName` | Yes | Name of the resource group for deployment | `rg-chargeback-prod` |
| `location` | Yes | Azure region for deployment | `eastus2` |
| `sourceLogAnalyticsWorkspace` | Yes | Name of workspace containing LLM logs | `MyLLMLogsWorkspace` |
| `sourceWorkspaceResourceGroup` | Yes | Resource group of source workspace | `MyLLMLogsWorkspace-RG` |

## What Gets Deployed

### Infrastructure Resources (via Bicep)

1. **App Service Plan** - `asp-chargeback-{uniqueSuffix}` (WS1 SKU for Logic Apps)
2. **Logic App** - `logic-chargeback-{uniqueSuffix}` with system-assigned managed identity
3. **Logic App Storage Account** - `lacb{uniqueSuffix}` with key-based auth (required for Logic App runtime)
4. **File Share** - Created in Logic App storage for internal operations
5. **Report Storage Account** - `rptcb{uniqueSuffix}` with managed identity only (no keys)
6. **Blob Container** - `reportoutput` in report storage for CSV files
7. **Log Analytics Workspace** - `law-chargeback-{uniqueSuffix}` for error logging
8. **Custom Log Table** - `WorkflowFailures_CL` with schema for error tracking
9. **Data Collection Endpoint** - `dce-chargeback-{uniqueSuffix}` for log ingestion
10. **Data Collection Rule** - `dcr-chargeback-{uniqueSuffix}` routes errors to custom table

### API Connections (via PowerShell)

- **azuremonitorlogs** - V2 connection with managed identity authentication
- **azureblob** - V2 connection with managed identity authentication
- Both connections configured with access policies granting Logic App identity access

### RBAC Role Assignments

| Role | Scope | Purpose | Assigned By |
|------|-------|---------|-------------|
| Storage Blob Data Contributor | Report storage account | Write CSV reports | Bicep |
| Monitoring Metrics Publisher | Data Collection Rule | Ingest error logs | Bicep |
| Monitoring Metrics Publisher | Data Collection Endpoint | Send logs to DCE | Bicep |
| Website Contributor | Logic App resource | Dynamic schema retrieval | PowerShell |
| Reader | Source workspace | Read workspace metadata | PowerShell |
| Log Analytics Reader | Source workspace | Query LLM logs | PowerShell |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Resource Group: rg-chargeback-prod                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────┐            │
│  │   Logic App      │────────▶│  API Connection  │            │
│  │   (Standard)     │         │  azuremonitorlogs│            │
│  └────────┬─────────┘         └────────┬─────────┘            │
│           │                            │                       │
│           │ Managed Identity           │                       │
│           │                            ▼                       │
│           │                   ┌─────────────────────┐         │
│           │                   │ Source Log Analytics│         │
│           │                   │   (External RG)     │         │
│           │                   └─────────────────────┘         │
│           │                                                    │
│           │         ┌──────────────────┐                      │
│           │────────▶│  API Connection  │                      │
│           │         │    azureblob     │                      │
│           │         └────────┬─────────┘                      │
│           │                  │                                │
│           ▼                  ▼                                │
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │ Storage (lacb*)  │  │ Storage (rptcb*) │                 │
│  │ Internal/Runtime │  │ CSV Reports Only │                 │
│  │ (Key Auth)       │  │ (Managed ID Only)│                 │
│  └──────────────────┘  └──────────────────┘                 │
│                                                                │
│  ┌──────────────────┐         ┌──────────────────┐           │
│  │   DCE/DCR        │────────▶│  Error Workspace │           │
│  │   Error Logging  │         │  (Custom Table)  │           │
│  └──────────────────┘         └──────────────────┘           │
│                                                                │
└─────────────────────────────────────────────────────────────────┘
```

## Workflow Details

### Trigger
- **Type**: Recurrence
- **Schedule**: Every 24 hours
- **Timezone**: Central Standard Time

### Actions

1. **Run_query_and_list_results**
   - Queries ApiManagementGatewayLogs for last 24 hours
   - Joins with ApiManagementGatewayLlmLog for token metrics
   - Aggregates by ProductId and ModelName

2. **Create_CSV_table**
   - Converts query results to CSV format

3. **Create_blob_(V2)**
   - Uploads CSV to `reportoutput/dailyChargeBackReport.csv`
   - Overwrites existing report

4. **Handle_Query_Failure** (error handler)
   - Triggers on query timeout/failure
   - Logs error details to WorkflowFailures_CL table via DCR

5. **Handle_Blob_Write_Failure** (error handler)
   - Triggers on blob write timeout/failure
   - Logs error details to WorkflowFailures_CL table via DCR

### KQL Query

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

## Post-Deployment

### Verify Deployment

1. **Check Logic App**
   ```powershell
   az logicapp show --name logic-chargeback-{uniqueSuffix} --resource-group rg-chargeback-prod
   ```

2. **View Workflow in Portal**
   - Navigate to Logic App → Workflows → CreateChargeBackReport
   - Verify connections show as "Connected" with managed identity

3. **Test Workflow**
   - In portal, click "Run Trigger" to manually test
   - Check run history for success/failure
   - Verify CSV appears in storage: `rptcb{suffix}/reportoutput/dailyChargeBackReport.csv`

### Monitor

- **Report Output**: Check blob storage container `reportoutput` for `dailyChargeBackReport.csv`
- **Error Logs**: Query `WorkflowFailures_CL` table in error workspace
- **Workflow Runs**: View run history in Logic App portal

### Query Errors

```kql
WorkflowFailures_CL
| where TimeGenerated >= ago(7d)
| project TimeGenerated, WorkflowName, FailureType, ActionName, ErrorCode, ErrorMessage, Severity
| order by TimeGenerated desc
```

## Troubleshooting

### Connection Errors

If connections show as "Invalid" or "Forbidden":
1. Verify Logic App has system-assigned managed identity enabled in Azure Portal
2. Check RBAC role assignments are properly configured
3. Wait 30-60 seconds for permissions to propagate
4. Restart the Logic App to refresh identity token:
   ```powershell
   az logicapp restart --name logic-chargeback-{uniqueSuffix} --resource-group rg-chargeback-prod
   ```

### Query Failures (InsufficientAccessError)

- Verify source workspace name and resource group are correct in parameters file
- Check Logic App has **both** Log Analytics Reader and Reader roles on source workspace
- Ensure `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog` tables exist
- Wait 30-60 seconds after RBAC assignment, then restart Logic App

### Blob Write Failures

- Verify report storage account has `allowSharedKeyAccess: false` (managed identity only)
- Check Storage Blob Data Contributor role assignment via Bicep deployment
- Ensure `reportoutput` container exists
- Verify container has no public access configured

### Dynamic Schema Errors

If you see "Failed to retrieve dynamic outputs":
- Verify Website Contributor role is assigned to Logic App on itself
- Restart Logic App after RBAC changes
- Wait for permissions to propagate (up to 5 minutes)

### Error Handling Not Working

- Verify DCR and DCE exist and are properly configured
- Check Monitoring Metrics Publisher roles on both DCR and DCE (assigned via Bicep)
- Restart Logic App to refresh permissions
- Verify DCE public network access is enabled

## Customization

### Modify Query

Edit the `body` field in `Run_query_and_list_results` action in [CreateChargeBackReport/workflow.json](CreateChargeBackReport/workflow.json):
- Keep the query as a single-line string
- Test query in Log Analytics first before deploying

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
LogicApp/
├── Deploy-ChargeBackLogicApp.ps1          # Main deployment script
├── README.md                               # This file
└── TokenUsage/
    └── TokenUtilization/
        ├── host.json                       # Logic App host configuration
        ├── local.settings.json             # Local development settings
        ├── connections.json                # Template for API connections (ignored in deployment)
        └── CreateChargeBackReport/
            └── workflow.json               # Workflow definition
```

## Important Notes

1. **connections.json in .funcignore**: The `connections.json` file is excluded from deployment. Connections are created in the portal after workflow deployment.

2. **Identity Token Refresh**: After deployment, the Logic App is restarted automatically to refresh the managed identity token and pick up new RBAC assignments.

3. **Resource Naming**: Resource names include random suffixes to ensure uniqueness across Azure.

4. **Connection Names**: API connections are named `azuremonitorlogs` and `azureblob` (without suffixes) to match workflow references.

5. **DCR/DCE URLs**: Error handling URIs are updated automatically during deployment with the newly created DCR/DCE details.

## License

Internal Microsoft use only.

## Support

For issues or questions, contact the Logic Apps development team.
