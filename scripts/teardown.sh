#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${1:-rg-ailab-rag-westus3}"
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
