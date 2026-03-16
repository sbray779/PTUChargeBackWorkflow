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

.PARAMETER ZipFunctionAppRegistrationClientId
    (Optional) The Application (client) ID of a pre-existing Entra ID app registration to use for
    authenticating the Zip CSV Function App.  Required when the deployer does not have permissions
    to create app registrations in Entra ID.  See README.md for manual creation steps.

.EXAMPLE
    # Standard deployment — script creates the app registration automatically
    .\Deploy-ChargeBackLogicApp-v2.ps1

.EXAMPLE
    # Deployment when the app registration was pre-created by an admin
    .\Deploy-ChargeBackLogicApp-v2.ps1 -ZipFunctionAppRegistrationClientId "<appId from admin>"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "deploy-infrastructure.bicepparam",

    # Supply this when the deployer lacks permission to create Entra app registrations.
    # An admin must first run the manual steps documented in README.md and provide the resulting appId.
    [Parameter(Mandatory=$false)]
    [string]$ZipFunctionAppRegistrationClientId = ""
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

# Verify .NET 10 SDK is available (required to build ZipCsvFunction)
$dotnetVersion = dotnet --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: .NET SDK is not installed or not in PATH" -ForegroundColor Red
    Write-Host "Install .NET 10 SDK from: https://aka.ms/dotnet/download" -ForegroundColor Yellow
    exit 1
}
$majorVersion = [int]($dotnetVersion -split '\.')[0]
if ($majorVersion -lt 10) {
    Write-Host "ERROR: .NET 10 SDK or later is required (found: $dotnetVersion)" -ForegroundColor Red
    Write-Host "Install .NET 10 SDK from: https://aka.ms/dotnet/download" -ForegroundColor Yellow
    exit 1
}
Write-Host "  .NET SDK version: $dotnetVersion" -ForegroundColor Gray

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
$zipFunctionAppName = $deploymentOutput.properties.outputs.zipFunctionAppName.value

Write-Host "✓ Infrastructure deployed successfully" -ForegroundColor Green
Write-Host "  Logic App: $LogicAppName" -ForegroundColor Gray
Write-Host "  User Managed Identity: $userManagedIdentityName" -ForegroundColor Gray
Write-Host "  User Managed Identity Principal ID: $userManagedIdentityPrincipalId" -ForegroundColor Gray
Write-Host "  Logic App Storage: $logicAppStorageAccountName" -ForegroundColor Gray
Write-Host "  Report Storage: $reportStorageAccountName" -ForegroundColor Gray
Write-Host "  DCE Endpoint: $dceEndpoint" -ForegroundColor Gray
Write-Host "  DCR Immutable ID: $dcrImmutableId" -ForegroundColor Gray
  Write-Host "  Zip Function App: $zipFunctionAppName" -ForegroundColor Gray
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

Write-Host "`nStep 6: Building and deploying Zip CSV Function App..." -ForegroundColor Cyan

# Build the .NET 8 isolated function
Write-Host "  Building ZipCsvFunction..." -ForegroundColor Gray
$zipCsvProjectPath = Join-Path $PSScriptRoot "ZipCsvFunction\ZipCsvFunction.csproj"
$zipCsvPublishPath = Join-Path $PSScriptRoot "ZipCsvFunction\publish"
dotnet publish $zipCsvProjectPath -c Release -o $zipCsvPublishPath --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: dotnet publish failed for ZipCsvFunction" -ForegroundColor Red
    exit 1
}

# Package and deploy via zip
$zipPackagePath = Join-Path $env:TEMP "ZipCsvFunction.zip"
Compress-Archive -Path (Join-Path $zipCsvPublishPath "*") -DestinationPath $zipPackagePath -Force
Write-Host "  Deploying to Function App: $zipFunctionAppName..." -ForegroundColor Gray
# Use 'az functionapp deploy' (newer /api/publish endpoint) instead of config-zip to avoid
# the legacy Kudu Ninject DI crash that occurs with the old /api/zipdeploy endpoint.
az functionapp deploy `
    --name $zipFunctionAppName `
    --resource-group $ResourceGroupName `
    --src-path $zipPackagePath `
    --type zip `
    --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Zip CSV Function App deployment failed" -ForegroundColor Red
    exit 1
}

Write-Host "`nStep 6b: Configuring Entra ID authentication on Zip CSV Function App..." -ForegroundColor Cyan
# EasyAuth requires a real AAD app registration as the resource audience.
# The function app name is only known after Bicep runs, so this cannot be done in Bicep.
$funcAuthAppName = "$zipFunctionAppName-auth"
# Identifier URI must include the tenant ID to satisfy org policies that require
# a verified domain, tenant ID, or app ID in the URI (see aka.ms/identifier-uri-formatting-error).
$funcAudience    = "api://$tenantId/$zipFunctionAppName"

if ($ZipFunctionAppRegistrationClientId) {
    # App registration was pre-created by an admin — use the supplied clientId directly.
    $funcAppClientId = $ZipFunctionAppRegistrationClientId
    Write-Host "  Using pre-supplied app registration: $funcAppClientId" -ForegroundColor Gray
    # Ensure the identifier URI is set (idempotent — safe to run on existing registrations).
    az ad app update --id $funcAppClientId --identifier-uris $funcAudience 2>&1 | Out-Null
} else {
    # Attempt to find an existing registration or create a new one.
    $existingApp = az ad app list --display-name $funcAuthAppName --query "[0]" -o json 2>$null | ConvertFrom-Json
    if ($existingApp -and $existingApp.appId) {
        $funcAppClientId = $existingApp.appId
        Write-Host "  Using existing app registration: $funcAppClientId" -ForegroundColor Gray
        az ad app update --id $funcAppClientId --identifier-uris $funcAudience 2>&1 | Out-Null
    } else {
        Write-Host "  Creating app registration for Function App..." -ForegroundColor Gray
        $funcAppClientId = az ad app create `
            --display-name $funcAuthAppName `
            --identifier-uris $funcAudience `
            --query appId -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "" -ForegroundColor Red
            Write-Host "ERROR: Failed to create Entra ID app registration." -ForegroundColor Red
            Write-Host "  This usually means your account does not have permission to create" -ForegroundColor Yellow
            Write-Host "  app registrations in this tenant." -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Write-Host "  Ask a tenant administrator to run the following commands and provide" -ForegroundColor Yellow
            Write-Host "  you with the resulting Application (client) ID:" -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Write-Host "    az ad app create ``" -ForegroundColor White
            Write-Host "      --display-name '$funcAuthAppName' ``" -ForegroundColor White
            Write-Host "      --identifier-uris '$funcAudience' ``" -ForegroundColor White
            Write-Host "      --query appId -o tsv" -ForegroundColor White
            Write-Host "" -ForegroundColor Yellow
            Write-Host "  Then re-run this script with the -ZipFunctionAppRegistrationClientId parameter:" -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Write-Host "    .\Deploy-ChargeBackLogicApp-v2.ps1 -ZipFunctionAppRegistrationClientId '<appId>'" -ForegroundColor White
            Write-Host "" -ForegroundColor Yellow
            exit 1
        }
        $funcAppClientId = $funcAppClientId.Trim()
        Write-Host "  Created app registration: $funcAppClientId" -ForegroundColor Gray
    }
}

# Apply EasyAuth v2 settings to the Function App via ARM REST API.
$authSettings = @{
    properties = @{
        globalValidation = @{
            requireAuthentication         = $true
            unauthenticatedClientAction   = 'Return401'
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled      = $true
                registration = @{
                    openIdIssuer = "https://sts.windows.net/$tenantId/v2.0"
                    clientId     = $funcAppClientId
                }
                validation   = @{
                    allowedAudiences             = @($funcAudience)
                    defaultAuthorizationPolicy   = @{
                        allowedPrincipals = @{
                            identities = @($userManagedIdentityPrincipalId)
                        }
                    }
                }
            }
        }
        login = @{ tokenStore = @{ enabled = $false } }
    }
}
$authTempFile = [System.IO.Path]::GetTempFileName() + '.json'
$authSettings | ConvertTo-Json -Depth 10 | Set-Content $authTempFile -Encoding UTF8
az rest --method PUT `
    --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$zipFunctionAppName/config/authsettingsV2?api-version=2022-09-01" `
    --headers "Content-Type=application/json" `
    --body "@$authTempFile" --output none
Remove-Item $authTempFile -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to configure EasyAuth on Function App" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Entra ID authentication configured (app: $funcAppClientId)" -ForegroundColor Green

# Store the plain function URL as a Logic App app setting.
# Authentication is handled via Managed Identity (EasyAuth) - no key needed.
$zipFunctionUrl = "https://$zipFunctionAppName.azurewebsites.net/api/ZipCsv"
Write-Host "  Storing function URL as Logic App app setting..." -ForegroundColor Gray
az logicapp config appsettings set `
    --name $logicAppName `
    --resource-group $ResourceGroupName `
    --settings "ZipCsvFunctionUrl=$zipFunctionUrl" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to set ZipCsvFunctionUrl app setting on Logic App" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Zip CSV Function deployed" -ForegroundColor Green

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

# Stage all Logic App files into a temp directory so placeholder tokens are never
# written back to the source files. The source files always stay as templates.
$tempDeployDir = Join-Path $env:TEMP "chargeback-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $tempDeployDir | Out-Null
Write-Host "  Staging files to: $tempDeployDir" -ForegroundColor Gray

$deploySucceeded = $false
try {
    # host.json needs no substitution
    Copy-Item (Join-Path $PSScriptRoot "host.json") $tempDeployDir

    # connections.json - resolve placeholders into the staged copy
    $connectionsContent = Get-Content (Join-Path $PSScriptRoot "connections.json") -Raw
    $connectionsContent = $connectionsContent `
        -replace '{{SUBSCRIPTION_ID}}', $subscription `
        -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
        -replace '{{LOCATION}}', $Location.ToLower() `
        -replace '{{USER_MANAGED_IDENTITY_ID}}', $userManagedIdentityId `
        -replace '{{AZURE_MONITOR_LOGS_RUNTIME_URL}}', $azureMonitorLogsRuntimeUrl `
        -replace '{{AZURE_BLOB_RUNTIME_URL}}', $azureBlobRuntimeUrl
    $connectionsContent | Set-Content (Join-Path $tempDeployDir "connections.json") -Encoding UTF8

    # Each workflow subfolder - resolve placeholders into staged copies
    Get-ChildItem -Path $PSScriptRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "workflow.json") } |
        ForEach-Object {
            $destDir = Join-Path $tempDeployDir $_.Name
            New-Item -ItemType Directory -Path $destDir | Out-Null
            $workflowContent = Get-Content (Join-Path $_.FullName "workflow.json") -Raw
            $workflowContent = $workflowContent `
                -replace '{{SUBSCRIPTION_ID}}', $subscription `
                -replace '{{RESOURCE_GROUP}}', $ResourceGroupName `
                -replace '{{SOURCE_WORKSPACE}}', $SourceLogAnalyticsWorkspace `
                -replace '{{SOURCE_WORKSPACE_RG}}', $SourceWorkspaceResourceGroup `
                -replace '{{STORAGE_ACCOUNT}}', $reportStorageAccountName `
                -replace '{{DCE_ENDPOINT}}', $dceEndpoint `
                -replace '{{DCR_IMMUTABLE_ID}}', $dcrImmutableId `
                -replace '{{USER_MANAGED_IDENTITY_ID}}', $userManagedIdentityId `
                -replace '{{ZIP_FUNCTION_APP_NAME}}', $zipFunctionAppName `
                -replace '{{ZIP_FUNCTION_AUDIENCE}}', $funcAudience
            $workflowContent | Set-Content (Join-Path $destDir "workflow.json") -Encoding UTF8
        }

    # local.settings.json is required by func CLI but should never be committed
    @{
        IsEncrypted = $false
        Values      = @{
            FUNCTIONS_WORKER_RUNTIME = "dotnet"
            AzureWebJobsStorage      = ""
        }
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tempDeployDir "local.settings.json") -Encoding UTF8

    # Publish from the staged copy
    Set-Location $tempDeployDir
    Write-Host "  Publishing to Logic App: $LogicAppName..." -ForegroundColor Gray
    $publishOutput = func azure functionapp publish $LogicAppName 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Workflow deployment failed" -ForegroundColor Red
        Write-Host "Output: $publishOutput" -ForegroundColor Yellow
    } else {
        $deploySucceeded = $true
        Write-Host "✓ Workflow deployed" -ForegroundColor Green
    }
} finally {
    Set-Location $PSScriptRoot
    Remove-Item $tempDeployDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $deploySucceeded) { exit 1 }

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
Write-Host "  Zip CSV Function App: $zipFunctionAppName" -ForegroundColor White
Write-Host "  Error Workspace: $errorWorkspaceName" -ForegroundColor White
Write-Host ""
Write-Host "RBAC Assignments:" -ForegroundColor Cyan
Write-Host "  ✓ Website Contributor on Logic App (for dynamic schema)" -ForegroundColor White
Write-Host "  ✓ Reader on source workspace $SourceLogAnalyticsWorkspace" -ForegroundColor White
Write-Host "  ✓ Log Analytics Reader on source workspace $SourceLogAnalyticsWorkspace (via Bicep)" -ForegroundColor White
Write-Host "  ✓ Storage Blob Data Contributor on $reportStorageAccountName (via Bicep)" -ForegroundColor White
Write-Host "  ✓ Monitoring Metrics Publisher on DCR/DCE (via Bicep)" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Verify workflow in Azure Portal: https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName" -ForegroundColor White
Write-Host "  2. Check report output in storage: $reportStorageAccountName/reportoutput/ (*.parquet files)" -ForegroundColor White
Write-Host "  3. Monitor errors in workspace: $errorWorkspaceName (table: WorkflowFailures_CL)" -ForegroundColor White
Write-Host ""
