# Azure AI RAG - Private Lab

This repo deploys a private Azure AI retrieval-augmented generation lab for a Teams bot, Foundry agents, AI Search, SharePoint ingestion, and observability. The architecture inherits from the Microsoft baseline private Foundry chat pattern and adapts it for a lightweight lab deployment.

## Contents

- [Architecture](#architecture)
- [Reference Architecture](#reference-architecture)
- [Networking](#networking)
- [Identity & RBAC](#identity--rbac)
- [Privatization Compromises](#privatization-compromises)
- [Prerequisites](#prerequisites)
- [Authentication](#authentication)
- [Deploy](#deploy)
- [Validation](#validation)
- [Day-2 Operations](#day-2-operations)
- [Observability](#observability)
- [Teardown](#teardown)
- [References](#references)

## Architecture

▶ **[Open the interactive architecture diagram](https://samsmith-msft.github.io/azure-ai-rag-private-lab/diagram/architecture.html)**

[![Architecture](diagram/architecture.png)](https://samsmith-msft.github.io/azure-ai-rag-private-lab/diagram/architecture.html)

> The PNG is a static preview. Click the PNG or the link above for the interactive version. The source is committed at `diagram/architecture.html`. GitHub READMEs cannot run JavaScript, so the interactive diagram is hosted through GitHub Pages.

## Reference Architecture

![Baseline Microsoft Foundry Chat Reference Architecture - Microsoft's canonical fully-private RAG pattern. This deployment adapts it with six documented changes listed below.](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/_images/baseline-microsoft-foundry.svg)

Source: [Baseline Microsoft Foundry Chat reference architecture](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat)

This lab adapts the baseline pattern in six ways:

1. NAT Gateway instead of Azure Firewall.
2. Bot Service for Teams instead of an App Service web UI.
3. Functions ingestion from SharePoint plus Document Intelligence.
4. Cross-region AI Search private endpoint, with Search in Central US and the private endpoint in the East US 2 hub VNet.
5. Azure Monitor Private Link Scope with `PrivateOnly` for monitoring.
6. App Configuration added for centralized settings.

## Networking

### Subnet plan

| Subnet | Prefix | Purpose |
| --- | --- | --- |
| `snet-compute` | `10.0.1.0/24` | App Service and Functions VNet integration with NAT egress. |
| `snet-pe` | `10.0.2.0/24` | Private endpoints for platform services. |
| `snet-foundry-agent` | `10.0.3.0/27` | Foundry Agent Service capability host subnet. |
| `snet-egress` | `10.0.4.0/26` | Reserved outbound subnet with NAT Gateway. |
| `AzureBastionSubnet` | `10.0.5.0/26` | Azure Bastion operator access. |
| `snet-jump` | `10.0.6.0/27` | Jump VM for portal and private endpoint validation. |

### Private DNS zones

| Zone | Service |
| --- | --- |
| `privatelink.services.ai.azure.com` | Foundry account and project endpoints |
| `privatelink.openai.azure.com` | Azure OpenAI model endpoints |
| `privatelink.cognitiveservices.azure.com` | Cognitive services endpoints |
| `privatelink.search.windows.net` | AI Search private endpoint |
| `privatelink.documents.azure.com` | Cosmos DB |
| `privatelink.blob.core.windows.net` | Storage blob endpoints |
| `privatelink.vaultcore.azure.net` | Key Vault |
| `privatelink.azconfig.io` | App Configuration |
| `privatelink.azurewebsites.net` | App Service and Functions |
| `privatelink.monitor.azure.com` | Azure Monitor |
| `privatelink.ods.opinsights.azure.com` | Log Analytics ingestion |
| `privatelink.oms.opinsights.azure.com` | Log Analytics query |
| `privatelink.agentsvc.azure-automation.net` | Azure Automation agent service telemetry |

![Foundry Agent Service network flows - inbound user, App Service to PaaS private endpoints, agent egress through NAT Gateway in this deployment or Azure Firewall in the baseline.](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/_images/baseline-microsoft-foundry-network-flow.svg)

Source: [Foundry Agent Service networking](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat#networking)

## Identity & RBAC

| Managed identity | Assigned to | Main responsibilities |
| --- | --- | --- |
| `uami-bot` | Bot app | Call Foundry project, read configuration, and access required secrets. |
| `uami-ingestion` | Function app | Read SharePoint content through Graph, process documents, write blobs, and update AI Search. |
| `uami-foundry` | Foundry resources | Operate Foundry resources that require managed identity access. |

RBAC uses managed identities instead of shared keys. Storage has shared key access disabled. Key Vault, Storage, Cosmos DB, Document Intelligence, AI Search, App Configuration, and Foundry access are granted through Azure RBAC roles such as Key Vault Secrets User, Storage Blob Data Contributor, Search Index Data Contributor, Search Service Contributor, App Configuration Data Reader, and Cognitive Services User.

## Privatization Compromises

- Foundry account `networkAcls.defaultAction = 'Allow'` is required by Agents Standard. The compensating control is a restrictive NSG on the agent subnet.
- Bot Service Teams channel relies on the public Bot Framework connector. This accepted exposure is limited to the Teams channel path.
- SharePoint Online has no Private Link support for this workflow. Ingestion egress goes through NAT Gateway only.
- NAT Gateway is simpler and lower cost than Azure Firewall, but it does not provide layer 7 inspection or centralized allow-list enforcement.

## Prerequisites

- Azure subscription with permissions to create resource groups, private endpoints, managed identities, role assignments, and AI services.
- GitHub CLI (`gh`) for repository operations.
- Azure CLI (`az`) and Bicep CLI.
- GitHub Codespaces can be used instead of a local workstation because the dev container installs Azure CLI, Bicep, and GitHub CLI.

## Authentication

```bash
az login --tenant <your-tenant-id>
az account set --subscription <your-subscription-id>
az account show --query "{tenantId:tenantId, subscriptionId:id, name:name}" --output table
```

## Deploy

### Run in GitHub Codespaces

1. Open the repo in Codespaces.
2. Authenticate with device code:

```bash
az login --use-device-code --tenant <your-tenant-id>
az account set --subscription <your-subscription-id>
```

3. Review and deploy:

```bash
az deployment sub what-if   --location eastus2   --template-file infra/main.bicep   --parameters infra/main.bicepparam

az deployment sub create   --location eastus2   --template-file infra/main.bicep   --parameters infra/main.bicepparam
```

### Local bash

```bash
git clone https://github.com/samsmith-MSFT/azure-ai-rag-private-lab.git
cd azure-ai-rag-private-lab
az login --tenant <your-tenant-id>
az account set --subscription <your-subscription-id>
```

Run the what-if gate first:

```bash
az deployment sub what-if   --location eastus2   --template-file infra/main.bicep   --parameters infra/main.bicepparam
```

If the what-if output is expected, deploy:

```bash
az deployment sub create   --location eastus2   --template-file infra/main.bicep   --parameters infra/main.bicepparam
```

## Validation

- From a VM in the VNet, run `nslookup <service-name>.search.windows.net` and confirm it resolves to a private IP.
- Run `az resource list --resource-group rg-ailab-rag-eastus2 --query "[].{name:name,type:type}" --output table`.
- Check that platform resources have `publicNetworkAccess` disabled where supported.
- Confirm Storage has shared key access disabled.
- Confirm AI Search is in `centralus` and its private endpoint is in the East US 2 hub VNet.
- Confirm AMPLS ingestion and query access modes are `PrivateOnly`.
- Confirm the Function app can reach SharePoint through NAT Gateway and can write to AI Search.

## Day-2 Operations

![Day-2 operator access to the Foundry portal: Bastion to jump VM to Foundry private endpoint.](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/_images/baseline-microsoft-foundry-portal-access.svg)

Source: [Ingress to Foundry](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat#ingress-to-foundry)

Use Azure Bastion to connect to the jump VM, then access the Foundry portal over the private endpoint path. Create the Foundry agent and capability hosts after deployment if they were not fully created by the infrastructure module. Update the bot application setting `AGENT_ID` with the created Foundry agent ID.

Register the Teams channel in Azure Bot Service after deployment. Use the placeholder `botMsaAppId` value in `infra/main.bicepparam` for the application/client ID created for the bot.

Grant SharePoint `Sites.Selected` permissions with PnP PowerShell from an operator workstation:

```powershell
Connect-PnPOnline -Url "https://<your-tenant>.sharepoint.com/sites/<your-site>" -Interactive
Grant-PnPAzureADAppSitePermission -AppId "<function-app-managed-identity-client-id>" -DisplayName "RAG ingestion" -Site "https://<your-tenant>.sharepoint.com/sites/<your-site>" -Permissions Read
```

## Observability

![Azure Monitor Private Link Scope: ingestion plus query both PrivateOnly. All telemetry on Azure backbone.](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/media/private-link-security/private-link-basic-topology.png)

Source: [Azure Monitor Private Link security](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/private-link-security)

The deployment creates Log Analytics, Application Insights, and AMPLS. Ingestion and query public access are disabled where supported, and AMPLS is configured with `PrivateOnly` modes so telemetry flows over Azure private networking.

## Teardown

```bash
az group delete --name rg-ailab-rag-eastus2 --yes --no-wait
```

Key Vault uses purge protection. If you need to reuse the same vault name, purge the deleted vault after the retention period and only when your governance policy allows it.

## References

- [Baseline Microsoft Foundry Chat reference architecture](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat)
- [Foundry Agent Service networking](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat#networking)
- [Ingress to Foundry](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-chat#ingress-to-foundry)
- [Azure Monitor Private Link security](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/private-link-security)
