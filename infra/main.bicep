targetScope = 'subscription'

@description('Short workload prefix used in resource names.')
param baseName string = 'ragbot'

@description('Environment name used in resource names and tags.')
param environmentName string = 'lab'

@description('Object ID of the deploying user or service principal. Granted Key Vault Secrets Officer at deploy time so the deployment can seed the Application Insights connection string.')
param deployerObjectId string

@description('Windows local admin username for the jump VM (Bastion-only access).')
param jumpVmAdminUsername string = 'azureuser'

@secure()
@description('Windows local admin password for the jump VM. Must be 12-123 chars and meet Azure complexity rules. Pass via -p jumpVmAdminPassword=... or set in a local bicepparam (which is gitignored).')
param jumpVmAdminPassword string

@description('Primary region. Hub VNet, compute, and the AI Foundry account all live here.')
param location string = 'westus3'

@description('Region for Azure AI Search. Service-only (the PE is in the hub VNet); cross-region PE is created automatically.')
param aiSearchLocation string = 'centralus'

@description('Target resource group name. Created at deploy time.')
param resourceGroupName string = 'rg-ailab-rag-${location}'

@description('Microsoft Entra tenant ID - required for the Bot Service UAMI binding.')
param tenantId string = ''

@description('SharePoint Online site ID (GUID) for the ingestion source. Leave empty if you will wire ingestion later.')
param sharePointSiteId string = ''

@description('SharePoint document library name to ingest from.')
param sharePointDriveName string = 'Documents'

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: {
    workload: baseName
    environment: environmentName
    deployment: 'ailab-rag-private'
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
    tenantId: tenantId
    sharePointSiteId: sharePointSiteId
    sharePointDriveName: sharePointDriveName
    jumpVmAdminUsername: jumpVmAdminUsername
    jumpVmAdminPassword: jumpVmAdminPassword
  }
}

output resourceGroupName string = rg.name
output botAppName string = workload.outputs.botAppName
output functionAppName string = workload.outputs.functionAppName
output foundryAccountName string = workload.outputs.foundryAccountName
output foundryProjectName string = workload.outputs.foundryProjectName
output jumpVmName string = workload.outputs.jumpVmName
output jumpVmAdminUsername string = workload.outputs.jumpVmAdminUsername
