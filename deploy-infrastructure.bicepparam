using './deploy-infrastructure.bicep'

param resourceGroupName = 'PTUChargeBackChunks'
param location = 'eastus2'
param sourceLogAnalyticsWorkspace = 'ChargeBackWorkspace'
param sourceWorkspaceResourceGroup = 'aihubchargeback'
