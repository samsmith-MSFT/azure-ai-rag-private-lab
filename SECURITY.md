# Security

## Scope

This repository contains a **lab** deployment of a privatized Azure AI RAG architecture. It is intended for learning, demonstration, and proof-of-concept work. **It is not production-ready software.**

The architecture has two documented compromises that are acceptable in a lab but would need additional controls before production use:

1. **AI Foundry account** uses `networkAcls.defaultAction = 'Allow'`. This is required by Foundry Agents Standard today. A restrictive NSG on the agent subnet partially compensates.
2. **Bot Framework connector** is a public, multi-tenant Microsoft-managed service. The Teams channel path traverses it. The compensating control is strict Bot Framework JWT validation on the messaging endpoint, optionally combined with an egress IP allowlist.

A full list of architectural compromises is documented in [README.md](./README.md) under "Privatization Compromises".

## Reporting a vulnerability

If you find a security issue in this repository, please **do not** open a public GitHub issue.

Instead, contact the repository owner directly via the GitHub profile linked in the repository metadata. For broader Microsoft Azure platform vulnerabilities (in the underlying services, not this lab code), report through the [Microsoft Security Response Center](https://msrc.microsoft.com/).

This is a personal lab repository maintained on a best-effort basis. There is no SLA on security response.

## What's in scope

- Bugs in the Bicep templates that materially weaken the security posture documented in the README.
- Insecure defaults in deployment scripts.
- Accidentally committed secrets, tokens, or internal identifiers.

## What's out of scope

- Vulnerabilities in upstream Azure Verified Modules — report those to the [AVM project](https://github.com/Azure/Azure-Verified-Modules).
- Vulnerabilities in Microsoft services themselves (Foundry, AI Search, App Service, etc.) — report through MSRC.
- Issues that only apply when the templates are modified in ways the README does not recommend.

## Hardening reminders for users

If you deploy this lab and intend to take it further than a sandbox:

- Replace the SharePoint client secret with Workload Identity Federation.
- Grant SharePoint app permissions via `Sites.Selected` rather than tenant-wide scopes.
- Restrict the bot's service principal to your NAT Gateway egress IP via Conditional Access.
- Add NSG egress restrictions to the Function subnet — allow only `AzureActiveDirectory` and `Microsoft.Graph` service tags.
- Review SharePoint-side governance before indexing — the bot reflects SharePoint's permission model, not yours.
- Rotate the jump VM admin password regularly, or rely exclusively on Entra ID login.
