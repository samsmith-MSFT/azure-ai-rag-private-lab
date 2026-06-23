#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${1:-rg-ailab-rag-eastus2}"
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
