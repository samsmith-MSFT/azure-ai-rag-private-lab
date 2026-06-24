# Post-Deployment Setup
> One-time manual steps required after Bicep deployment completes successfully.

This runbook starts after the subscription-scope Bicep deployment succeeds. It ends when the Foundry agent can answer questions over SharePoint documents through the private ingestion path.

## Prerequisites

- Azure CLI 2.87+
- jq (recommended for parsing)
- The deployment dir from `~/.copilot/azure-deploy/deployments/.../`
- (Optional) Microsoft Graph Explorer for SharePoint permission grants

Set these placeholders once per shell. Replace every value before running examples.

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export TENANT_ID="<tenant-id>"
export RG="<rg-name>"
export LOCATION="<primary-region>"
export SEARCH_NAME="<search-name>"
export FOUNDRY_NAME="<foundry-name>"
export FOUNDRY_PROJECT_NAME="<foundry-project-name>"
export COSMOS_NAME="<cosmos-name>"
export STORAGE_NAME="<storage-account-name>"
export FUNC_NAME="<function-app-name>"
export JUMP_VM_NAME="<jump-vm-name>"
export UAMI_INGESTION_NAME="uami-ingestion"
export SITE_ID="<sharepoint-site-id>"
```

```powershell
$SubscriptionId = "<subscription-id>"
$TenantId = "<tenant-id>"
$Rg = "<rg-name>"
$Location = "<primary-region>"
$SearchName = "<search-name>"
$FoundryName = "<foundry-name>"
$FoundryProjectName = "<foundry-project-name>"
$CosmosName = "<cosmos-name>"
$StorageName = "<storage-account-name>"
$FuncName = "<function-app-name>"
$JumpVmName = "<jump-vm-name>"
$UamiIngestionName = "uami-ingestion"
$SiteId = "<sharepoint-site-id>"
```

## Step 1 - Sign in and verify subscription

Why: Some subscriptions are linked to a different tenant than the one selected by your default Azure CLI profile. Setting the subscription alone does not switch tenants; sign in to the deployment tenant explicitly.

```bash
az login --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o json
```

Expected: `tenant` equals `<tenant-id>` and `subscription` equals `<subscription-id>`.

## Step 2 - Grant your user RBAC on the new resources

Why: The deployment grants managed identities the runtime permissions, but the deploying user also needs management-plane and data-plane permissions for post-deploy setup: Search index creation, Foundry agent setup, and Cosmos debugging.

Get your signed-in object ID.

```bash
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
RG_ID=$(az group show -n "<rg-name>" --query id -o tsv)
SEARCH_ID=$(az search service show -g "<rg-name>" -n "<search-name>" --query id -o tsv)
FOUNDRY_ID=$(az cognitiveservices account show -g "<rg-name>" -n "<foundry-name>" --query id -o tsv)
COSMOS_ID=$(az cosmosdb show -g "<rg-name>" -n "<cosmos-name>" --query id -o tsv)
```

Grant resource-group Contributor if you do not already have it.

```bash
az role assignment create --assignee "$USER_OBJECT_ID" --role "Contributor" --scope "$RG_ID"
```

Grant AI Search management and index data permissions.

```bash
az role assignment create --assignee "$USER_OBJECT_ID" --role "Search Service Contributor" --scope "$SEARCH_ID"
az role assignment create --assignee "$USER_OBJECT_ID" --role "Search Index Data Contributor" --scope "$SEARCH_ID"
```

Grant Foundry permissions for project and agent work.

```bash
az role assignment create --assignee "$USER_OBJECT_ID" --role "Cognitive Services User" --scope "$FOUNDRY_ID"
az role assignment create --assignee "$USER_OBJECT_ID" --role "Azure AI Developer" --scope "$FOUNDRY_ID"
```

Grant Cosmos data-plane read/write for debugging agent state. This is a Cosmos SQL built-in role assignment, not an Azure RBAC role assignment.

```bash
az cosmosdb sql role assignment create \
  --resource-group "<rg-name>" \
  --account-name "<cosmos-name>" \
  --role-definition-id "00000000-0000-0000-0000-000000000002" \
  --principal-id "$USER_OBJECT_ID" \
  --scope "$COSMOS_ID"
```

Allow several minutes for RBAC propagation before creating the Search index or Foundry agent.

## Step 3 - Connect to the jump VM via Bastion

Why: Most data-plane endpoints are private-only. Use the Windows 11 jump VM to create the Search index, create the queue, publish Functions, and run private DNS checks from inside the VNet.

The VM local admin credentials are in the local deployment parameter file. That file is intentionally gitignored.

```powershell
Get-Content ".\infra\main.deploy.bicepparam"
```

In Azure portal, open the VM resource, select **Bastion**, use username `azureuser` unless you changed `jumpVmAdminUsername`, and paste the password from `jumpVmAdminPassword`.

After login, confirm the VM has a managed identity and can reach IMDS.

```powershell
Invoke-RestMethod `
  -Headers @{ Metadata = "true" } `
  -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
```

## Step 4 - Set up SharePoint test site

Why: The ingestion Function reads SharePoint through Microsoft Graph using managed identity and `Sites.Selected`. The app can access only the exact site you grant.

### 4a. Create the site

Portal path: SharePoint admin center → Active sites → **Create** → Team site or Communication site. Record the site URL and resolve the Graph site ID.

```bash
HOSTNAME="<tenant>.sharepoint.com"
SITE_PATH="/sites/<site-name>"
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/sites/${HOSTNAME}:${SITE_PATH}" \
  --query id -o tsv
```

If using REST for site creation, use an app or delegated user that has permission to create SharePoint sites. `Sites.Selected` is sufficient for later access but not for tenant-wide site creation.

```http
POST https://graph.microsoft.com/v1.0/sites
Content-Type: application/json

{
  "displayName": "<site-display-name>",
  "name": "<site-name>",
  "webUrl": "https://<tenant>.sharepoint.com/sites/<site-name>"
}
```

### 4b. Grant the Function and VM managed identities Sites.Selected Read

Why: `uami-ingestion` scans and downloads documents. The jump VM system-assigned identity is useful for validating Graph access from the same private host used for setup.

Get the managed identity application IDs.

```bash
FUNC_MI_APP_ID=$(az identity show -g "<rg-name>" -n "uami-ingestion" --query clientId -o tsv)
VM_MI_PRINCIPAL_ID=$(az vm identity show -g "<rg-name>" -n "<jump-vm-name>" --query principalId -o tsv)
VM_MI_APP_ID=$(az ad sp show --id "$VM_MI_PRINCIPAL_ID" --query appId -o tsv)
```

Grant both identities read access to the site. Run with a Graph token that can manage site permissions, such as Graph Explorer with `Sites.FullControl.All`, or an admin-approved automation identity.

```bash
for APP_ID in "$FUNC_MI_APP_ID" "$VM_MI_APP_ID"; do
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/sites/<site-id>/permissions" \
    --headers "Content-Type=application/json" \
    --body "{\"roles\":[\"read\"],\"grantedToIdentities\":[{\"application\":{\"id\":\"${APP_ID}\",\"displayName\":\"managed-identity\"}}]}"
done
```

Validate with the singular default document library endpoint. Do not use the drives enumeration endpoint for this app.

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/sites/<site-id>/drive/root/children"
```

### 4c. Upload test documents (⚠ generate outside OneDrive)

Why: Office sidecar processes in OneDrive-synced folders can silently rewrite generated `.docx` files to legacy compound-document binary format. Document Intelligence and the ingestion code expect real Open XML `.docx` files with ZIP magic bytes.

Generate sample files in `%TEMP%`, verify the first four bytes are `50 4B 03 04`, then upload using the SharePoint browser UI.

```powershell
$Docx = Join-Path $env:TEMP "sample-policy.docx"
# Create or copy the DOCX into $Docx before upload.
(Get-Content -Encoding Byte -TotalCount 4 $Docx) | ForEach-Object { $_.ToString("X2") }
```

Expected output:

```text
50
4B
03
04
```

If the first four bytes are `D0 CF 11 E0`, discard the file and regenerate it outside OneDrive.

## Step 5 - Create the 2 Foundry shared private links from AI Search

Why: Foundry Knowledge Base retrieval causes AI Search to call the embedding model. Search needs shared private links to Foundry because Foundry public access is disabled for data paths. Foundry `kind=AIServices` exposes both OpenAI and Cognitive Services hosts, so one SPL is insufficient.

Use JSON files for request bodies. Inline JSON often fails shell parsing for this API.

### 5a. Create spl-foundry (openai_account)

```bash
FOUNDRY_ID=$(az cognitiveservices account show -g "<rg-name>" -n "<foundry-name>" --query id -o tsv)
cat > spl-foundry-openai.json <<'JSON'
{
  "properties": {
    "privateLinkResourceId": "<foundry-resource-id>",
    "groupId": "openai_account",
    "requestMessage": "Allow AI Search Knowledge Base to call Foundry OpenAI embeddings over private link.",
    "resourceRegion": "<foundry-region>"
  }
}
JSON
sed -i "s|<foundry-resource-id>|${FOUNDRY_ID}|g; s|<foundry-region>|<primary-region>|g" spl-foundry-openai.json
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Search/searchServices/<search-name>/sharedPrivateLinkResources/spl-foundry?api-version=2024-06-01-preview" \
  --body @spl-foundry-openai.json
```

PowerShell equivalent for Windows shells:

```powershell
$FoundryId = az cognitiveservices account show -g "<rg-name>" -n "<foundry-name>" --query id -o tsv
@{
  properties = @{
    privateLinkResourceId = $FoundryId
    groupId = "openai_account"
    requestMessage = "Allow AI Search Knowledge Base to call Foundry OpenAI embeddings over private link."
    resourceRegion = "<primary-region>"
  }
} | ConvertTo-Json -Depth 10 | Set-Content -Path ".\spl-foundry-openai.json" -Encoding utf8
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Search/searchServices/<search-name>/sharedPrivateLinkResources/spl-foundry?api-version=2024-06-01-preview" `
  --body "@spl-foundry-openai.json"
```

### 5b. Create spl-foundry-cogsvc (cognitiveservices_account)

```bash
cat > spl-foundry-cogsvc.json <<'JSON'
{
  "properties": {
    "privateLinkResourceId": "<foundry-resource-id>",
    "groupId": "cognitiveservices_account",
    "requestMessage": "Allow AI Search Knowledge Base to call Foundry Cognitive Services endpoint over private link.",
    "resourceRegion": "<foundry-region>"
  }
}
JSON
sed -i "s|<foundry-resource-id>|${FOUNDRY_ID}|g; s|<foundry-region>|<primary-region>|g" spl-foundry-cogsvc.json
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Search/searchServices/<search-name>/sharedPrivateLinkResources/spl-foundry-cogsvc?api-version=2024-06-01-preview" \
  --body @spl-foundry-cogsvc.json
```

```powershell
@{
  properties = @{
    privateLinkResourceId = $FoundryId
    groupId = "cognitiveservices_account"
    requestMessage = "Allow AI Search Knowledge Base to call Foundry Cognitive Services endpoint over private link."
    resourceRegion = "<primary-region>"
  }
} | ConvertTo-Json -Depth 10 | Set-Content -Path ".\spl-foundry-cogsvc.json" -Encoding utf8
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Search/searchServices/<search-name>/sharedPrivateLinkResources/spl-foundry-cogsvc?api-version=2024-06-01-preview" `
  --body "@spl-foundry-cogsvc.json"
```

### 5c. Approve the auto-generated PEs on the Foundry side

Why: Search creates pending private endpoint connections against the Foundry account. Foundry will not accept Search traffic until those connections are approved.

```bash
az network private-endpoint-connection list \
  --id "$FOUNDRY_ID" \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv
```

```bash
for PEC_ID in $(az network private-endpoint-connection list --id "$FOUNDRY_ID" --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv); do
  az network private-endpoint-connection approve \
    --id "$PEC_ID" \
    --description "Approved for AI Search Knowledge Base private embedding calls"
done
```

## Step 6 - Create the AI Search ragdocs index (from jump VM)

Why: The Function uploads documents to a fixed schema. Search is private-endpoint only, so create the index from a VNet-resident host such as the jump VM.

Use the repo script if present; it obtains an Azure AD token through IMDS and sends the index PUT to the private Search endpoint.

```powershell
cd "<repo-dir>"
.\scripts\s1-create-index-imds.ps1 -SearchName "<search-name>" -IndexName "ragdocs"
```

If the script is not available, this is the exact schema the index must use.

```powershell
$Token = (Invoke-RestMethod `
  -Headers @{ Metadata = "true" } `
  -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fsearch.azure.com%2F").access_token

$Index = @{
  name = "ragdocs"
  fields = @(
    @{ name = "id"; type = "Edm.String"; key = $true; filterable = $true },
    @{ name = "content"; type = "Edm.String"; searchable = $true },
    @{ name = "contentVector"; type = "Collection(Edm.Single)"; searchable = $true; dimensions = 1536; vectorSearchProfile = "default" },
    @{ name = "title"; type = "Edm.String"; searchable = $true; filterable = $true },
    @{ name = "sourceDoc"; type = "Edm.String"; filterable = $true },
    @{ name = "sourceUrl"; type = "Edm.String" },
    @{ name = "chunkIndex"; type = "Edm.Int32"; filterable = $true }
  )
  vectorSearch = @{
    algorithms = @(@{ name = "default-hnsw"; kind = "hnsw" })
    profiles = @(@{ name = "default"; algorithm = "default-hnsw" })
  }
  semantic = @{
    configurations = @(@{
      name = "default-semantic"
      prioritizedFields = @{
        titleField = @{ fieldName = "title" }
        prioritizedContentFields = @(@{ fieldName = "content" })
        prioritizedKeywordsFields = @(@{ fieldName = "sourceDoc" })
      }
    })
  }
} | ConvertTo-Json -Depth 20

Invoke-RestMethod `
  -Method PUT `
  -Uri "https://<search-name>.search.windows.net/indexes/ragdocs?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
  -Body $Index
```

Validate private DNS from the jump VM.

```powershell
Resolve-DnsName "<search-name>.search.windows.net"
```

Expected: a private IP from the VNet, not a public IP.

## Step 7 - Configure Function App settings

Why: Bicep configures infrastructure defaults, but these ingestion settings depend on post-deploy decisions: the live Foundry endpoint, queue name, manifest location, and the index name created in Step 6.

```bash
az functionapp config appsettings set \
  --resource-group "<rg-name>" \
  --name "<function-app-name>" \
  --settings \
    AZURE_FOUNDRY_ENDPOINT="https://<foundry-name>.openai.azure.com/" \
    EMBEDDING_DEPLOYMENT_NAME="text-embedding-3-small" \
    INGEST_QUEUE_NAME="ingest-queue" \
    INGEST_MANIFEST_CONTAINER="rag-content" \
    INGEST_MANIFEST_BLOB="ingest-state/manifest.json" \
    AZURE_SEARCH_INDEX="ragdocs"
```

Confirm the values.

```bash
az functionapp config appsettings list \
  --resource-group "<rg-name>" \
  --name "<function-app-name>" \
  --query "[?name=='AZURE_SEARCH_INDEX' || name=='AZURE_FOUNDRY_ENDPOINT' || name=='INGEST_QUEUE_NAME']"
```

## Step 8 - Create the ingest-queue (from jump VM)

Why: The storage container is created by Bicep, but the queue is not. The Function queue trigger needs `ingest-queue`, and the queue endpoint must resolve through `privatelink.queue.core.windows.net`.

From the jump VM, use the VM managed identity or an Azure CLI login with Storage Queue Data Contributor on the storage account.

```powershell
$StorageName = "<storage-account-name>"
$QueueName = "ingest-queue"
$Token = (Invoke-RestMethod `
  -Headers @{ Metadata = "true" } `
  -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F").access_token
$Date = (Get-Date).ToUniversalTime().ToString("R")

Invoke-RestMethod `
  -Method PUT `
  -Uri "https://$StorageName.queue.core.windows.net/$QueueName?restype=queue" `
  -Headers @{
    Authorization = "Bearer $Token"
    "x-ms-date" = $Date
    "x-ms-version" = "2023-11-03"
  }
```

Verify queue DNS and the existing `rag-content` blob container.

```powershell
Resolve-DnsName "<storage-account-name>.queue.core.windows.net"
Resolve-DnsName "<storage-account-name>.blob.core.windows.net"

$BlobToken = (Invoke-RestMethod `
  -Headers @{ Metadata = "true" } `
  -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F").access_token
Invoke-RestMethod `
  -Method GET `
  -Uri "https://<storage-account-name>.blob.core.windows.net/rag-content?restype=container" `
  -Headers @{ Authorization = "Bearer $BlobToken"; "x-ms-date" = (Get-Date).ToUniversalTime().ToString("R"); "x-ms-version" = "2023-11-03" }
```

Expected: both names resolve to private IPs, and the container request returns metadata instead of public-network `403`.

## Step 9 - Install Functions Core Tools + Azure CLI on jump VM

Why: The Windows 11 image does not include the deployment tools. Install them inside the VNet so publishing and private endpoint validation run from the same network path the Function uses.

Install Azure CLI.

```powershell
Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindows" -OutFile ".\AzureCLI.msi"
Start-Process msiexec.exe -Wait -ArgumentList "/i AzureCLI.msi /quiet"
```

Install Functions Core Tools 4.x from the GitHub releases MSI named `func-cli-X.Y.Z-x64.msi`. Do not look for the retired `Azure.Functions.Cli.win-x64.X.Y.Z.msi` asset name.

```powershell
$Release = Invoke-RestMethod "https://api.github.com/repos/Azure/azure-functions-core-tools/releases/latest"
$Asset = $Release.assets | Where-Object { $_.name -match '^func-cli-.*-x64\.msi$' } | Select-Object -First 1
Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile ".\$($Asset.name)"
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$($Asset.name)`" /quiet"
```

Open a new PowerShell session and verify.

```powershell
az version
func --version
```

## Step 10 - Publish the Function from jump VM

Why: The Function App and Kudu SCM endpoint are private. Publishing from the jump VM avoids public ingress and uses remote build so Linux Python 3.11 dependencies are built correctly.

Sign in on the VM and select the correct tenant/subscription.

```powershell
az login --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
```

Warm Kudu SCM once. The first cold SCM call can otherwise time out while `func publish` is updating environment settings.

```powershell
Invoke-WebRequest "https://<function-app-name>.scm.azurewebsites.net/api/settings" -UseBasicParsing
```

Publish from the Function source directory.

```powershell
cd "<repo-dir>\src\functions\spo-ingest"
func azure functionapp publish "<function-app-name>" --python --build remote
```

A local Python 3.12 vs runtime Python 3.11 warning is harmless with `--build remote`; Oryx builds on the Function App's Linux Python 3.11 runtime.

Verify functions after a short warmup.

```powershell
Start-Sleep -Seconds 30
az functionapp function list -g "<rg-name>" -n "<function-app-name>" --query "[].name" -o tsv
```

Expected functions:

```text
<function-app-name>/ScanSharePoint
<function-app-name>/ProcessDocument
```

## Step 11 - Create the Foundry agent + Knowledge Base (portal)

Why: Agent and Knowledge Base creation are operator choices after the Search index exists and Search can reach Foundry privately. Use Foundry IQ, not the older Knowledge tab, so the agent uses the Search-backed KB path.

Portal flow:

1. Open `https://ai.azure.com`.
2. Select `<foundry-project-name>`.
3. Go to **Agents** → **New Agent**.
4. Name the agent `contoso-policy-bot` or a customer-specific name.
5. Select model deployment `gpt-5.4-mini`.
6. Add a Knowledge Base through **Foundry IQ**.
7. Set KB name `contoso-policies`.
8. Source: Azure AI Search index `ragdocs` on `<search-name>`.
9. Embedding model: `text-embedding-3-small`.
10. Attach the KB to the agent.
11. Remove the default Web search tool. The agent should ground only on the KB.

Record the agent ID if the bot app will call this agent later.

## Step 12 - Trigger initial ingest

Why: The timer runs every five minutes, but force the first scan so you can validate queue, Graph, Document Intelligence, embedding, and Search upload without waiting.

Get the master key and call the timer admin endpoint from a host that can resolve the private Function endpoint.

```powershell
$MasterKey = az functionapp keys list `
  -g "<rg-name>" `
  -n "<function-app-name>" `
  --query "masterKey" -o tsv

Invoke-RestMethod `
  -Method POST `
  -Uri "https://<function-app-name>.azurewebsites.net/admin/functions/ScanSharePoint" `
  -Headers @{ "x-functions-key" = $MasterKey } `
  -ContentType "application/json" `
  -Body "{}"
```

Watch logs and queue depth.

```powershell
az webapp log tail -g "<rg-name>" -n "<function-app-name>"
```

One-shot backfill option: if the repo includes `scripts\s3b-ingest.py`, use it only as a bootstrap/debug tool from the jump VM. The steady-state path should be the timer plus queue-trigger Function.

## Step 13 - Validate end-to-end via Foundry playground

Why: Infrastructure validation is not enough. The acceptance test is whether the agent answers from indexed SharePoint content, cites the KB, and refuses out-of-scope questions.

In the Foundry playground for the agent, run these prompts:

| Prompt | Expected result |
| --- | --- |
| `How much PTO do I accrue after 5 years?` | Specific number from the PTO Policy document with citation. |
| `Can I expense a bottle of wine?` | Refusal or disallowance grounded in the expense policy. |
| `Can I use MFA from a coffee shop?` | MFA-required answer grounded in the security policy. |
| `Can I paste customer code into ChatGPT?` | Refusal grounded in AI Acceptable Use policy. |
| `What is the 401k company match?` | Specific match formula from the benefits document with citation. |
| `What is the weather in Seattle tomorrow?` | Graceful refusal; out of scope because Web search was removed. |

If citations are absent, validate the agent has the KB attached and Web search removed. If answers are generic, validate `ragdocs` has documents.

```powershell
$Token = (az account get-access-token --resource "https://search.azure.com/" --query accessToken -o tsv)
Invoke-RestMethod `
  -Uri "https://<search-name>.search.windows.net/indexes/ragdocs/docs/`$count?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $Token" }
```

## Troubleshooting

### "401 Unauthorized" calling knowledge_base_retrieve

Verbatim error:

```text
401 Unauthorized
knowledge_base_retrieve failed
PermissionDenied
```

Likely causes:

- Search system-assigned managed identity lacks `Cognitive Services User` and `Cognitive Services OpenAI User` on the Foundry account.
- The two Search shared private links to Foundry are missing or pending approval.
- Foundry project managed identity lacks account-scope Cosmos DB Built-in Data Contributor on the Cosmos account.

Check Search MI grants.

```bash
SEARCH_MI=$(az search service show -g "<rg-name>" -n "<search-name>" --query identity.principalId -o tsv)
FOUNDRY_ID=$(az cognitiveservices account show -g "<rg-name>" -n "<foundry-name>" --query id -o tsv)
az role assignment list --assignee "$SEARCH_MI" --scope "$FOUNDRY_ID" -o table
```

Check Cosmos account-scope grant for the Foundry project MI. The Bicep includes this because the Foundry AVM pattern grants only selected containers; newer agent containers such as `agent-definitions-v1` require account scope.

```bash
az cosmosdb sql role assignment list -g "<rg-name>" -a "<cosmos-name>" -o table
```

### "403 Public access is disabled. Please configure private endpoint"

Verbatim error:

```text
403 Public access is disabled. Please configure private endpoint
```

You are hitting a public endpoint for a private-only service. Run the operation from the jump VM or a network with VNet/private DNS access, then verify name resolution.

```powershell
Resolve-DnsName "<search-name>.search.windows.net"
Resolve-DnsName "<storage-account-name>.queue.core.windows.net"
Resolve-DnsName "<function-app-name>.azurewebsites.net"
Resolve-DnsName "<function-app-name>.scm.azurewebsites.net"
```

### Function publish times out on "Updating Application Settings"

Verbatim error:

```text
Updating Application Settings
Timed out waiting for SCM site to respond
```

Warm Kudu SCM, then republish.

```powershell
Invoke-WebRequest "https://<function-app-name>.scm.azurewebsites.net/api/settings" -UseBasicParsing
cd "<repo-dir>\src\functions\spo-ingest"
func azure functionapp publish "<function-app-name>" --python --build remote
```

### ProcessDocument failures land in ingest-queue-poison

Verbatim error:

```text
Message has reached MaxDequeueCount of 5. Moving message to queue 'ingest-queue-poison'.
ProcessDocument failed
```

Common causes: invalid DOCX bytes, missing Foundry app settings, missing Function MI permissions on Foundry/Search/Storage/Document Intelligence, or Search schema mismatch.

```powershell
az webapp log tail -g "<rg-name>" -n "<function-app-name>"
az functionapp config appsettings list -g "<rg-name>" -n "<function-app-name>" --query "[?starts_with(name, 'AZURE_') || starts_with(name, 'INGEST_') || name=='SPO_SITE_ID']"
```

### DOCX uploads silently corrupted (D0 CF 11 E0 magic)

Verbatim symptom:

```text
D0
CF
11
E0
```

This is legacy Office compound-file binary, not `.docx` ZIP format. Generate test documents in `%TEMP%`, verify `50 4B 03 04`, then upload via browser.

```powershell
$Docx = Join-Path $env:TEMP "sample-policy.docx"
(Get-Content -Encoding Byte -TotalCount 4 $Docx) | ForEach-Object { $_.ToString("X2") }
```

Expected:

```text
50
4B
03
04
```

### "az login --identity" returns nothing on the jump VM

Verbatim symptom:

```text
[]
```

The VM may not have a system-assigned managed identity, the identity was added after login and needs a reboot, or IMDS is unreachable. Check VM identity and IMDS directly.

```powershell
az vm identity show -g "<rg-name>" -n "<jump-vm-name>"
Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"
```

### Python version warning on func publish

Verbatim warning:

```text
Your Python version is 3.12.x, but the Function App runtime is Python 3.11.
```

This is expected on the Windows jump VM when publishing with remote build. Oryx builds the package on Linux using the Function App runtime version.

```powershell
func azure functionapp publish "<function-app-name>" --python --build remote
```

Additional gotchas observed during deployment:

| Gotcha | Error message | Fix |
| --- | --- | --- |
| `Sites.Selected` permits the default drive but not drive enumeration. | `403 Forbidden` on `GET /sites/{id}/drives` | Use `GET /sites/{id}/drive/root/children`. The Function intentionally uses singular `/drive`. |
| Foundry `kind=AIServices` needs two SPL group IDs. | `403 Public access is disabled. Please configure private endpoint` | Create both `openai_account` and `cognitiveservices_account` SPLs and approve both PEs. |
| App Service / Function App regional quota is zero. | `This region has quota of 0 instances for this subscription` | Deploy the App Service plan in a region with quota; this lab uses a region that supports EP1. |
| AI Search S2 quota is zero in some regions. | `The requested SKU is not available for this subscription in this region` | Use S1 (`standard`) unless quota is approved for S2. |
| Deprecated mini model selected. | `The model gpt-4o-mini version 2024-07-18 is deprecated on 2026-03-31` | Use `gpt-5.4-mini` version `2026-03-17`. |
| Queue private DNS zone missing. | `403 Public access is disabled` from `*.queue.core.windows.net` | Ensure `privatelink.queue.core.windows.net` is linked and the queue PE exists. Blob private DNS is not enough. |

## Reference: Identities and what each gets

| Identity | Role(s) | Scope |
|----------|---------|-------|
| Deploying user | Contributor | Resource group `<rg-name>` |
| Deploying user | Search Service Contributor; Search Index Data Contributor | Search service `<search-name>` |
| Deploying user | Cognitive Services User; Azure AI Developer | Foundry account `<foundry-name>` |
| Deploying user | Cosmos DB Built-in Data Contributor | Cosmos account `<cosmos-name>` |
| `uami-ingestion` | Storage Blob Data Owner; Storage Queue Data Contributor; Storage Table Data Contributor | Storage account `<storage-account-name>` |
| `uami-ingestion` | Search Index Data Contributor | Search service `<search-name>` |
| `uami-ingestion` | Cognitive Services User | Document Intelligence account `<doc-intel-name>` |
| `uami-ingestion` | Cognitive Services User; Cognitive Services OpenAI User | Foundry account `<foundry-name>` |
| `uami-ingestion` | Sites.Selected `read` | SharePoint site `<site-id>` |
| Jump VM system-assigned MI | Sites.Selected `read` | SharePoint site `<site-id>` |
| `uami-bot` | Key Vault Secrets User | Key Vault `<key-vault-name>` |
| `uami-bot` | Storage Blob Data Reader | Storage account `<storage-account-name>` |
| `uami-bot` | Search Index Data Reader | Search service `<search-name>` |
| `uami-bot` | Cognitive Services User | Foundry account `<foundry-name>` |
| `uami-foundry` | Storage Blob Data Owner | Storage account `<storage-account-name>` |
| `uami-foundry` | Search Index Data Contributor; Search Service Contributor | Search service `<search-name>` |
| `uami-foundry` | DocumentDB Account Contributor | Cosmos account `<cosmos-name>` |
| Foundry project system MI | Cosmos DB Built-in Data Contributor | Cosmos account `<cosmos-name>` account scope |
| Search service system MI | Cognitive Services User; Cognitive Services OpenAI User | Foundry account `<foundry-name>` |

## Reference: Network paths

Run this from the jump VM to replace `<resolved-private-ip>` placeholders.

```powershell
@(
  "<foundry-name>.openai.azure.com",
  "<foundry-name>.cognitiveservices.azure.com",
  "<foundry-name>.services.ai.azure.com",
  "<search-name>.search.windows.net",
  "<cosmos-name>.documents.azure.com",
  "<storage-account-name>.blob.core.windows.net",
  "<storage-account-name>.queue.core.windows.net",
  "<key-vault-name>.vault.azure.net",
  "<app-config-name>.azconfig.io",
  "<doc-intel-name>.cognitiveservices.azure.com",
  "<function-app-name>.azurewebsites.net",
  "<function-app-name>.scm.azurewebsites.net",
  "<bot-app-name>.azurewebsites.net",
  "<bot-app-name>.scm.azurewebsites.net"
) | ForEach-Object { Resolve-DnsName $_ | Select-Object Name, IPAddress }
```

| Service | FQDN | Private IP after deploy | PE subnet | Private DNS zone |
| --- | --- | --- | --- | --- |
| Foundry OpenAI | `<foundry-name>.openai.azure.com` | `<resolved-private-ip>` | `snet-pe` plus Search-managed SPL PE | `privatelink.openai.azure.com` |
| Foundry Cognitive Services | `<foundry-name>.cognitiveservices.azure.com` | `<resolved-private-ip>` | `snet-pe` plus Search-managed SPL PE | `privatelink.cognitiveservices.azure.com` |
| Foundry AI Services | `<foundry-name>.services.ai.azure.com` | `<resolved-private-ip>` | `snet-pe` | `privatelink.services.ai.azure.com` |
| AI Search | `<search-name>.search.windows.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.search.windows.net` |
| Cosmos DB SQL | `<cosmos-name>.documents.azure.com` | `<resolved-private-ip>` | `snet-pe` | `privatelink.documents.azure.com` |
| Storage Blob | `<storage-account-name>.blob.core.windows.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.blob.core.windows.net` |
| Storage Queue | `<storage-account-name>.queue.core.windows.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.queue.core.windows.net` |
| Key Vault | `<key-vault-name>.vault.azure.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.vaultcore.azure.net` |
| App Configuration | `<app-config-name>.azconfig.io` | `<resolved-private-ip>` | `snet-pe` | `privatelink.azconfig.io` |
| Document Intelligence | `<doc-intel-name>.cognitiveservices.azure.com` | `<resolved-private-ip>` | `snet-pe` | `privatelink.cognitiveservices.azure.com` |
| Function App | `<function-app-name>.azurewebsites.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.azurewebsites.net` |
| Function Kudu SCM | `<function-app-name>.scm.azurewebsites.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.azurewebsites.net` |
| Bot App | `<bot-app-name>.azurewebsites.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.azurewebsites.net` |
| Bot Kudu SCM | `<bot-app-name>.scm.azurewebsites.net` | `<resolved-private-ip>` | `snet-pe` | `privatelink.azurewebsites.net` |
| Azure Monitor private link scope | AMPLS endpoints | `<resolved-private-ip>` | `snet-pe` | `privatelink.monitor.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net` |
| Foundry Agent Service delegated subnet | Capability host traffic | N/A | `snet-foundry-agent` | Uses Foundry-managed agent networking plus the Foundry DNS zones above |
