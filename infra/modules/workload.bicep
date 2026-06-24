param baseName string
param environmentName string
param location string
param aiSearchLocation string
param deployerObjectId string
param tenantId string
param sharePointSiteId string
param sharePointDriveName string

@description('Windows local admin username for the jump VM.')
param jumpVmAdminUsername string = 'azureuser'

@secure()
@description('Windows local admin password for the jump VM (min 12 chars, complexity).')
param jumpVmAdminPassword string

var uniqueSuffix = toLower(substring(uniqueString(subscription().id, resourceGroup().id, baseName, environmentName), 0, 6))
var namePrefix = '${baseName}-${environmentName}'
var compactPrefix = toLower(replace('${baseName}${environmentName}', '-', ''))
var tags = {
  workload: baseName
  environment: environmentName
  deployment: 'ailab-rag-private-20260623'
}

var vnetName = 'vnet-${namePrefix}-hub'
var natPipName = 'pip-${namePrefix}-nat-${uniqueSuffix}'
var natGatewayName = 'nat-${namePrefix}-${uniqueSuffix}'
var lawName = 'log-${namePrefix}-${uniqueSuffix}'
var appInsightsName = 'appi-${namePrefix}-${uniqueSuffix}'
var amplsName = 'ampls-${namePrefix}-${uniqueSuffix}'
var keyVaultName = take('kv-${compactPrefix}-${uniqueSuffix}', 24)
var storageName = take('${compactPrefix}st${uniqueSuffix}', 24)
var cosmosName = take('cosmos-${namePrefix}-${uniqueSuffix}', 44)
var searchName = take('srch-${namePrefix}-${uniqueSuffix}', 60)
var docIntelName = take('di-${namePrefix}-${uniqueSuffix}', 64)
var appConfigName = take('appcs-${namePrefix}-${uniqueSuffix}', 50)
var foundryBaseName = 'ai${uniqueSuffix}'
var foundryAccountName = take('ai-${namePrefix}-${uniqueSuffix}', 64)
var foundryProjectName = take('proj-${namePrefix}', 50)
var botPlanName = 'asp-${namePrefix}-bot'
var functionPlanName = 'asp-${namePrefix}-func'
var botAppName = take('app-${namePrefix}-bot-${uniqueSuffix}', 60)
var functionAppName = take('func-${namePrefix}-ingest-${uniqueSuffix}', 60)
var botServiceName = take('bot-${namePrefix}-${uniqueSuffix}', 42)

var zoneAiServices = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
var zoneOpenAi = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
var zoneCognitive = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
var zoneSearch = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
var zoneCosmos = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
var zoneBlob = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
var zoneQueue = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.queue.${environment().suffixes.storage}')
var zoneVault = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')
var zoneAppConfig = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.azconfig.io')
var zoneWeb = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.azurewebsites.net')
var zoneMonitor = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.monitor.azure.com')
var zoneOds = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.ods.opinsights.azure.com')
var zoneOms = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.oms.opinsights.azure.com')
var zoneAutomation = resourceId('Microsoft.Network/privateDnsZones', 'privatelink.agentsvc.azure-automation.net')

var computeSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-compute')
var privateEndpointSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-pe')
var foundryAgentSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-foundry-agent')
var appInsightsConnectionStringSecretName = 'applicationinsights-connection-string'

module uamiBot 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'uami-bot'
  params: {
    name: 'uami-bot'
    location: location
    tags: tags
  }
}

module uamiIngestion 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'uami-ingestion'
  params: {
    name: 'uami-ingestion'
    location: location
    tags: tags
  }
}

module uamiFoundry 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'uami-foundry'
  params: {
    name: 'uami-foundry'
    location: location
    tags: tags
  }
}

module nsgCompute 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-compute'
  params: {
    name: 'nsg-snet-compute'
    location: location
    securityRules: [
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4095
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Internet-Outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
    tags: tags
  }
}

module nsgPrivateEndpoints 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-pe'
  params: {
    name: 'nsg-snet-pe'
    location: location
    securityRules: [
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4095
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    tags: tags
  }
}

module nsgFoundryAgent 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-foundry-agent'
  params: {
    name: 'nsg-snet-foundry-agent'
    location: location
    securityRules: [
      {
        name: 'Deny-All-Inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-VNet-Outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Internet-Outbound-For-Foundry-Agent'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
    tags: tags
  }
}

module nsgEgress 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-egress'
  params: {
    name: 'nsg-snet-egress'
    location: location
    securityRules: []
    tags: tags
  }
}

module nsgJump 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-jump'
  params: {
    name: 'nsg-snet-jump'
    location: location
    securityRules: [
      {
        name: 'Allow-Bastion-RDP-Inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
          description: 'Allow RDP from Bastion (inside VNet) to jump VM'
        }
      }
      {
        name: 'Allow-Bastion-SSH-Inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow SSH from Bastion (inside VNet) to jump VM'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 200
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-VNet-Outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Internet-Outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 4000
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'Allow outbound to Internet via NAT Gateway (Foundry portal, sign-in, asset loading). Data plane still goes via private endpoints.'
        }
      }
    ]
    tags: tags
  }
}

module natPublicIp 'br/public:avm/res/network/public-ip-address:0.12.0' = {
  name: 'pip-nat'
  params: {
    name: natPipName
    location: location
    availabilityZones: []
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    tags: tags
  }
}

module natGateway 'br/public:avm/res/network/nat-gateway:2.1.0' = {
  name: 'nat-gateway'
  params: {
    name: natGatewayName
    location: location
    availabilityZone: -1
    publicIpResourceIds: [
      natPublicIp.outputs.resourceId
    ]
    tags: tags
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'hub-vnet'
  params: {
    name: vnetName
    location: location
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    subnets: [
      {
        name: 'snet-compute'
        addressPrefix: '10.0.1.0/24'
        delegation: 'Microsoft.Web/serverFarms'
        natGatewayResourceId: natGateway.outputs.resourceId
        networkSecurityGroupResourceId: nsgCompute.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'snet-pe'
        addressPrefix: '10.0.2.0/24'
        networkSecurityGroupResourceId: nsgPrivateEndpoints.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        defaultOutboundAccess: false
      }
      {
        name: 'snet-foundry-agent'
        addressPrefix: '10.0.3.0/27'
        delegation: 'Microsoft.App/environments'
        natGatewayResourceId: natGateway.outputs.resourceId
        networkSecurityGroupResourceId: nsgFoundryAgent.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'snet-egress'
        addressPrefix: '10.0.4.0/26'
        natGatewayResourceId: natGateway.outputs.resourceId
        networkSecurityGroupResourceId: nsgEgress.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.0.5.0/26'
      }
      {
        name: 'snet-jump'
        addressPrefix: '10.0.6.0/27'
        networkSecurityGroupResourceId: nsgJump.outputs.resourceId
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
    ]
    tags: tags
  }
}

module privateDnsZones 'br/public:avm/ptn/network/private-link-private-dns-zones:0.7.3' = {
  name: 'private-link-dns-zones'
  params: {
    location: location
    privateLinkPrivateDnsZones: [
      'privatelink.services.ai.azure.com'
      'privatelink.openai.azure.com'
      'privatelink.cognitiveservices.azure.com'
      'privatelink.search.windows.net'
      'privatelink.documents.azure.com'
      'privatelink.blob.${environment().suffixes.storage}'
      'privatelink.queue.${environment().suffixes.storage}'
      'privatelink.vaultcore.azure.net'
      'privatelink.azconfig.io'
      'privatelink.azurewebsites.net'
      'privatelink.monitor.azure.com'
      'privatelink.ods.opinsights.azure.com'
      'privatelink.oms.opinsights.azure.com'
      'privatelink.agentsvc.azure-automation.net'
    ]
    virtualNetworkLinks: [
      {
        name: '${vnetName}-link'
        registrationEnabled: false
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
      }
    ]
    tags: tags
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: 'bastion'
  params: {
    name: 'bas-${namePrefix}-${uniqueSuffix}'
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    skuName: 'Standard'
    scaleUnits: 2
    publicIPAddressObject: {
      name: 'pip-bas-${namePrefix}-${uniqueSuffix}'
      availabilityZones: []
    }
    tags: tags
  }
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.1' = {
  name: 'log-analytics'
  params: {
    name: lawName
    location: location
    skuName: 'PerGB2018'
    dataRetention: 30
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    tags: tags
  }
}

module appInsights 'br/public:avm/res/insights/component:0.7.2' = {
  name: 'app-insights'
  params: {
    name: appInsightsName
    location: location
    workspaceResourceId: logAnalytics.outputs.resourceId
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    disableLocalAuth: true
    tags: tags
  }
}

module ampls 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: 'ampls'
  params: {
    name: amplsName
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
    scopedResources: [
      {
        name: 'law'
        linkedResourceId: logAnalytics.outputs.resourceId
      }
      {
        name: 'appi'
        linkedResourceId: appInsights.outputs.resourceId
      }
    ]
    tags: tags
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'key-vault'
  params: {
    name: keyVaultName
    location: location
    sku: 'standard'
    enableRbacAuthorization: true
    publicNetworkAccess: 'Disabled'
    enablePurgeProtection: true
    roleAssignments: [
      {
        principalId: deployerObjectId
        principalType: 'User'
        roleDefinitionIdOrName: 'Key Vault Administrator'
      }
      {
        principalId: uamiBot.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Key Vault Secrets User'
      }
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Key Vault Secrets User'
      }
    ]
    tags: tags
  }
}

resource appInsightsConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  name: '${keyVaultName}/${appInsightsConnectionStringSecretName}'
  properties: {
    value: appInsights.outputs.connectionString
  }
  dependsOn: [
    keyVault
  ]
}

module storage 'br/public:avm/res/storage/storage-account:0.32.1' = {
  name: 'storage'
  params: {
    name: storageName
    location: location
    skuName: 'Standard_LRS'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    blobServices: {
      containers: [
        {
          name: 'assets'
          publicAccess: 'None'
        }
        {
          name: 'rag-content'
          publicAccess: 'None'
        }
      ]
    }
    roleAssignments: [
      {
        principalId: uamiBot.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Reader'
      }
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Owner'
      }
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Queue Data Contributor'
      }
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Table Data Contributor'
      }
      {
        principalId: uamiFoundry.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Owner'
      }
    ]
    tags: tags
  }
}

module cosmos 'br/public:avm/res/document-db/database-account:0.19.0' = {
  name: 'cosmos'
  params: {
    name: cosmosName
    location: location
    failoverLocations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    zoneRedundant: false
    disableLocalAuthentication: true
    capabilitiesToAdd: [
      'EnableServerless'
    ]
    networkRestrictions: {
      publicNetworkAccess: 'Disabled'
      networkAclBypass: 'None'
    }
    roleAssignments: [
      {
        principalId: uamiFoundry.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'DocumentDB Account Contributor'
      }
    ]
    tags: tags
  }
}

module docIntelligence 'br/public:avm/res/cognitive-services/account:0.15.0' = {
  name: 'doc-intelligence'
  params: {
    name: docIntelName
    location: location
    kind: 'FormRecognizer'
    sku: 'S0'
    customSubDomainName: docIntelName
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
    }
    roleAssignments: [
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Cognitive Services User'
      }
    ]
    tags: tags
  }
}

module search 'br/public:avm/res/search/search-service:0.12.2' = {
  name: 'ai-search'
  params: {
    name: searchName
    location: aiSearchLocation
    sku: 'standard'
    replicaCount: 1
    partitionCount: 1
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
    managedIdentities: {
      systemAssigned: true
    }
    roleAssignments: [
      {
        principalId: uamiBot.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Reader'
      }
      {
        principalId: uamiIngestion.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Contributor'
      }
      {
        principalId: uamiFoundry.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Contributor'
      }
      {
        principalId: uamiFoundry.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Service Contributor'
      }
    ]
    tags: tags
  }
}

module appConfig 'br/public:avm/res/app-configuration/configuration-store:0.9.3' = {
  name: 'app-config'
  params: {
    name: appConfigName
    location: location
    sku: 'Standard'
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    roleAssignments: [
      {
        principalId: uamiBot.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'App Configuration Data Reader'
      }
    ]
    tags: tags
  }
}

module foundry 'br/public:avm/ptn/ai-ml/ai-foundry:0.7.0' = {
  name: 'ai-foundry'
  params: {
    baseName: foundryBaseName
    location: location
    includeAssociatedResources: true
    privateEndpointSubnetResourceId: privateEndpointSubnetId
    aiModelDeployments: [
      {
        name: 'gpt-5.4-mini'
        model: {
          name: 'gpt-5.4-mini'
          format: 'OpenAI'
          version: '2026-03-17'
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 50
        }
      }
      {
        name: 'text-embedding-3-small'
        model: {
          name: 'text-embedding-3-small'
          format: 'OpenAI'
          version: '1'
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 50
        }
      }
    ]
    aiFoundryConfiguration: {
      accountName: foundryAccountName
      location: location
      sku: 'S0'
      disableLocalAuth: true
      createCapabilityHosts: true
      networking: {
        agentServiceSubnetResourceId: foundryAgentSubnetId
        cognitiveServicesPrivateDnsZoneResourceId: zoneCognitive
        openAiPrivateDnsZoneResourceId: zoneOpenAi
        aiServicesPrivateDnsZoneResourceId: zoneAiServices
      }
      project: {
        name: foundryProjectName
        displayName: 'RAG private lab'
        desc: 'Private RAG lab project with Standard Agent Service capability hosts.'
      }
      roleAssignments: [
        {
          principalId: uamiBot.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services User'
        }
        // Function App ingest MI needs Cog Services User + OpenAI User on Foundry to
        // call the embedding model from the queue trigger. Without these grants the
        // ProcessDocument function fails with 401 PermissionDenied and messages go to poison.
        {
          principalId: uamiIngestion.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services User'
        }
        {
          principalId: uamiIngestion.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
        }
        // Search service MI needs Cog Services User + OpenAI User on Foundry so the
        // Foundry IQ Knowledge Base embedding call (Search -> Foundry over the SPL)
        // is authorized. Without these grants the playground returns 401 Unauthorized.
        {
          principalId: search.outputs.systemAssignedMIPrincipalId!
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services User'
        }
        {
          principalId: search.outputs.systemAssignedMIPrincipalId!
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
        }
      ]
    }
    keyVaultConfiguration: {
      existingResourceId: keyVault.outputs.resourceId
      privateDnsZoneResourceId: zoneVault
    }
    aiSearchConfiguration: {
      existingResourceId: search.outputs.resourceId
      privateDnsZoneResourceId: zoneSearch
      sku: 'standard'
      replicaCount: 1
      partitionCount: 1
    }
    storageAccountConfiguration: {
      existingResourceId: storage.outputs.resourceId
      blobPrivateDnsZoneResourceId: zoneBlob
    }
    cosmosDbConfiguration: {
      existingResourceId: cosmos.outputs.resourceId
      privateDnsZoneResourceId: zoneCosmos
      enableZoneRedundancy: false
      enableServerless: true
    }
    tags: tags
  }
  dependsOn: [
    privateDnsZones
    virtualNetwork
  ]
}

module searchSplStorage 'br/public:avm/res/search/search-service/shared-private-link-resource:0.1.0' = {
  name: 'search-spl-storage'
  params: {
    searchServiceName: search.outputs.name
    name: 'spl-blob'
    privateLinkResourceId: storage.outputs.resourceId
    groupId: 'blob'
    requestMessage: 'Allow AI Search indexers to reach private Blob Storage.'
    resourceRegion: location
  }
}

module searchSplCosmos 'br/public:avm/res/search/search-service/shared-private-link-resource:0.1.0' = {
  name: 'search-spl-cosmos'
  params: {
    searchServiceName: search.outputs.name
    name: 'spl-cosmos'
    privateLinkResourceId: cosmos.outputs.resourceId
    groupId: 'Sql'
    requestMessage: 'Allow AI Search indexers to reach private Cosmos DB.'
    resourceRegion: location
  }
}

// NOTE: search-spl-docintel removed - Doc Intelligence is not a valid Search shared-PL target
// (Cognitive Services groupId 'account' is not supported for non-OpenAI accounts). In our flow
// Functions calls Doc Intelligence directly via its own private endpoint, so no Search PL needed.

// AI Search -> Foundry shared private links: REQUIRED for the Foundry IQ Knowledge Base
// embedding call when Foundry has publicNetworkAccess=Disabled. Two SPLs needed because
// Foundry (kind=AIServices) exposes both the legacy OpenAI host (*.openai.azure.com) and
// the multi-service host (*.cognitiveservices.azure.com). The Knowledge Base may call either.
//
// IMPORTANT: SPLs to Foundry are created out-of-band (POST-DEPLOY.md "Step 7") rather than
// in Bicep. The Search RP only permits updates to the `requestMessage` property after creation,
// so any subsequent Bicep deploy that re-PUTs the SPL with the same params fails with
// "When updating a shared private link resource, only 'requestMessage' property is allowed
// to be modified". Keeping SPLs as a one-shot az rest PUT avoids this drift trap.
//
// The Bicep-managed SPLs (spl-blob, spl-cosmos) above target resource types whose RP behaves
// correctly on idempotent PUT, so they remain in IaC.

// Queue private endpoint + DNS zone for the Function App's ingest queue.
// The Foundry AVM pattern only creates the blob PE on the shared storage account;
// the Function App's queue trigger needs a separate queue PE because storage
// publicNetworkAccess=Disabled blocks the public queue endpoint.
module storageQueuePE 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'pe-storage-queue'
  params: {
    name: 'pe-${storageName}-queue'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'conn-queue'
        properties: {
          privateLinkServiceId: storage.outputs.resourceId
          groupIds: [ 'queue' ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          privateDnsZoneResourceId: zoneQueue
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    privateDnsZones
  ]
}

// Cosmos full-account-scope grant for Foundry project MI.
// The AVM Foundry pattern only grants the project MI on 3 specific containers
// (system-thread-message-store, thread-message-store, agent-entity-store). Newer
// agent containers like 'agent-definitions-v1' are out of scope and the agent
// creation API returns 401 Unauthorized. Account-scope grant covers all current
// and future containers under the cosmos account.
resource cosmosAccountExisting 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosName
}

resource foundryProjectExisting 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: '${foundryAccountName}/${foundryProjectName}'
}

resource cosmosAccountScopeGrantForFoundryProject 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmosAccountExisting
  name: guid(cosmosName, foundryProjectName, 'cosmos-account-scope-data-contributor')
  properties: {
    roleDefinitionId: resourceId('Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', cosmosName, '00000000-0000-0000-0000-000000000002')
    principalId: foundryProjectExisting.identity.principalId
    scope: cosmosAccountExisting.id
  }
  dependsOn: [
    foundry
    cosmos
  ]
}

module botPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'bot-plan'
  params: {
    name: botPlanName
    location: location
    skuName: 'P0v3'
    skuCapacity: 1
    zoneRedundant: false
    reserved: true
    kind: 'linux'
    tags: tags
  }
}

module functionPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'function-plan'
  params: {
    name: functionPlanName
    location: location
    skuName: 'EP1'
    skuCapacity: 1
    zoneRedundant: false
    reserved: true
    kind: 'elastic'
    tags: tags
  }
}

module botApp 'br/public:avm/res/web/site:0.23.1' = {
  name: 'bot-app'
  params: {
    name: botAppName
    location: location
    kind: 'app,linux'
    serverFarmResourceId: botPlan.outputs.resourceId
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetResourceId: computeSubnetId
    keyVaultAccessIdentityResourceId: uamiBot.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        uamiBot.outputs.resourceId
      ]
    }
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: true
      healthCheckPath: '/health'
    }
    outboundVnetRouting: {
      allTraffic: true
      applicationTraffic: true
      contentShareTraffic: true
      imagePullTraffic: true
      backupRestoreTraffic: true
    }
    configs: [
      {
        name: 'appsettings'
        properties: {
          AZURE_CLIENT_ID: uamiBot.outputs.clientId
          FOUNDRY_PROJECT_ENDPOINT: 'https://${foundry.outputs.aiServicesName}.services.ai.azure.com/api/projects/${foundry.outputs.aiProjectName}'
          FOUNDRY_PROJECT_NAME: foundry.outputs.aiProjectName
          AGENT_ID: '<foundry-agent-id>'
          APPLICATIONINSIGHTS_CONNECTION_STRING: '@Microsoft.KeyVault(SecretUri=${appInsightsConnectionStringSecret.properties.secretUriWithVersion})'
        }
      }
    ]
    tags: tags
  }
}

module functionApp 'br/public:avm/res/web/site:0.23.1' = {
  name: 'function-app'
  params: {
    name: functionAppName
    location: location
    kind: 'functionapp,linux'
    serverFarmResourceId: functionPlan.outputs.resourceId
    storageAccountRequired: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetResourceId: computeSubnetId
    keyVaultAccessIdentityResourceId: uamiIngestion.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        uamiIngestion.outputs.resourceId
      ]
    }
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: true
    }
    outboundVnetRouting: {
      allTraffic: true
      applicationTraffic: true
      contentShareTraffic: true
      imagePullTraffic: true
      backupRestoreTraffic: true
    }
    configs: [
      {
        name: 'appsettings'
        storageAccountResourceId: storage.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
        properties: {
          AzureWebJobsStorage__accountName: storage.outputs.name
          AZURE_CLIENT_ID: uamiIngestion.outputs.clientId
          AZURE_SEARCH_ENDPOINT: search.outputs.endpoint
          AZURE_SEARCH_INDEX: 'rag-lab-docs'
          DOC_INTELLIGENCE_ENDPOINT: docIntelligence.outputs.endpoint
          BLOB_STORAGE_ACCOUNT: storage.outputs.name
          SPO_SITE_ID: sharePointSiteId
          SPO_DRIVE_NAME: sharePointDriveName
          GRAPH_TENANT_ID: tenantId
          WEBSITE_VNET_ROUTE_ALL: '1'
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: 'python'
          APPLICATIONINSIGHTS_CONNECTION_STRING: '@Microsoft.KeyVault(SecretUri=${appInsightsConnectionStringSecret.properties.secretUriWithVersion})'
        }
      }
    ]
    tags: tags
  }
}

resource botService 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botServiceName
  location: 'global'
  kind: 'azurebot'
  sku: {
    name: 'F0'
  }
  properties: {
    displayName: botServiceName
    endpoint: 'https://${botApp.outputs.defaultHostname}/api/messages'
    msaAppId: uamiBot.outputs.clientId
    msaAppMSIResourceId: uamiBot.outputs.resourceId
    msaAppTenantId: tenantId
    msaAppType: 'UserAssignedMSI'
  }
  tags: tags
}

module peKeyVault 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-key-vault'
  params: {
    name: 'pe-${keyVaultName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${keyVaultName}'
        properties: {
          groupIds: [ 'vault' ]
          privateLinkServiceId: keyVault.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-vaultcore-azure-net'
          privateDnsZoneResourceId: zoneVault
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peStorageBlob 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-storage-blob'
  params: {
    name: 'pe-${storageName}-blob'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageName}-blob'
        properties: {
          groupIds: [ 'blob' ]
          privateLinkServiceId: storage.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-blob-storage'
          privateDnsZoneResourceId: zoneBlob
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peCosmos 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-cosmos'
  params: {
    name: 'pe-${cosmosName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${cosmosName}'
        properties: {
          groupIds: [ 'Sql' ]
          privateLinkServiceId: cosmos.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-documents'
          privateDnsZoneResourceId: zoneCosmos
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peSearch 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-search'
  params: {
    name: 'pe-${searchName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${searchName}'
        properties: {
          groupIds: [ 'searchService' ]
          privateLinkServiceId: search.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-search'
          privateDnsZoneResourceId: zoneSearch
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peDocIntelligence 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-doc-intelligence'
  params: {
    name: 'pe-${docIntelName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${docIntelName}'
        properties: {
          groupIds: [ 'account' ]
          privateLinkServiceId: docIntelligence.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-cognitive'
          privateDnsZoneResourceId: zoneCognitive
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peAppConfig 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-app-config'
  params: {
    name: 'pe-${appConfigName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${appConfigName}'
        properties: {
          groupIds: [ 'configurationStores' ]
          privateLinkServiceId: appConfig.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-azconfig'
          privateDnsZoneResourceId: zoneAppConfig
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peBotApp 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-bot-app'
  params: {
    name: 'pe-${botAppName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${botAppName}'
        properties: {
          groupIds: [ 'sites' ]
          privateLinkServiceId: botApp.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-web'
          privateDnsZoneResourceId: zoneWeb
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peFunctionApp 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-function-app'
  params: {
    name: 'pe-${functionAppName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${functionAppName}'
        properties: {
          groupIds: [ 'sites' ]
          privateLinkServiceId: functionApp.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-web'
          privateDnsZoneResourceId: zoneWeb
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}

module peAmpls 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-ampls'
  params: {
    name: 'pe-${amplsName}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'pe-${amplsName}'
        properties: {
          groupIds: [ 'azuremonitor' ]
          privateLinkServiceId: ampls.outputs.resourceId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'privatelink-monitor'
          privateDnsZoneResourceId: zoneMonitor
        }
        {
          name: 'privatelink-ods'
          privateDnsZoneResourceId: zoneOds
        }
        {
          name: 'privatelink-oms'
          privateDnsZoneResourceId: zoneOms
        }
        {
          name: 'privatelink-automation'
          privateDnsZoneResourceId: zoneAutomation
        }
      ]
    }
    tags: tags
  }
  dependsOn: [ privateDnsZones, virtualNetwork ]
}
output botAppName string = botApp.outputs.name
output functionAppName string = functionApp.outputs.name
output foundryAccountName string = foundry.outputs.aiServicesName
output foundryProjectName string = foundry.outputs.aiProjectName
output searchEndpoint string = search.outputs.endpoint
output docIntelligenceEndpoint string = docIntelligence.outputs.endpoint
output storageAccountName string = storage.outputs.name
output keyVaultName string = keyVault.outputs.name
output jumpVmName string = jumpVm.outputs.name
output jumpVmAdminUsername string = jumpVmAdminUsername

// =====================================================================
// Jump VM (Windows, Bastion-accessed) - for operator access to Foundry
// portal and private FQDNs from inside the VNet. Hybrid Benefit ON
// (requires qualifying Windows Client + SA / VDA license held by deployer).
// =====================================================================
var jumpVmName = take('vm-jump-${uniqueSuffix}', 15)
var jumpSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-jump')

module jumpVm 'br/public:avm/res/compute/virtual-machine:0.9.0' = {
  name: 'jump-vm'
  params: {
    name: jumpVmName
    location: location
    computerName: jumpVmName
    vmSize: 'Standard_D2as_v5'
    osType: 'Windows'
    licenseType: 'Windows_Client'
    zone: 0
    adminUsername: jumpVmAdminUsername
    adminPassword: jumpVmAdminPassword
    imageReference: {
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'Windows-11'
      sku: 'win11-24h2-pro'
      version: 'latest'
    }
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 128
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    nicConfigurations: [
      {
        name: 'nic-${jumpVmName}'
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: jumpSubnetId
          }
        ]
        networkSecurityGroupResourceId: nsgJump.outputs.resourceId
      }
    ]
    encryptionAtHost: false
    tags: tags
  }
  dependsOn: [ virtualNetwork ]
}




