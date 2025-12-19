<#
.SYNOPSIS
    Deploys Azure Logic App Standard with ChargeBack reporting workflow.

.DESCRIPTION
    This script deploys a complete Logic App infrastructure including:
    - App Service Plan and Logic App (Standard)
    - API connections (Azure Monitor Logs and Azure Blob Storage)
    - Storage account for report output
    - Log Analytics workspace for error logging
    - Data Collection Rule and Endpoint for error handling
    - All necessary RBAC role assignments

.PARAMETER ResourceGroupName
    The name of the resource group where resources will be deployed.

.PARAMETER SourceLogAnalyticsWorkspace
    The name of the Log Analytics workspace containing LLM logging data (ApiManagementGatewayLogs).

.PARAMETER Location
    The Azure region for deployment (e.g., eastus2, westus2, centralus).

.PARAMETER LogicAppName
    The name of the Logic App to create. Default: Logic-App-ChargeBack-Report

.EXAMPLE
    .\Deploy-ChargeBackLogicApp.ps1 -ResourceGroupName "MyResourceGroup" -SourceLogAnalyticsWorkspace "MyLLMLogsWorkspace" -Location "eastus2"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$SourceLogAnalyticsWorkspace,

    [Parameter(Mandatory=$true)]
    [string]$Location,

    [Parameter(Mandatory=$false)]
    [string]$LogicAppName = "Logic-App-ChargeBack-Report"
)

$ErrorActionPreference = "Stop"

# Generate resource group name if not provided
if (-not $ResourceGroupName) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ResourceGroupName = "rg-chargeback-$timestamp"
    Write-Host "Generated Resource Group Name: $ResourceGroupName" -ForegroundColor Yellow
}

Write-Host "=== ChargeBack Logic App Deployment Script ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host "Source Workspace: $SourceLogAnalyticsWorkspace" -ForegroundColor Yellow
Write-Host "Location: $Location" -ForegroundColor Yellow
Write-Host ""

# Verify Azure CLI is authenticated
Write-Host "Verifying Azure CLI authentication..." -ForegroundColor Cyan
try {
    $subscription = (az account show --output json | ConvertFrom-Json).id
    if (-not $subscription) {
        throw "Unable to get subscription ID"
    }
    Write-Host "✓ Using subscription: $subscription" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Not logged in to Azure CLI. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

# Generate unique resource names
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$uniqueSuffix = -join ((97..122) | Get-Random -Count 6 | ForEach-Object {[char]$_})
$appServicePlanName = "ASP-$ResourceGroupName-$uniqueSuffix"
$logicAppStorageAccountName = "lacbstorage$uniqueSuffix"
$reportStorageAccountName = "rptcbstorage$uniqueSuffix"
$errorWorkspaceName = "cbErrorWorkspace-$uniqueSuffix"
$dcrName = "dcr-workflow-errors"
$dceName = "dce-workflow-errors"

Write-Host "Step 1: Verifying Resource Group..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Host "  Resource Group '$ResourceGroupName' already exists" -ForegroundColor Yellow
} else {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "✓ Resource Group created: $ResourceGroupName" -ForegroundColor Green
}

Write-Host "`nStep 2: Deploying infrastructure using Bicep..." -ForegroundColor Cyan
Write-Host "  This will create: App Service Plan, Logic App, Storage Accounts, Log Analytics, DCR/DCE, and RBAC roles" -ForegroundColor Gray

$deploymentName = "chargebackInfra-$(Get-Date -Format 'yyyyMMddHHmmss')"
$bicepFile = Join-Path $PSScriptRoot "deploy-infrastructure.bicep"

$deploymentOutput = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --template-file $bicepFile `
    --parameters `
        logicAppName=$LogicAppName `
        appServicePlanName=$appServicePlanName `
        logicAppStorageAccountName=$logicAppStorageAccountName `
        reportStorageAccountName=$reportStorageAccountName `
        errorWorkspaceName=$errorWorkspaceName `
        dceEndpointName=$dceName `
        dcrName=$dcrName `
        location=$Location `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Infrastructure deployment failed" -ForegroundColor Red
    exit 1
}

# Extract outputs from deployment
$logicAppIdentity = $deploymentOutput.properties.outputs.logicAppIdentity.value
$reportStorageAccountName = $deploymentOutput.properties.outputs.reportStorageAccountName.value
$dceEndpoint = $deploymentOutput.properties.outputs.dceEndpoint.value
$dcrImmutableId = $deploymentOutput.properties.outputs.dcrImmutableId.value
$errorWorkspaceName = $deploymentOutput.properties.outputs.errorWorkspaceName.value

Write-Host "✓ Infrastructure deployed successfully" -ForegroundColor Green
Write-Host "  Logic App Identity: $logicAppIdentity" -ForegroundColor Gray
Write-Host "  DCE Endpoint: $dceEndpoint" -ForegroundColor Gray
Write-Host "  DCR Immutable ID: $dcrImmutableId" -ForegroundColor Gray

Write-Host "`nStep 3: Creating API Connections..." -ForegroundColor Cyan

# Get current user's object ID for RBAC
$currentUserObjectId = (az ad signed-in-user show --query id -o tsv)

# Logic App internal storage (requires key-based auth)
$logicAppStorageExists = az storage account show --name $logicAppStorageAccountName --resource-group $ResourceGroupName 2>$null
if ($logicAppStorageExists) {
    Write-Host "  Logic App storage account '$logicAppStorageAccountName' already exists" -ForegroundColor Yellow
} else {
    az storage account create `
        --name $logicAppStorageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --allow-shared-key-access true `
        --allow-blob-public-access false `
        --https-only true `
        --min-tls-version TLS1_2 `
        --output none
}

# Ensure shared key access is enabled (critical for Logic App runtime)
Write-Host "  Enabling local/key-based authentication..." -ForegroundColor Gray

# Use az rest API to directly set allowSharedKeyAccess property
$storageUpdateBody = @{
    properties = @{
        allowSharedKeyAccess = $true
    }
} | ConvertTo-Json -Depth 10

az rest --method PATCH `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$logicAppStorageAccountName`?api-version=2023-01-01" `
    --headers "Content-Type=application/json" `
    --body $storageUpdateBody `
    --output none

# Wait for propagation
Start-Sleep -Seconds 5

# Verify key access is enabled
$keyAccessEnabled = (az storage account show `
    --name $logicAppStorageAccountName `
    --resource-group $ResourceGroupName `
    --query "allowSharedKeyAccess" `
    --output tsv)

if ($keyAccessEnabled -ne "True" -and $keyAccessEnabled -ne "true") {
    Write-Host "ERROR: Failed to enable key-based authentication on storage account. Current value: $keyAccessEnabled" -ForegroundColor Red
    Write-Host "Attempting alternative method..." -ForegroundColor Yellow
    
    az storage account update `
        --name $logicAppStorageAccountName `
        --resource-group $ResourceGroupName `
        --allow-shared-key-access true `
        --output none
    
    Start-Sleep -Seconds 5
    
    $keyAccessEnabled = (az storage account show `
        --name $logicAppStorageAccountName `
        --resource-group $ResourceGroupName `
        --query "allowSharedKeyAccess" `
        --output tsv)
    
    if ($keyAccessEnabled -ne "True" -and $keyAccessEnabled -ne "true") {
        Write-Host "ERROR: Still failed to enable key-based authentication. Please enable it manually." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  ✓ Key-based authentication confirmed enabled" -ForegroundColor Green

Write-Host "  Creating internal file share for Logic App runtime..." -ForegroundColor Gray

# Get storage account key for file share creation
$storageKey = (az storage account keys list `
    --account-name $logicAppStorageAccountName `
    --resource-group $ResourceGroupName `
    --query "[0].value" `
    --output tsv)

# File share name must be lowercase and valid (3-63 chars, lowercase letters, numbers, hyphens only)
$fileShareName = $LogicAppName.ToLower() -replace '[^a-z0-9-]', '-' -replace '-+', '-' -replace '^-|-$', ''
if ($fileShareName.Length -gt 63) {
    $fileShareName = $fileShareName.Substring(0, 63)
}

Write-Host "  File share name: $fileShareName" -ForegroundColor Gray

# Check if file share exists
$fileShareExists = az storage share exists `
    --name $fileShareName `
    --account-name $logicAppStorageAccountName `
    --account-key $storageKey `
    --query "exists" `
    --output tsv

if ($fileShareExists -eq "true") {
    Write-Host "  File share '$fileShareName' already exists" -ForegroundColor Yellow
} else {
    # Create file share that Logic App needs for its internal operation (NOT for CSV output)
    az storage share create `
        --name $fileShareName `
        --account-name $logicAppStorageAccountName `
        --account-key $storageKey `
        --quota 5120 `
        --output none
}

Write-Host "✓ Logic App storage account created: $logicAppStorageAccountName" -ForegroundColor Green

# Report output storage (managed identity only)
$reportStorageExists = az storage account show --name $reportStorageAccountName --resource-group $ResourceGroupName 2>$null
if ($reportStorageExists) {
    Write-Host "  Report storage account '$reportStorageAccountName' already exists" -ForegroundColor Yellow
} else {
    az storage account create `
        --name $reportStorageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --allow-shared-key-access false `
        --output none

    # Assign Storage Blob Data Contributor to current user for container creation
    az role assignment create `
        --assignee $currentUserObjectId `
        --role "Storage Blob Data Contributor" `
        --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$reportStorageAccountName" `
        --output none

    Write-Host "  Waiting for RBAC propagation..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

# Check if container exists
$containerExists = az storage container exists `
    --name "reportoutput" `
    --account-name $reportStorageAccountName `
    --auth-mode login `
    --query "exists" `
    --output tsv 2>$null

if ($containerExists -eq "true") {
    Write-Host "  Container 'reportoutput' already exists" -ForegroundColor Yellow
} else {
    az storage container create `
        --name "reportoutput" `
        --account-name $reportStorageAccountName `
        --auth-mode login `
        --output none
}
Write-Host "✓ Report storage account ready: $reportStorageAccountName" -ForegroundColor Green

Write-Host "`nStep 4: Creating Logic App (Standard)..." -ForegroundColor Cyan

# Get storage account connection string for Logic App
$storageConnectionString = (az storage account show-connection-string `
    --name $logicAppStorageAccountName `
    --resource-group $ResourceGroupName `
    --query connectionString `
    --output tsv)

if (-not $storageConnectionString) {
    Write-Host "ERROR: Failed to retrieve storage connection string" -ForegroundColor Red
    exit 1
}

# Check if Logic App exists
$logicAppExists = az logicapp show --name $LogicAppName --resource-group $ResourceGroupName 2>$null
if ($logicAppExists) {
    Write-Host "  Logic App '$LogicAppName' already exists" -ForegroundColor Yellow
} else {
    # Create Logic App with explicit storage connection string
    az logicapp create `
        --name $LogicAppName `
        --resource-group $ResourceGroupName `
        --plan $appServicePlanName `
        --storage-account $logicAppStorageAccountName `
        --assign-identity `
        --output none

    # Verify Logic App was created
    $logicAppExists = az logicapp show --name $LogicAppName --resource-group $ResourceGroupName 2>$null
    if (-not $logicAppExists) {
        Write-Host "ERROR: Logic App creation failed" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Waiting for Logic App to initialize..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

# Ensure storage connection is set in app settings
az logicapp config appsettings set `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --settings "AzureWebJobsStorage=$storageConnectionString" "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING=$storageConnectionString" "WEBSITE_CONTENTSHARE=$fileShareName" `
    --output none

# Enable system-assigned managed identity using webapp commands (Logic Apps Standard are web apps)
Write-Host "  Enabling managed identity via webapp commands..." -ForegroundColor Gray

az webapp identity assign `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: webapp identity assign command failed, trying alternative method..." -ForegroundColor Yellow
    
    # Alternative: Use resource update command
    az resource update `
        --ids "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName" `
        --set identity.type='SystemAssigned' `
        --output none
}

Write-Host "  ✓ Managed identity configuration applied" -ForegroundColor Green

# Wait for identity to propagate and retrieve it
Write-Host "  Retrieving managed identity principal ID (waiting 30s for propagation)..." -ForegroundColor Gray
Start-Sleep -Seconds 30

$logicAppIdentity = $null
$retryCount = 0
$maxRetries = 6

while (-not $logicAppIdentity -and $retryCount -lt $maxRetries) {
    # Try multiple methods to retrieve the identity
    $logicAppIdentity = (az webapp identity show `
        --name $LogicAppName `
        --resource-group $ResourceGroupName `
        --query "principalId" `
        --output tsv 2>$null)
    
    if (-not $logicAppIdentity -or $logicAppIdentity -eq "") {
        # Fallback to logicapp show
        $logicAppIdentity = (az logicapp show `
            --name $LogicAppName `
            --resource-group $ResourceGroupName `
            --query "identity.principalId" `
            --output tsv 2>$null)
    }
    
    if (-not $logicAppIdentity -or $logicAppIdentity -eq "") {
        $retryCount++
        if ($retryCount -lt $maxRetries) {
            Write-Host "  Retry $retryCount/$maxRetries (waiting 20s)..." -ForegroundColor Gray
            Start-Sleep -Seconds 20
        }
        $logicAppIdentity = $null
    }
}

if (-not $logicAppIdentity) {
    Write-Host "ERROR: Failed to retrieve Logic App managed identity after $maxRetries attempts" -ForegroundColor Red
    Write-Host "Please verify the Logic App was created successfully in the portal" -ForegroundColor Yellow
    exit 1
}
Write-Host "✓ Logic App created: $LogicAppName" -ForegroundColor Green
Write-Host "  Identity: $logicAppIdentity" -ForegroundColor Gray

Write-Host "`nStep 5: Creating Log Analytics Workspace for error logging..." -ForegroundColor Cyan
$errorWorkspaceExists = az monitor log-analytics workspace show --workspace-name $errorWorkspaceName --resource-group $ResourceGroupName 2>$null
if ($errorWorkspaceExists) {
    Write-Host "  Error Workspace '$errorWorkspaceName' already exists" -ForegroundColor Yellow
} else {
    az monitor log-analytics workspace create `
        --workspace-name $errorWorkspaceName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --output none
    Write-Host "✓ Error Workspace created: $errorWorkspaceName" -ForegroundColor Green
}

$errorWorkspaceId = (az monitor log-analytics workspace show `
    --workspace-name $errorWorkspaceName `
    --resource-group $ResourceGroupName `
    --output json | ConvertFrom-Json).customerId

if (-not $errorWorkspaceId) {
    Write-Host "ERROR: Failed to retrieve error workspace ID" -ForegroundColor Red
    exit 1
}
Write-Host "  Workspace ID: $errorWorkspaceId" -ForegroundColor Gray

Write-Host "`nStep 6: Creating Data Collection Endpoint..." -ForegroundColor Cyan
$dceExists = az rest --method GET --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName`?api-version=2022-06-01" 2>$null
if ($dceExists) {
    Write-Host "  DCE '$dceName' already exists" -ForegroundColor Yellow
} else {
    $dceBody = @{
        location = $Location
        properties = @{
            networkAcls = @{
                publicNetworkAccess = "Enabled"
            }
        }
    } | ConvertTo-Json -Depth 10

    az rest --method PUT `
        --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName`?api-version=2022-06-01" `
        --headers "Content-Type=application/json" `
        --body $dceBody `
        --output none
    Write-Host "✓ DCE created" -ForegroundColor Green
}

$dceEndpoint = (az rest --method GET `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName`?api-version=2022-06-01" `
    --output json | ConvertFrom-Json).properties.logsIngestion.endpoint

if (-not $dceEndpoint) {
    Write-Host "ERROR: Failed to retrieve DCE endpoint" -ForegroundColor Red
    exit 1
}
Write-Host "  DCE endpoint: $dceEndpoint" -ForegroundColor Gray

Write-Host "`nStep 7: Creating custom table in error workspace..." -ForegroundColor Cyan
$tableName = "WorkflowFailures_CL"
$tableSchema = @{
    properties = @{
        schema = @{
            name = $tableName
            columns = @(
                @{ name = "TimeGenerated"; type = "datetime" }
                @{ name = "WorkflowName"; type = "string" }
                @{ name = "WorkflowRunId"; type = "string" }
                @{ name = "FailureType"; type = "string" }
                @{ name = "ActionName"; type = "string" }
                @{ name = "ErrorCode"; type = "string" }
                @{ name = "ErrorMessage"; type = "string" }
                @{ name = "Severity"; type = "string" }
                @{ name = "BlobPath"; type = "string" }
            )
        }
    }
} | ConvertTo-Json -Depth 10

az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$errorWorkspaceName/tables/$tableName`?api-version=2022-10-01" `
    --headers "Content-Type=application/json" `
    --body $tableSchema `
    --output none
Write-Host "✓ Custom table created: $tableName" -ForegroundColor Green

Write-Host "`nStep 8: Creating Data Collection Rule..." -ForegroundColor Cyan
$dcrExists = az rest --method GET --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2022-06-01" 2>$null
if ($dcrExists) {
    Write-Host "  DCR '$dcrName' already exists" -ForegroundColor Yellow
    $dcrImmutableId = (az rest --method GET --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2022-06-01" | ConvertFrom-Json).properties.immutableId
} else {
    $dcrBody = @{
    location = $Location
    properties = @{
        dataCollectionEndpointId = "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName"
        streamDeclarations = @{
            "Custom-WorkflowFailuresStream" = @{
                columns = @(
                    @{ name = "TimeGenerated"; type = "datetime" }
                    @{ name = "WorkflowName"; type = "string" }
                    @{ name = "WorkflowRunId"; type = "string" }
                    @{ name = "FailureType"; type = "string" }
                    @{ name = "ActionName"; type = "string" }
                    @{ name = "ErrorCode"; type = "string" }
                    @{ name = "ErrorMessage"; type = "string" }
                    @{ name = "Severity"; type = "string" }
                    @{ name = "BlobPath"; type = "string" }
                )
            }
        }
        destinations = @{
            logAnalytics = @(
                @{
                    name = "errorWorkspace"
                    workspaceResourceId = "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$errorWorkspaceName"
                }
            )
        }
        dataFlows = @(
            @{
                streams = @("Custom-WorkflowFailuresStream")
                destinations = @("errorWorkspace")
                transformKql = "source"
                outputStream = "Custom-$tableName"
            }
        )
    }
} | ConvertTo-Json -Depth 10

    az rest --method PUT `
        --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2022-06-01" `
        --headers "Content-Type=application/json" `
        --body $dcrBody `
        --output none

    $dcrImmutableId = (az rest --method GET `
        --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2022-06-01" `
        --output json | ConvertFrom-Json).properties.immutableId
    
    if (-not $dcrImmutableId) {
        Write-Host "ERROR: Failed to retrieve DCR immutable ID" -ForegroundColor Red
        exit 1
    }
    Write-Host "✓ DCR created: $dcrImmutableId" -ForegroundColor Green
}

Write-Host "`nStep 9: Creating API Connections..." -ForegroundColor Cyan

# Create Azure Monitor Logs connection
$azureMonitorLogsConnectionBody = @{
    location = $Location
    kind = "V2"
    properties = @{
        api = @{
            id = "/subscriptions/$subscription/providers/Microsoft.Web/locations/$Location/managedApis/azuremonitorlogs"
        }
        parameterValueSet = @{
            name = "managedIdentityAuth"
            values = @{}
        }
    }
} | ConvertTo-Json -Depth 10

az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azuremonitorlogs?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body $azureMonitorLogsConnectionBody `
    --output none

# Add access policy for Logic App identity
$tenantId = (az account show --query tenantId --output tsv)
$azureMonitorLogsAccessPolicyBody = @{
    location = $Location
    properties = @{
        principal = @{
            type = "ActiveDirectory"
            identity = @{
                tenantId = $tenantId
                objectId = $logicAppIdentity
            }
        }
    }
} | ConvertTo-Json -Depth 10

az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azuremonitorlogs/accessPolicies/$logicAppIdentity`?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body $azureMonitorLogsAccessPolicyBody `
    --output none

Write-Host "✓ Azure Monitor Logs connection created" -ForegroundColor Green

# Create Azure Blob connection
$azureBlobConnectionBody = @{
    location = $Location
    kind = "V2"
    properties = @{
        api = @{
            id = "/subscriptions/$subscription/providers/Microsoft.Web/locations/$Location/managedApis/azureblob"
        }
        parameterValueSet = @{
            name = "managedIdentityAuth"
            values = @{}
        }
    }
} | ConvertTo-Json -Depth 10

az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body $azureBlobConnectionBody `
    --output none

# Add access policy for Logic App identity
$azureBlobAccessPolicyBody = @{
    location = $Location
    properties = @{
        principal = @{
            type = "ActiveDirectory"
            identity = @{
                tenantId = $tenantId
                objectId = $logicAppIdentity
            }
        }
    }
} | ConvertTo-Json -Depth 10

az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob/accessPolicies/$logicAppIdentity`?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body $azureBlobAccessPolicyBody `
    --output none

Write-Host "✓ Azure Blob connection created" -ForegroundColor Green

Write-Host "`nStep 10: Assigning RBAC roles..." -ForegroundColor Cyan

# Log Analytics Reader on source workspace
az role assignment create `
    --assignee $logicAppIdentity `
    --role "Log Analytics Reader" `
    --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$SourceLogAnalyticsWorkspace" `
    --output none
Write-Host "✓ Log Analytics Reader assigned on source workspace" -ForegroundColor Green

# Storage Blob Data Contributor on report storage account
az role assignment create `
    --assignee $logicAppIdentity `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$reportStorageAccountName" `
    --output none
Write-Host "✓ Storage Blob Data Contributor assigned" -ForegroundColor Green

# Monitoring Metrics Publisher on DCR
az role assignment create `
    --assignee $logicAppIdentity `
    --role "Monitoring Metrics Publisher" `
    --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName" `
    --output none
Write-Host "✓ Monitoring Metrics Publisher assigned on DCR" -ForegroundColor Green

# Monitoring Metrics Publisher on DCE
az role assignment create `
    --assignee $logicAppIdentity `
    --role "Monitoring Metrics Publisher" `
    --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName" `
    --output none
Write-Host "✓ Monitoring Metrics Publisher assigned on DCE" -ForegroundColor Green

Write-Host "`nStep 11: Updating workflow and connections with deployment-specific values..." -ForegroundColor Cyan

# Read workflow template
$workflowPath = Join-Path $PSScriptRoot "CreateChargeBackReport\workflow.json"
$workflowContent = Get-Content $workflowPath -Raw

# Replace placeholders in workflow
$workflowContent = $workflowContent `
    -replace '{{SUBSCRIPTION_ID}}', $subscription `
    -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
    -replace '{{SOURCE_WORKSPACE}}', $SourceLogAnalyticsWorkspace `
    -replace '{{STORAGE_ACCOUNT}}', $reportStorageAccountName `
    -replace '{{DCE_ENDPOINT}}', $dceEndpoint `
    -replace '{{DCR_IMMUTABLE_ID}}', $dcrImmutableId

$workflowContent | Set-Content $workflowPath -Encoding UTF8

# Read and update connections.json template
$connectionsPath = Join-Path $PSScriptRoot "connections.json"
$connectionsContent = Get-Content $connectionsPath -Raw

# Replace placeholders in connections
$connectionsContent = $connectionsContent `
    -replace '{{SUBSCRIPTION_ID}}', $subscription `
    -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
    -replace '{{LOCATION}}', $Location.ToLower()

$connectionsContent | Set-Content $connectionsPath -Encoding UTF8

Write-Host "✓ Workflow and connections updated" -ForegroundColor Green

Write-Host "`nStep 12: Deploying workflow to Logic App..." -ForegroundColor Cyan
Set-Location $PSScriptRoot
func azure functionapp publish $LogicAppName --output none
Write-Host "✓ Workflow deployed" -ForegroundColor Green

Write-Host "`nStep 13: Restarting Logic App to refresh identity token..." -ForegroundColor Cyan
az logicapp restart --name $LogicAppName --resource-group $ResourceGroupName --output none
Write-Host "✓ Logic App restarted" -ForegroundColor Green

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Resource Summary:" -ForegroundColor Cyan
Write-Host "  Logic App: $LogicAppName" -ForegroundColor White
Write-Host "  Logic App Storage: $logicAppStorageAccountName" -ForegroundColor White
Write-Host "  Report Storage: $reportStorageAccountName" -ForegroundColor White
Write-Host "  Error Workspace: $errorWorkspaceName" -ForegroundColor White
Write-Host "  DCR: $dcrName ($dcrImmutableId)" -ForegroundColor White
Write-Host "  DCE: $dceName" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Verify workflow in Azure Portal: https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName" -ForegroundColor White
Write-Host "  2. Check report output in storage: $reportStorageAccountName/reportoutput/dailyChargeBackReport.csv" -ForegroundColor White
Write-Host "  3. Monitor errors in workspace: $errorWorkspaceName (table: WorkflowFailures_CL)" -ForegroundColor White
Write-Host ""
