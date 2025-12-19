using './deploy-infrastructure.bicep'

param resourceGroupName = 'testchargeback'
param location = 'eastus2'
param sourceLogAnalyticsWorkspace = 'ChargeBackWorkspace'
param sourceWorkspaceResourceGroup = 'AIHubChargeBack'
