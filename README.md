# CreateChargeBackReport Logic App Workflow

## Overview

This Azure Logic App (Standard) workflow automates the daily generation of AI/LLM usage chargeback reports by:
1. Querying Azure Monitor Logs for API Management gateway logs enriched with LLM usage data
2. Converting query results to CSV format
3. Writing the CSV report to Azure Blob Storage
4. Logging any failures to a custom Log Analytics workspace for monitoring and alerting

The workflow uses **managed identity authentication** throughout, eliminating the need for connection strings or API keys.

---

## Workflow Architecture

### Workflow Actions

1. **Run_query_and_list_results**
   - Type: ApiConnection (Azure Monitor Logs)
   - Purpose: Executes a KQL query joining API Management Gateway Logs with LLM usage data
   - Output: Query results containing token usage, costs, and request details
   - Authentication: Managed Identity

2. **Create_CSV_table**
   - Type: Table (built-in)
   - Purpose: Converts JSON query results to CSV format
   - Input: Results from query action
   - Output: CSV-formatted string

3. **Create_blob_(V2)**
   - Type: ApiConnection (Azure Blob Storage)
   - Purpose: Writes CSV data to blob storage
   - Target: `reportoutput/dailyChargeBackReport.csv`
   - Authentication: Managed Identity

4. **Handle_Query_Failure** (Error Handler)
   - Type: HTTP
   - Purpose: Logs query failures to custom Log Analytics table
   - Triggers on: FAILED, TIMEDOUT, SKIPPED status of Run_query_and_list_results
   - Authentication: Managed Identity (audience: https://monitor.azure.com)

5. **Handle_Blob_Write_Failure** (Error Handler)
   - Type: HTTP
   - Purpose: Logs blob write failures to custom Log Analytics table
   - Triggers on: FAILED, TIMEDOUT, SKIPPED status of Create_blob_(V2)
   - Authentication: Managed Identity (audience: https://monitor.azure.com)

### Error Logging Schema

Failures are logged to the `WorkflowFailures_CL` custom table with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| TimeGenerated | datetime | Timestamp of the failure |
| WorkflowName | string | Name of the workflow (CreateChargeBackReport) |
| WorkflowRunId | string | Unique identifier for the workflow run |
| FailureType | string | Type of failure (QueryFailure or BlobWriteFailure) |
| ActionName | string | Name of the action that failed |
| ErrorCode | string | Error code from the failed action |
| ErrorMessage | string | Detailed error message |
| Severity | string | Severity level (High, Medium, Low) |
| BlobPath | string | Target blob path (for blob write failures) |

---

## Prerequisites

### 1. Azure Resources Required

#### Source Log Analytics Workspace
- **Purpose**: Contains API Management Gateway Logs and LLM usage data for querying
- **Required Tables**: 
  - `ApiManagementGatewayLogs`
  - Custom LLM usage logs table
- **Resource ID Example**: `/subscriptions/{subscription-id}/resourceGroups/{rg-name}/providers/Microsoft.OperationalInsights/workspaces/{workspace-name}`

#### Error Logging Log Analytics Workspace
- **Purpose**: Stores workflow failure events
- **Custom Table**: `WorkflowFailures_CL` (created via Data Collection Rules)
- **Retention**: 30 days (configurable)
- **Resource ID Example**: `/subscriptions/{subscription-id}/resourceGroups/{rg-name}/providers/Microsoft.OperationalInsights/workspaces/logicapperrorhandling`

#### Data Collection Endpoint (DCE)
- **Purpose**: Ingestion endpoint for custom logs
- **Location**: Same region as Log Analytics workspace (e.g., eastus2)
- **Creation**:
  ```bash
  az monitor data-collection endpoint create \
    --name dce-workflowerrors \
    --resource-group {resource-group} \
    --location {location} \
    --public-network-access Enabled
  ```
- **Output**: Note the endpoint URI (e.g., `https://dce-workflowerrors-xxxx.{region}-1.ingest.monitor.azure.com`)

#### Data Collection Rule (DCR)
- **Purpose**: Defines data flow from ingestion endpoint to Log Analytics table
- **Stream Name**: `Custom-WorkflowFailuresStream`
- **Output Stream**: `Custom-WorkflowFailures_CL`

##### Create Custom Table
```bash
# Create the custom table in Log Analytics
az monitor log-analytics workspace table create \
  --subscription {subscription-id} \
  --resource-group {resource-group} \
  --workspace-name {workspace-name} \
  --name WorkflowFailures_CL \
  --retention-time 30 \
  --columns TimeGenerated=datetime WorkflowName=string WorkflowRunId=string \
            FailureType=string ActionName=string ErrorCode=string \
            ErrorMessage=string Severity=string BlobPath=string
```

##### Create DCR
```json
{
  "location": "{location}",
  "properties": {
    "dataCollectionEndpointId": "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionEndpoints/dce-workflowerrors",
    "streamDeclarations": {
      "Custom-WorkflowFailuresStream": {
        "columns": [
          { "name": "TimeGenerated", "type": "datetime" },
          { "name": "WorkflowName", "type": "string" },
          { "name": "WorkflowRunId", "type": "string" },
          { "name": "FailureType", "type": "string" },
          { "name": "ActionName", "type": "string" },
          { "name": "ErrorCode", "type": "string" },
          { "name": "ErrorMessage", "type": "string" },
          { "name": "Severity", "type": "string" },
          { "name": "BlobPath", "type": "string" }
        ]
      }
    },
    "destinations": {
      "logAnalytics": [
        {
          "workspaceResourceId": "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace-name}",
          "name": "errorWorkspace"
        }
      ]
    },
    "dataFlows": [
      {
        "streams": [ "Custom-WorkflowFailuresStream" ],
        "destinations": [ "errorWorkspace" ],
        "transformKql": "source",
        "outputStream": "Custom-WorkflowFailures_CL"
      }
    ]
  }
}
```

Save the above JSON to `dcr-config.json` and create:
```bash
az rest --method PUT \
  --uri "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/dcr-workflowerrors?api-version=2022-06-01" \
  --body @dcr-config.json
```

**Important**: Note the `immutableId` from the response - this is used in the workflow HTTP endpoints.

#### Azure Storage Account
- **Purpose**: Stores generated CSV reports
- **Container**: Create a container for report output (e.g., `reportoutput`)
- **Access**: Logic App managed identity needs write access

#### Logic App (Standard)
- **SKU**: Workflow Standard (WS1, WS2, or WS3)
- **Hosting**: App Service Plan or Container
- **System-Assigned Managed Identity**: Must be enabled

### 2. API Connections

Two API connections are required (created during deployment):

#### azuremonitorlogs
- **Type**: Azure Monitor Logs connector
- **Authentication**: Managed Identity
- **Purpose**: Query source Log Analytics workspace

#### azureblob-1
- **Type**: Azure Blob Storage connector
- **Authentication**: Managed Identity
- **Purpose**: Write CSV files to blob storage

### 3. RBAC Requirements

The Logic App's **system-assigned managed identity** requires the following role assignments:

#### On Source Log Analytics Workspace
```bash
# Get Logic App managed identity principal ID
LOGIC_APP_IDENTITY=$(az webapp identity show \
  --name {logic-app-name} \
  --resource-group {resource-group} \
  --query principalId -o tsv)

# Assign Log Analytics Reader role
az role assignment create \
  --assignee $LOGIC_APP_IDENTITY \
  --role "Log Analytics Reader" \
  --scope /subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{source-workspace}
```

#### On Error Logging Log Analytics Workspace
```bash
# Assign Log Analytics Contributor role
az role assignment create \
  --assignee $LOGIC_APP_IDENTITY \
  --role "Log Analytics Contributor" \
  --scope /subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{error-workspace}
```

#### On Data Collection Rule
```bash
# Assign Monitoring Metrics Publisher role (required for Logs Ingestion API)
az role assignment create \
  --assignee $LOGIC_APP_IDENTITY \
  --role "Monitoring Metrics Publisher" \
  --scope /subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/dcr-workflowerrors
```

#### On Storage Account
```bash
# Assign Storage Blob Data Contributor role
az role assignment create \
  --assignee $LOGIC_APP_IDENTITY \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{storage-account-name}
```

---

## Deployment Steps

### Step 1: Prepare Local Environment

1. **Install Prerequisites**:
   - [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
   - [Azure Functions Core Tools v4](https://docs.microsoft.com/azure/azure-functions/functions-run-local)
   - [Visual Studio Code](https://code.visualstudio.com/)
   - [Azure Logic Apps (Standard) extension](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurelogicapps)

2. **Clone/Download this repository**

3. **Update local.settings.json** (for local testing):
   ```json
   {
     "IsEncrypted": false,
     "Values": {
       "AzureWebJobsStorage": "UseDevelopmentStorage=true",
       "FUNCTIONS_WORKER_RUNTIME": "node",
       "WORKFLOWS_SUBSCRIPTION_ID": "{your-subscription-id}",
       "WORKFLOWS_RESOURCE_GROUP_NAME": "{your-resource-group}",
       "WORKFLOWS_LOCATION_NAME": "{location}"
     }
   }
   ```

### Step 2: Create Azure Infrastructure

Run the following commands in order:

```bash
# Login to Azure
az login

# Set variables
SUBSCRIPTION_ID="your-subscription-id"
RESOURCE_GROUP="your-resource-group"
LOCATION="eastus2"
LOGIC_APP_NAME="logic-process-yourname"
STORAGE_ACCOUNT="storageyourname"
ERROR_WORKSPACE="logicapperrorhandling"
SOURCE_WORKSPACE="your-source-workspace"

# Create resource group (if needed)
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create storage account for Logic App
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS

# Create App Service Plan
az appservice plan create \
  --name plan-logicapp \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku WS1

# Create Logic App (Standard)
az logicapp create \
  --name $LOGIC_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --plan plan-logicapp

# Enable system-assigned managed identity
az webapp identity assign \
  --name $LOGIC_APP_NAME \
  --resource-group $RESOURCE_GROUP

# Create error logging workspace (if not exists)
az monitor log-analytics workspace create \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $ERROR_WORKSPACE \
  --location $LOCATION

# Create Data Collection Endpoint
az monitor data-collection endpoint create \
  --name dce-workflowerrors \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --public-network-access Enabled

# Create custom table (see prerequisites section for full command)
# Create DCR (see prerequisites section for configuration)
```

### Step 3: Configure RBAC

Assign all required roles (see RBAC Requirements section above).

**Important**: Role assignments can take up to 5 minutes to propagate.

### Step 4: Update Workflow Configuration

Edit `CreateChargeBackReport/workflow.json` and update the following placeholders:

1. **Query Action** - Update the Log Analytics workspace resource ID:
   ```json
   "subscriptionId": "{your-subscription-id}",
   "resourceGroupName": "{your-source-workspace-rg}",
   "workspaceName": "{your-source-workspace-name}"
   ```

2. **Error Handler URLs** - Update DCE and DCR IDs:
   ```json
   "uri": "https://dce-workflowerrors-{suffix}.{region}-1.ingest.monitor.azure.com/dataCollectionRules/dcr-{immutable-id}/streams/Custom-WorkflowFailuresStream?api-version=2023-01-01"
   ```

3. **Blob Storage Action** - Update storage account:
   ```json
   "blobName": "reportoutput/dailyChargeBackReport.csv",
   "folderPath": "",
   "accountName": "{your-storage-account-name}"
   ```

### Step 5: Create API Connections

API connections must be created in Azure and referenced in `connections.json`:

#### Create Azure Monitor Logs Connection
```bash
az rest --method PUT \
  --uri "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azuremonitorlogs?api-version=2018-07-01-preview" \
  --body '{
    "properties": {
      "displayName": "azuremonitorlogs",
      "api": {
        "id": "/subscriptions/'$SUBSCRIPTION_ID'/providers/Microsoft.Web/locations/'$LOCATION'/managedApis/azuremonitorlogs"
      },
      "parameterValueType": "Alternative"
    },
    "location": "'$LOCATION'"
  }'
```

#### Create Blob Storage Connection
```bash
az rest --method PUT \
  --uri "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azureblob-1?api-version=2018-07-01-preview" \
  --body '{
    "properties": {
      "displayName": "azureblob-1",
      "api": {
        "id": "/subscriptions/'$SUBSCRIPTION_ID'/providers/Microsoft.Web/locations/'$LOCATION'/managedApis/azureblob"
      },
      "parameterValueType": "Alternative"
    },
    "location": "'$LOCATION'"
  }'
```

### Step 6: Deploy Workflow

#### Option A: Deploy via VS Code
1. Open this folder in VS Code
2. Install Azure Logic Apps (Standard) extension
3. Right-click on the workflow folder → **Deploy to Logic App**
4. Select your Logic App resource

#### Option B: Deploy via Azure CLI
```bash
# Package the workflow
cd TokenUtilization
zip -r ../logic-app.zip .

# Deploy to Logic App
az logicapp deployment source config-zip \
  --name $LOGIC_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --src ../logic-app.zip
```

#### Option C: Deploy via Azure Functions Core Tools
```bash
cd TokenUtilization
func azure functionapp publish $LOGIC_APP_NAME --force
```

### Step 7: Configure API Connection Access Policy

After deployment, grant the Logic App access to the API connections:

```bash
# Get Logic App identity
IDENTITY=$(az webapp identity show \
  --name $LOGIC_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

# Grant access to azuremonitorlogs connection
az rest --method PUT \
  --uri "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azuremonitorlogs/accessPolicies/$IDENTITY?api-version=2016-06-01" \
  --body '{
    "properties": {
      "principal": {
        "type": "ActiveDirectory",
        "identity": {
          "objectId": "'$IDENTITY'"
        }
      }
    }
  }'

# Grant access to azureblob-1 connection
az rest --method PUT \
  --uri "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azureblob-1/accessPolicies/$IDENTITY?api-version=2016-06-01" \
  --body '{
    "properties": {
      "principal": {
        "type": "ActiveDirectory",
        "identity": {
          "objectId": "'$IDENTITY'"
        }
      }
    }
  }'
```

### Step 8: Test the Workflow

1. Navigate to Azure Portal → Logic App → Workflows → CreateChargeBackReport
2. Click **Run Trigger** → **Manual**
3. Monitor the run in the **Run History**
4. Verify CSV file created in blob storage
5. To test error handling, temporarily modify blob path or query to cause a failure
6. Check `WorkflowFailures_CL` table for error events:
   ```kql
   WorkflowFailures_CL
   | where TimeGenerated > ago(1h)
   | project TimeGenerated, FailureType, ActionName, ErrorMessage, Severity
   ```

**Note**: Log ingestion can take 3-5 minutes to appear in Log Analytics.

---

## Monitoring and Alerts

### Query Error Events
```kql
WorkflowFailures_CL
| where TimeGenerated > ago(24h)
| summarize FailureCount = count() by FailureType, Severity, bin(TimeGenerated, 1h)
| render timechart
```

### Create Alert Rule
1. Navigate to Log Analytics workspace → Alerts → Create
2. Condition: Custom log search
3. Query:
   ```kql
   WorkflowFailures_CL
   | where Severity == "High"
   ```
4. Alert logic: Number of results > 0
5. Evaluation period: 5 minutes
6. Action group: Configure email/webhook notifications

---

## Troubleshooting

### Workflow Runs but No Data in Blob
- Verify managed identity has **Storage Blob Data Contributor** role
- Check API connection access policy is configured
- Review Logic App run history for error details

### Error Events Not Appearing in Log Analytics
- Wait 3-5 minutes for ingestion latency
- Verify DCR configuration: `outputStream` should be `Custom-WorkflowFailures_CL`
- Check managed identity has **Monitoring Metrics Publisher** role on DCR
- Verify DCE and DCR URIs are correct in workflow
- Check workflow run history - error handlers only execute on failures

### Query Action Fails
- Verify managed identity has **Log Analytics Reader** role on source workspace
- Confirm KQL query is valid
- Check source workspace contains required tables

### HTTP 403 Errors on Error Handler
- Ensure managed identity has **Log Analytics Contributor** role on error workspace
- Verify **Monitoring Metrics Publisher** role on DCR
- Wait 5 minutes for role assignments to propagate
- Confirm authentication audience is `https://monitor.azure.com`

### Data Goes to Syslog Instead of Custom Table
- DCR configuration may not be fully propagated (wait up to 30 minutes)
- Verify custom table exists: `WorkflowFailures_CL`
- Check DCR `outputStream` exactly matches: `Custom-WorkflowFailures_CL`
- Confirm stream name matches: `Custom-WorkflowFailuresStream`

---

## Maintenance

### Update Query Logic
- Edit the KQL query in `Run_query_and_list_results` action
- Test query in Log Analytics before deploying
- Redeploy workflow using deployment steps

### Modify Error Schema
1. Update DCR stream declaration with new columns
2. Update custom table schema in Log Analytics
3. Update error handler HTTP body in workflow
4. Wait 30 minutes for DCR propagation
5. Test with a triggered failure

### Change Report Schedule
Add a trigger to the workflow:
```json
{
  "triggers": {
    "Recurrence": {
      "type": "Recurrence",
      "recurrence": {
        "frequency": "Day",
        "interval": 1,
        "schedule": {
          "hours": ["6"],
          "minutes": [0]
        },
        "timeZone": "Eastern Standard Time"
      }
    }
  }
}
```

---

## Security Considerations

- **No Secrets Required**: All authentication uses managed identity
- **Network Security**: Consider using private endpoints for storage and Log Analytics
- **RBAC**: Follow principle of least privilege - only grant necessary permissions
- **Data Retention**: Configure appropriate retention periods for cost management
- **Audit Logging**: Enable diagnostic settings on Logic App for activity logging

---

## Cost Optimization

- **Logic App**: Charged per workflow execution (~$0.000025 per action execution)
- **Log Analytics**: 
  - Ingestion: ~$2.99 per GB
  - Retention: First 31 days free, then ~$0.12 per GB/month
- **Blob Storage**: 
  - Hot tier: ~$0.0184 per GB/month
  - Transactions: ~$0.0004 per 10,000 operations
- **Data Collection**: No additional cost for DCE/DCR

**Estimated Monthly Cost** (assuming 1 run/day):
- Logic App: ~$0.02 (30 executions × 5 actions × $0.000025)
- Log Analytics: Minimal (error logs only, < 1 MB/month)
- Blob Storage: < $0.01 (small CSV files)
- **Total**: < $0.05/month (excluding source workspace query costs)

---

## Support and Contribution

For issues or questions:
1. Check troubleshooting section above
2. Review Azure Logic Apps documentation: https://docs.microsoft.com/azure/logic-apps/
3. Review Azure Monitor Logs Ingestion API: https://docs.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview

---

## Version History

- **v1.0** (December 2025): Initial release with managed identity authentication and custom error logging
