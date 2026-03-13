targetScope = 'resourceGroup'

@description('The name of the resource group')
param resourceGroupName string

@description('The Azure region for deployment')
param location string

@description('The name of the source Log Analytics workspace')
param sourceLogAnalyticsWorkspace string

@description('The resource group containing the source Log Analytics workspace')
param sourceWorkspaceResourceGroup string

// Generate unique suffix for all resource names
var uniqueSuffix = uniqueString(resourceGroup().id)
var logicAppName = 'logic-chargeback-${uniqueSuffix}'
var appServicePlanName = 'asp-chargeback-${uniqueSuffix}'
var logicAppStorageAccountName = 'lacb${uniqueSuffix}'
var reportStorageAccountName = 'rptcb${uniqueSuffix}'
var errorWorkspaceName = 'law-chargeback-${uniqueSuffix}'
var dceEndpointName = 'dce-chargeback-${uniqueSuffix}'
var dcrName = 'dcr-chargeback-${uniqueSuffix}'
var userManagedIdentityName = 'id-chargeback-${uniqueSuffix}'

// User Assigned Managed Identity
resource userManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: userManagedIdentityName
  location: location
}

// App Service Plan for Logic App
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 20
  }
}

// Logic App internal storage (with key access enabled)
resource logicAppStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: logicAppStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// File share for Logic App runtime
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${logicAppStorage.name}/default/${toLower(logicAppName)}'
  properties: {
    shareQuota: 5120
  }
}

// Report output storage (managed identity only)
resource reportStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: reportStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// Blob container for reports
resource reportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${reportStorage.name}/default/reportoutput'
  properties: {
    publicAccess: 'None'
  }
}

// Logic App with user-assigned managed identity
resource logicApp 'Microsoft.Web/sites@2022-09-01' = {
  name: logicAppName
  location: location
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userManagedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${logicAppStorage.name};AccountKey=${logicAppStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${logicAppStorage.name};AccountKey=${logicAppStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(logicAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'WORKFLOWS_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'WORKFLOWS_LOCATION_NAME'
          value: location
        }
        {
          name: 'WORKFLOWS_RESOURCE_GROUP_NAME'
          value: resourceGroupName
        }
        {
          name: 'REPORT_STORAGE_ACCOUNT_NAME'
          value: reportStorage.name
        }
        {
          name: 'USER_MANAGED_IDENTITY_NAME'
          value: userManagedIdentity.name
        }
        {
          name: 'USER_MANAGED_IDENTITY_CLIENT_ID'
          value: userManagedIdentity.properties.clientId
        }
        {
          name: 'LOG_ANALYTICS_WORKSPACE_ID'
          value: sourceWorkspaceRbac.outputs.workspaceCustomerId
        }
        {
          name: 'REPORT_END_HOUR'
          value: '21'
        }
        {
          name: 'ERROR_WORKSPACE_ID'
          value: errorWorkspace.properties.customerId
        }
      ]
      netFrameworkVersion: 'v6.0'
      use32BitWorkerProcess: false
    }
  }
  dependsOn: [
    fileShare
  ]
}

// Log Analytics Workspace for error logging
resource errorWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: errorWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Custom table for workflow failures
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: 'WorkflowFailures_CL'
  parent: errorWorkspace
  properties: {
    schema: {
      name: 'WorkflowFailures_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'WorkflowName', type: 'string' }
        { name: 'WorkflowRunId', type: 'string' }
        { name: 'FailureType', type: 'string' }
        { name: 'ActionName', type: 'string' }
        { name: 'ErrorCode', type: 'string' }
        { name: 'ErrorMessage', type: 'string' }
        { name: 'Severity', type: 'string' }
        { name: 'BlobPath', type: 'string' }
      ]
    }
  }
}

// Intermediate chunk-level summary table used for idempotent daily re-aggregation (Option C pattern)
resource chargeBackChunksTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: 'ChargeBackChunks_CL'
  parent: errorWorkspace
  properties: {
    schema: {
      name: 'ChargeBackChunks_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'ReportDate', type: 'string' }
        { name: 'WorkflowRunId', type: 'string' }
        { name: 'ChunkId', type: 'real' }
        { name: 'ProductId', type: 'string' }
        { name: 'Luma', type: 'string' }
        { name: 'Workspace', type: 'string' }
        { name: 'DeploymentName', type: 'string' }
        { name: 'ModelName', type: 'string' }
        { name: 'AccountName', type: 'string' }
        { name: 'SubscriptionId', type: 'string' }
        { name: 'ResourceID', type: 'string' }
        { name: 'SkuName', type: 'string' }
        { name: 'SkuCapacity', type: 'real' }
        { name: 'BackendId', type: 'string' }
        { name: 'Endpoint', type: 'string' }
        { name: 'PromptTokens', type: 'real' }
        { name: 'CompletionTokens', type: 'real' }
        { name: 'TotalTokens', type: 'real' }
        { name: 'Calls', type: 'real' }
        { name: 'FirstSeen', type: 'datetime' }
        { name: 'LastSeen', type: 'datetime' }
        { name: 'Regions', type: 'string' }
        { name: 'CallerIpAddresses', type: 'string' }
      ]
    }
  }
}

// Wait for custom table schemas to propagate before creating the DCR.
// Azure reports tables as created before they are queryable by DCR validation,
// causing InvalidOutputTable errors if the DCR is created immediately.
resource waitForCustomTables 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'wait-tables-${uniqueSuffix}'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userManagedIdentity.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '11.0'
    scriptContent: 'Start-Sleep -Seconds 90'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
  }
  dependsOn: [
    customTable
    chargeBackChunksTable
  ]
}

// Data Collection Endpoint
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceEndpointName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Data Collection Rule
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-WorkflowFailuresStream': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'WorkflowName', type: 'string' }
          { name: 'WorkflowRunId', type: 'string' }
          { name: 'FailureType', type: 'string' }
          { name: 'ActionName', type: 'string' }
          { name: 'ErrorCode', type: 'string' }
          { name: 'ErrorMessage', type: 'string' }
          { name: 'Severity', type: 'string' }
          { name: 'BlobPath', type: 'string' }
        ]
      }
      'Custom-ChargeBackChunksStream': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ReportDate', type: 'string' }
          { name: 'WorkflowRunId', type: 'string' }
          { name: 'ChunkId', type: 'real' }
          { name: 'ProductId', type: 'string' }
          { name: 'Luma', type: 'string' }
          { name: 'Workspace', type: 'string' }
          { name: 'DeploymentName', type: 'string' }
          { name: 'ModelName', type: 'string' }
          { name: 'AccountName', type: 'string' }
          { name: 'SubscriptionId', type: 'string' }
          { name: 'ResourceID', type: 'string' }
          { name: 'SkuName', type: 'string' }
          { name: 'SkuCapacity', type: 'real' }
          { name: 'BackendId', type: 'string' }
          { name: 'Endpoint', type: 'string' }
          { name: 'PromptTokens', type: 'real' }
          { name: 'CompletionTokens', type: 'real' }
          { name: 'TotalTokens', type: 'real' }
          { name: 'Calls', type: 'real' }
          { name: 'FirstSeen', type: 'datetime' }
          { name: 'LastSeen', type: 'datetime' }
          { name: 'Regions', type: 'string' }
          { name: 'CallerIpAddresses', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'errorWorkspace'
          workspaceResourceId: errorWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-WorkflowFailuresStream' ]
        destinations: [ 'errorWorkspace' ]
        transformKql: 'source'
        outputStream: 'Custom-WorkflowFailures_CL'
      }
      {
        streams: [ 'Custom-ChargeBackChunksStream' ]
        destinations: [ 'errorWorkspace' ]
        transformKql: 'source'
        outputStream: 'Custom-ChargeBackChunks_CL'
      }
    ]
  }
  dependsOn: [
    waitForCustomTables
  ]
}

// RBAC: Log Analytics Reader on error workspace for Logic App (needed to query ChargeBackChunks_CL)
resource errorWorkspaceReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(errorWorkspace.id, userManagedIdentity.id, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: errorWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: userManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Storage Blob Data Contributor on report storage for Logic App
resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(reportStorage.id, userManagedIdentity.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: reportStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: userManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Monitoring Metrics Publisher on DCR for Logic App
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, userManagedIdentity.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: userManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Monitoring Metrics Publisher on DCE for Logic App
resource dceRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dce.id, userManagedIdentity.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dce
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: userManagedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Log Analytics Reader on source workspace for Logic App (cross-resource-group)
module sourceWorkspaceRbac 'modules/logAnalyticsRbac.bicep' = {
  name: 'sourceWorkspaceRbac'
  scope: resourceGroup(sourceWorkspaceResourceGroup)
  params: {
    workspaceName: sourceLogAnalyticsWorkspace
    principalId: userManagedIdentity.properties.principalId
  }
}

// Outputs
output userManagedIdentityId string = userManagedIdentity.id
output userManagedIdentityName string = userManagedIdentity.name
output userManagedIdentityClientId string = userManagedIdentity.properties.clientId
output userManagedIdentityPrincipalId string = userManagedIdentity.properties.principalId
output logicAppName string = logicApp.name
output logicAppStorageAccountName string = logicAppStorage.name
output reportStorageAccountName string = reportStorage.name
output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output errorWorkspaceName string = errorWorkspace.name
output errorWorkspaceId string = errorWorkspace.properties.customerId
output sourceWorkspaceName string = sourceLogAnalyticsWorkspace
output sourceWorkspaceResourceGroup string = sourceWorkspaceResourceGroup
output sourceWorkspaceId string = sourceWorkspaceRbac.outputs.workspaceCustomerId

