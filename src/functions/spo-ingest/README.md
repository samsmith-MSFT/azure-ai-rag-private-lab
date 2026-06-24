# SharePoint to Azure AI Search ingestion function

Python 3.11 Azure Functions v2 app that scans a SharePoint document library, queues changed `.docx` and `.pdf` files, parses them with Document Intelligence Layout, embeds chunks with Azure OpenAI in Foundry, and uploads idempotent chunk documents to Azure AI Search.

## Files

- `function_app.py` - `ScanSharePoint` timer trigger and `ProcessDocument` queue trigger.
- `requirements.txt` - Python dependencies for Functions publish.
- `host.json` - Functions host and base64 queue message configuration.
- `local.settings.json.example` - local development settings template. Do not copy real secrets into source control.

## Build and run locally

Install Python 3.11 and Azure Functions Core Tools v4. On a Windows jump VM, install Core Tools with npm:

```powershell
npm install -g azure-functions-core-tools@4 --unsafe-perm true
```

Create and activate a virtual environment, then install dependencies:

```powershell
cd "<repo>\src\functions\spo-ingest"
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
Copy-Item .\local.settings.json.example .\local.settings.json
# Edit local.settings.json for local identity-based settings.
func start
```

Local execution still uses `DefaultAzureCredential`; sign in with `az login` or run on a VM/host with a managed identity that has the same permissions as the Function App identity.

## Publish

Run from a jump VM or host with network access to the private Function App endpoints:

```powershell
cd "<repo>\src\functions\spo-ingest"
func azure functionapp publish <function-app-name> --python
```

If publishing fails with private endpoint, DNS, or SCM connectivity errors, connect to VPN or publish from the jump VM inside the private network.

## App settings

The live app already has several settings; this function reads all of these through `os.environ`:

| Setting | Required | Purpose |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | Yes in Azure | User-assigned managed identity client ID used by `DefaultAzureCredential`. |
| `AZURE_SEARCH_ENDPOINT` | Yes | Azure AI Search endpoint, for example `https://<search-service-name>.search.windows.net`. |
| `AZURE_SEARCH_INDEX` | Yes | Search index name. Bicep references `rag-lab-docs`, but the live lab index is `ragdocs`; set this to the live index. |
| `DOC_INTELLIGENCE_ENDPOINT` | Yes | Document Intelligence endpoint. |
| `BLOB_STORAGE_ACCOUNT` | Fallback | Storage account name used if `AzureWebJobsStorage__blobServiceUri` is absent. |
| `SPO_SITE_ID` | Yes | Graph site ID used with `/sites/{id}/drive`; the code intentionally does not enumerate `/drives`. |
| `SPO_DRIVE_NAME` | Informational | Documents library name for operator reference. |
| `GRAPH_TENANT_ID` | Informational | Tenant ID for operator reference. |
| `AzureWebJobsStorage__accountName` | Yes | Identity-based Functions storage setting. |
| `AzureWebJobsStorage__queueServiceUri` | Yes | Queue endpoint used by the trigger and queue SDK. |
| `AzureWebJobsStorage__blobServiceUri` | Yes | Blob endpoint for the manifest. |
| `AzureWebJobsStorage__tableServiceUri` | Yes | Identity-based Functions storage setting. |
| `AZURE_FOUNDRY_ENDPOINT` | Yes | Azure OpenAI endpoint, for example `https://<foundry-account-name>.openai.azure.com/`. |
| `EMBEDDING_DEPLOYMENT_NAME` | No | Embedding deployment name; defaults to `text-embedding-3-small`. |
| `INGEST_QUEUE_NAME` | No | Queue name; defaults to `ingest-queue`. |
| `INGEST_MANIFEST_CONTAINER` | No | Manifest blob container; defaults to `rag-content`. |
| `INGEST_MANIFEST_BLOB` | No | Manifest blob path; defaults to `ingest-state/manifest.json`. |

Add the new settings after deployment:

```powershell
az functionapp config appsettings set `
  --resource-group <resource-group-name> `
  --name <function-app-name> `
  --settings `
    AZURE_FOUNDRY_ENDPOINT=https://<foundry-account-name>.openai.azure.com/ `
    EMBEDDING_DEPLOYMENT_NAME=text-embedding-3-small `
    INGEST_QUEUE_NAME=ingest-queue `
    INGEST_MANIFEST_CONTAINER=rag-content `
    INGEST_MANIFEST_BLOB=ingest-state/manifest.json
```

## Triggers

### `ScanSharePoint`

Runs every five minutes on `0 */5 * * * *`. It lists `/sites/{SPO_SITE_ID}/drive/root/children`, filters `.docx` and `.pdf`, compares each `lastModifiedDateTime` with the manifest blob, and enqueues changed files to `ingest-queue` as base64-encoded JSON.

### `ProcessDocument`

Consumes `ingest-queue`, downloads `/sites/{SPO_SITE_ID}/drive/items/{itemId}/content` with `follow_redirects=True`, parses bytes with Document Intelligence `prebuilt-layout` markdown output, chunks on paragraphs, embeds each chunk, and uploads deterministic IDs (`{itemId}-{chunkIndex}`) to Search so re-ingest overwrites cleanly.

## Troubleshooting

- **No files found**: Confirm `SPO_SITE_ID` is the site ID and the managed identity has Graph `Sites.Selected` access to the site. The code uses `/sites/{id}/drive` because `/drives` enumeration can be blocked by Sites.Selected.
- **Graph content downloads return HTML or small payloads**: Check SharePoint permissions and confirm redirects are allowed; the HTTP client sets `follow_redirects=True`.
- **Queue trigger cannot decode messages**: `host.json` sets `extensions.queues.messageEncoding` to `base64`; messages are manually base64-encoded before enqueue.
- **Search upload fails with unknown fields**: The code targets the observed `ragdocs` schema from `scripts\s1-create-index-imds.ps1`: `id`, `sourceDoc`, `sourceUrl`, `chunkIndex`, `title`, `content`, `contentVector`.
- **Publish cannot reach SCM**: The app is private-endpoint only; publish from the jump VM or a VPN-connected machine with private DNS resolution.
- **Authentication errors**: Verify `AZURE_CLIENT_ID` is set to the user-assigned managed identity client ID and that the identity has Graph, Blob/Queue data, Document Intelligence, Azure OpenAI, and Search data-plane permissions.
