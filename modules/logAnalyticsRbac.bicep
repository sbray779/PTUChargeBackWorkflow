@description('The name of the Log Analytics workspace')
param workspaceName string

@description('The principal ID to grant access to')
param principalId string

// Reference the existing Log Analytics workspace
resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// Log Analytics Reader role: 73c42c96-874c-492b-b04d-ab87d138a893
resource logAnalyticsReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, principalId, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: workspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
