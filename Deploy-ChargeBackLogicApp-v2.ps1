<#
.SYNOPSIS
    Deploys Azure Logic App Standard with ChargeBack reporting workflow using Bicep for infrastructure.

.DESCRIPTION
    This script deploys a complete Logic App infrastructure including:
    - App Service Plan and Logic App (Standard) with managed identity
    - API connections (Azure Monitor Logs and Azure Blob Storage)
    - Storage accounts for Logic App and report output
    - Log Analytics workspace for error logging
    - Data Collection Rule and Endpoint for error handling
    - All necessary RBAC role assignments

.PARAMETER ResourceGroupName
    The name of the resource group where resources will be deployed. If not provided, a random name will be generated.

.PARAMETER SourceLogAnalyticsWorkspace
    The name of the Log Analytics workspace containing LLM logging data (ApiManagementGatewayLogs).

.PARAMETER Location
    The Azure region for deployment (e.g., eastus2, westus2, centralus).

.PARAMETER LogicAppName
    The name of the Logic App to create. Default: Logic-App-ChargeBack-Report

.EXAMPLE
    .\Deploy-ChargeBackLogicApp-v2.ps1 -SourceLogAnalyticsWorkspace "MyLLMLogsWorkspace" -Location "eastus2"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "deploy-infrastructure.bicepparam"
)

$ErrorActionPreference = "Stop"

Write-Host "=== ChargeBack Logic App Deployment Script ===" -ForegroundColor Cyan
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

# Verify parameters file exists
$parametersFilePath = Join-Path $PSScriptRoot $ParametersFile
if (-not (Test-Path $parametersFilePath)) {
    Write-Host "ERROR: Parameters file not found: $parametersFilePath" -ForegroundColor Red
    exit 1
}

# Read parameters from Bicep parameters file
Write-Host "Reading parameters from: $ParametersFile" -ForegroundColor Cyan
$paramsContent = Get-Content $parametersFilePath -Raw
if ($paramsContent -match "param resourceGroupName = '([^']+)'") {
    $ResourceGroupName = $Matches[1]
}
if ($paramsContent -match "param location = '([^']+)'") {
    $Location = $Matches[1]
}
if ($paramsContent -match "param sourceLogAnalyticsWorkspace = '([^']+)'") {
    $SourceLogAnalyticsWorkspace = $Matches[1]
}
if ($paramsContent -match "param sourceWorkspaceResourceGroup = '([^']+)'") {
    $SourceWorkspaceResourceGroup = $Matches[1]
}

if (-not $ResourceGroupName -or -not $Location -or -not $SourceLogAnalyticsWorkspace -or -not $SourceWorkspaceResourceGroup) {
    Write-Host "ERROR: Failed to parse required parameters from Bicep parameters file" -ForegroundColor Red
    exit 1
}

Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Location: $Location" -ForegroundColor Gray
Write-Host "  Source Workspace: $SourceLogAnalyticsWorkspace" -ForegroundColor Gray
Write-Host "  Source Workspace RG: $SourceWorkspaceResourceGroup" -ForegroundColor Gray
Write-Host ""

Write-Host "Step 1: Verifying Resource Group..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Host "  Resource Group '$ResourceGroupName' already exists" -ForegroundColor Yellow
} else {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "✓ Resource Group created: $ResourceGroupName" -ForegroundColor Green
}

Write-Host "`nStep 2: Deploying infrastructure using Bicep..." -ForegroundColor Cyan
Write-Host "  This will create: App Service Plan, Logic App (with managed identity), Storage, Log Analytics, DCR/DCE, RBAC" -ForegroundColor Gray

$deploymentName = "chargebackInfra-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Capture raw output to diagnose errors
$rawOutput = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --parameters $parametersFilePath `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Infrastructure deployment failed" -ForegroundColor Red
    Write-Host "Raw output: $rawOutput" -ForegroundColor Yellow
    exit 1
}

try {
    # Strip any non-JSON prefix (e.g., "Bicep CLI is already installed..." messages)
    $jsonOutput = $rawOutput -join "`n"
    if ($jsonOutput -match '(?s)(\{.*\})') {
        $jsonOutput = $Matches[1]
    }
    $deploymentOutput = $jsonOutput | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Failed to parse deployment output as JSON" -ForegroundColor Red
    Write-Host "Raw output: $rawOutput" -ForegroundColor Yellow
    exit 1
}

if (-not $deploymentOutput) {
    Write-Host "ERROR: Infrastructure deployment returned no output" -ForegroundColor Red
    exit 1
}

# Extract outputs from deployment
$userManagedIdentityId = $deploymentOutput.properties.outputs.userManagedIdentityId.value
$userManagedIdentityName = $deploymentOutput.properties.outputs.userManagedIdentityName.value
$userManagedIdentityPrincipalId = $deploymentOutput.properties.outputs.userManagedIdentityPrincipalId.value
$LogicAppName = $deploymentOutput.properties.outputs.logicAppName.value
$logicAppStorageAccountName = $deploymentOutput.properties.outputs.logicAppStorageAccountName.value
$reportStorageAccountName = $deploymentOutput.properties.outputs.reportStorageAccountName.value
$dceEndpoint = $deploymentOutput.properties.outputs.dceEndpoint.value
$dcrImmutableId = $deploymentOutput.properties.outputs.dcrImmutableId.value
$errorWorkspaceName = $deploymentOutput.properties.outputs.errorWorkspaceName.value

Write-Host "✓ Infrastructure deployed successfully" -ForegroundColor Green
Write-Host "  Logic App: $LogicAppName" -ForegroundColor Gray
Write-Host "  User Managed Identity: $userManagedIdentityName" -ForegroundColor Gray
Write-Host "  User Managed Identity Principal ID: $userManagedIdentityPrincipalId" -ForegroundColor Gray
Write-Host "  Logic App Storage: $logicAppStorageAccountName" -ForegroundColor Gray
Write-Host "  Report Storage: $reportStorageAccountName" -ForegroundColor Gray
Write-Host "  DCE Endpoint: $dceEndpoint" -ForegroundColor Gray
Write-Host "  DCR Immutable ID: $dcrImmutableId" -ForegroundColor Gray

Write-Host "`nStep 3: Creating API Connections..." -ForegroundColor Cyan

# Get tenant ID for access policies
$tenantId = (az account show --query tenantId --output tsv)

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
}

$tempFile = [System.IO.Path]::GetTempFileName()
$azureMonitorLogsConnectionBody | ConvertTo-Json -Depth 10 | Set-Content $tempFile -Encoding UTF8

$result = az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azuremonitorlogs?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body "@$tempFile" 2>&1

Remove-Item $tempFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR creating Azure Monitor Logs connection: $result" -ForegroundColor Red
    exit 1
}

# Add access policy for Logic App identity
$azureMonitorLogsAccessPolicyBody = @{
    location = $Location
    properties = @{
        principal = @{
            type = "ActiveDirectory"
            identity = @{
                tenantId = $tenantId
                objectId = $userManagedIdentityPrincipalId
            }
        }
    }
}

$tempFile = [System.IO.Path]::GetTempFileName()
$azureMonitorLogsAccessPolicyBody | ConvertTo-Json -Depth 10 | Set-Content $tempFile -Encoding UTF8

$result = az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azuremonitorlogs/accessPolicies/$userManagedIdentityPrincipalId`?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body "@$tempFile" 2>&1

Remove-Item $tempFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR creating Azure Monitor Logs access policy: $result" -ForegroundColor Red
    exit 1
}

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
}

$tempFile = [System.IO.Path]::GetTempFileName()
$azureBlobConnectionBody | ConvertTo-Json -Depth 10 | Set-Content $tempFile -Encoding UTF8

$result = az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body "@$tempFile" 2>&1

Remove-Item $tempFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR creating Azure Blob connection: $result" -ForegroundColor Red
    exit 1
}

# Wait for connection to be provisioned
Write-Host "  Waiting for Azure Blob connection to provision..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Verify connection exists before adding access policy
$blobConnectionCheck = az rest --method GET `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob?api-version=2018-07-01-preview" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Azure Blob connection was not created successfully: $blobConnectionCheck" -ForegroundColor Red
    exit 1
}

# Add access policy for Logic App identity
$azureBlobAccessPolicyBody = @{
    location = $Location
    properties = @{
        principal = @{
            type = "ActiveDirectory"
            identity = @{
                tenantId = $tenantId
                objectId = $userManagedIdentityPrincipalId
            }
        }
    }
}

$tempFile = [System.IO.Path]::GetTempFileName()
$azureBlobAccessPolicyBody | ConvertTo-Json -Depth 10 | Set-Content $tempFile -Encoding UTF8

$result = az rest --method PUT `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob/accessPolicies/$userManagedIdentityPrincipalId`?api-version=2018-07-01-preview" `
    --headers "Content-Type=application/json" `
    --body "@$tempFile" 2>&1

Remove-Item $tempFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR creating Azure Blob access policy: $result" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Azure Blob connection created" -ForegroundColor Green

Write-Host "`nStep 4: Retrieving connection runtime URLs..." -ForegroundColor Cyan

# Get Azure Monitor Logs connection runtime URL
$azureMonitorLogsConnection = az rest --method GET `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azuremonitorlogs?api-version=2018-07-01-preview" `
    --output json | ConvertFrom-Json

$azureMonitorLogsRuntimeUrl = $azureMonitorLogsConnection.properties.connectionRuntimeUrl

if (-not $azureMonitorLogsRuntimeUrl) {
    Write-Host "ERROR: Failed to retrieve Azure Monitor Logs connection runtime URL" -ForegroundColor Red
    exit 1
}
Write-Host "  Azure Monitor Logs URL: $azureMonitorLogsRuntimeUrl" -ForegroundColor Gray

# Get Azure Blob connection runtime URL
$azureBlobConnection = az rest --method GET `
    --uri "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/azureblob?api-version=2018-07-01-preview" `
    --output json | ConvertFrom-Json

$azureBlobRuntimeUrl = $azureBlobConnection.properties.connectionRuntimeUrl

if (-not $azureBlobRuntimeUrl) {
    Write-Host "ERROR: Failed to retrieve Azure Blob connection runtime URL" -ForegroundColor Red
    exit 1
}
Write-Host "  Azure Blob URL: $azureBlobRuntimeUrl" -ForegroundColor Gray

Write-Host "✓ Connection runtime URLs retrieved" -ForegroundColor Green

Write-Host "`nStep 5: Assigning RBAC roles..." -ForegroundColor Cyan

# Website Contributor on the Logic App itself for dynamic schema retrieval
Write-Host "  Assigning Website Contributor on Logic App..." -ForegroundColor Gray
az role assignment create `
    --assignee $userManagedIdentityPrincipalId `
    --role "Website Contributor" `
    --scope "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Website Contributor assigned on Logic App" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Website Contributor assignment may already exist" -ForegroundColor Yellow
}

# Log Analytics Reader on source workspace
Write-Host "  Assigning Log Analytics Reader on source workspace..." -ForegroundColor Gray
az role assignment create `
    --assignee $userManagedIdentityPrincipalId `
    --role "Log Analytics Reader" `
    --scope "/subscriptions/$subscription/resourceGroups/$SourceWorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$SourceLogAnalyticsWorkspace" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Log Analytics Reader assigned on source workspace" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Log Analytics Reader assignment may already exist" -ForegroundColor Yellow
}

# Reader on source workspace for resource metadata access
Write-Host "  Assigning Reader on source workspace resource..." -ForegroundColor Gray
az role assignment create `
    --assignee $userManagedIdentityPrincipalId `
    --role "Reader" `
    --scope "/subscriptions/$subscription/resourceGroups/$SourceWorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$SourceLogAnalyticsWorkspace" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Reader assigned on source workspace" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Reader assignment may already exist" -ForegroundColor Yellow
}

Write-Host "✓ RBAC roles assigned" -ForegroundColor Green
Write-Host "  Waiting 30 seconds for RBAC permissions to propagate..." -ForegroundColor Gray
Start-Sleep -Seconds 30

Write-Host "`nStep 6: Updating workflow and connections with deployment-specific values..." -ForegroundColor Cyan

# Read workflow template
$workflowPath = Join-Path $PSScriptRoot "CreateChargeBackReport\workflow.json"
$workflowContent = Get-Content $workflowPath -Raw

# Replace placeholders in workflow
$workflowContent = $workflowContent `
    -replace '{{SUBSCRIPTION_ID}}', $subscription `
    -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
    -replace '{{SOURCE_WORKSPACE}}', $SourceLogAnalyticsWorkspace `
    -replace '{{SOURCE_WORKSPACE_RG}}', $SourceWorkspaceResourceGroup `
    -replace '{{STORAGE_ACCOUNT}}', $reportStorageAccountName `
    -replace '{{DCE_ENDPOINT}}', $dceEndpoint `
    -replace '{{DCR_IMMUTABLE_ID}}', $dcrImmutableId `
    -replace '{{USER_MANAGED_IDENTITY_ID}}', $userManagedIdentityId

$workflowContent | Set-Content $workflowPath -Encoding UTF8

# Read and update connections.json template
$connectionsPath = Join-Path $PSScriptRoot "connections.json"
$connectionsContent = Get-Content $connectionsPath -Raw

# Replace placeholders in connections
$connectionsContent = $connectionsContent `
    -replace '{{SUBSCRIPTION_ID}}', $subscription `
    -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
    -replace '{{LOCATION}}', $Location.ToLower() `
    -replace '{{USER_MANAGED_IDENTITY_ID}}', $userManagedIdentityId `
    -replace '{{AZURE_MONITOR_LOGS_RUNTIME_URL}}', $azureMonitorLogsRuntimeUrl `
    -replace '{{AZURE_BLOB_RUNTIME_URL}}', $azureBlobRuntimeUrl

$connectionsContent | Set-Content $connectionsPath -Encoding UTF8

Write-Host "✓ Workflow and connections updated" -ForegroundColor Green

Write-Host "`nStep 7: Deploying workflow to Logic App..." -ForegroundColor Cyan
Set-Location $PSScriptRoot

# Check if Azure Functions Core Tools is installed
$funcVersion = func --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Azure Functions Core Tools (func) is not installed or not in PATH" -ForegroundColor Red
    Write-Host "Install it with: npm install -g azure-functions-core-tools@4" -ForegroundColor Yellow
    Write-Host "Or download from: https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local" -ForegroundColor Yellow
    exit 1
}
Write-Host "  Using Azure Functions Core Tools version: $funcVersion" -ForegroundColor Gray

# Deploy workflow - capture output to show errors
Write-Host "  Publishing to Logic App: $LogicAppName..." -ForegroundColor Gray
$publishOutput = func azure functionapp publish $LogicAppName 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Workflow deployment failed" -ForegroundColor Red
    Write-Host "Output: $publishOutput" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Workflow deployed" -ForegroundColor Green

Write-Host "`nStep 8: Restarting Logic App to apply permissions..." -ForegroundColor Cyan
Write-Host "  This ensures all RBAC permissions and identity tokens are refreshed" -ForegroundColor Gray
az logicapp restart --name $LogicAppName --resource-group $ResourceGroupName --output none
Write-Host "✓ Logic App restarted" -ForegroundColor Green

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Resource Summary:" -ForegroundColor Cyan
Write-Host "  Logic App: $LogicAppName" -ForegroundColor White
Write-Host "  User Managed Identity: $userManagedIdentityName" -ForegroundColor White
Write-Host "  User Managed Identity Principal ID: $userManagedIdentityPrincipalId" -ForegroundColor White
Write-Host "  Logic App Storage: $logicAppStorageAccountName" -ForegroundColor White
Write-Host "  Report Storage: $reportStorageAccountName" -ForegroundColor White
Write-Host "  Error Workspace: $errorWorkspaceName" -ForegroundColor White
Write-Host ""
Write-Host "RBAC Assignments:" -ForegroundColor Cyan
Write-Host "  ✓ Website Contributor on Logic App (for dynamic schema)" -ForegroundColor White
Write-Host "  ✓ Reader on source workspace $SourceLogAnalyticsWorkspace" -ForegroundColor White
Write-Host "  ✓ Log Analytics Reader on source workspace $SourceLogAnalyticsWorkspace" -ForegroundColor White
Write-Host "  ✓ Storage Blob Data Contributor on $reportStorageAccountName (via Bicep)" -ForegroundColor White
Write-Host "  ✓ Monitoring Metrics Publisher on DCR/DCE (via Bicep)" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Verify workflow in Azure Portal: https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName" -ForegroundColor White
Write-Host "  2. Check report output in storage: $reportStorageAccountName/reportoutput/dailyChargeBackReport.csv" -ForegroundColor White
Write-Host "  3. Monitor errors in workspace: $errorWorkspaceName (table: WorkflowFailures_CL)" -ForegroundColor White
Write-Host ""
