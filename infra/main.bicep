targetScope = 'subscription'

@description('Short workload prefix used in resource names.')
param baseName string = 'ragbot'

@description('Environment name used in resource names and tags.')
param environmentName string = 'lab'

@description('Object ID of the deployment operator. Placeholder is replaced by deployment script.')
param deployerObjectId string

@description('Microsoft Entra application/client ID for the Azure Bot registration. Created post-deploy.')
param botMsaAppId string

param location string = 'eastus2'
param aiSearchLocation string = 'centralus'
param resourceGroupName string = 'rg-ailab-rag-eastus2'
param tenantId string = ''
param sharePointSiteId string = ''
param sharePointDriveName string = 'Documents'

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: {
    workload: baseName
    environment: environmentName
    deployment: 'ailab-rag-private-20260623'
  }
}

module workload './modules/workload.bicep' = {
  name: 'deploy-${baseName}-${environmentName}-infra'
  scope: rg
  params: {
    baseName: baseName
    environmentName: environmentName
    location: location
    aiSearchLocation: aiSearchLocation
    deployerObjectId: deployerObjectId
    botMsaAppId: botMsaAppId
    tenantId: tenantId
    sharePointSiteId: sharePointSiteId
    sharePointDriveName: sharePointDriveName
  }
}

output resourceGroupName string = rg.name
output botAppName string = workload.outputs.botAppName
output functionAppName string = workload.outputs.functionAppName
output foundryAccountName string = workload.outputs.foundryAccountName
output foundryProjectName string = workload.outputs.foundryProjectName
