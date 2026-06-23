using './main.bicep'

// PLACEHOLDER PARAMETERS - REPLACE BEFORE DEPLOY
//
// 1. Copy this file to `main.deploy.bicepparam` (which is gitignored).
// 2. Fill in real values for the placeholders below.
// 3. Generate a strong Windows password for `jumpVmAdminPassword`
//    (12-123 chars, must satisfy Azure Windows VM complexity rules).
// 4. Deploy with:
//      az deployment sub create --location <region> \
//        --template-file ./infra/main.bicep \
//        --parameters ./infra/main.deploy.bicepparam

param baseName = 'ragbot'
param environmentName = 'lab'
param deployerObjectId = '<your-aad-object-id>'
param location = 'westus3'
param aiSearchLocation = 'centralus'
param resourceGroupName = 'rg-ailab-rag-westus3'
param tenantId = '<your-tenant-id>'
param sharePointSiteId = '<your-sharepoint-site-id>'
param sharePointDriveName = 'Documents'
param jumpVmAdminUsername = 'azureuser'
param jumpVmAdminPassword = '<generate-a-strong-windows-password>'
