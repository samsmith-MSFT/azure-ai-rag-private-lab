#requires -Version 5.1
<#
.SYNOPSIS
  Creates the ragdocs vector + semantic index on Azure AI Search.
.DESCRIPTION
  Designed to run on a VM inside the VNet (Search is PE-only). Uses VM system MI
  via IMDS to acquire a search.azure.com token, then PUTs the index schema.
.PARAMETER SearchService
  AI Search service name (without .search.windows.net). Required.
.PARAMETER IndexName
  Index name to create. Defaults to 'ragdocs'.
.EXAMPLE
  .\create-search-index.ps1 -SearchService srch-myproject -IndexName ragdocs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SearchService,
    [string]$IndexName = 'ragdocs',
    [string]$ApiVersion = '2024-07-01'
)
$ErrorActionPreference = 'Stop'

$searchEndpoint = "https://$SearchService.search.windows.net"

Write-Output "=== Acquiring token via IMDS (VM system MI) ==="
$tokenResp = Invoke-RestMethod -Method GET -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://search.azure.com" -Headers @{ Metadata = "true" } -TimeoutSec 10
$token = $tokenResp.access_token
Write-Output "Token len=$($token.Length)"

Write-Output "=== Resolving Search endpoint via private DNS ==="
$ip = [System.Net.Dns]::GetHostAddresses("$SearchService.search.windows.net") | Select-Object -First 1
Write-Output "$SearchService.search.windows.net -> $ip"

Write-Output "=== Building index schema ==="
$indexSchema = @{
    name = $IndexName
    fields = @(
        @{ name = 'id';           type = 'Edm.String';                 key = $true;  searchable = $false; filterable = $true;  sortable = $true;  facetable = $false; retrievable = $true }
        @{ name = 'sourceDoc';    type = 'Edm.String';                                searchable = $false; filterable = $true;  sortable = $true;  facetable = $true;  retrievable = $true }
        @{ name = 'sourceUrl';    type = 'Edm.String';                                searchable = $false; filterable = $false; sortable = $false; facetable = $false; retrievable = $true }
        @{ name = 'chunkIndex';   type = 'Edm.Int32';                                 searchable = $false; filterable = $true;  sortable = $true;  facetable = $false; retrievable = $true }
        @{ name = 'title';        type = 'Edm.String';                                searchable = $true;  filterable = $true;  sortable = $false; facetable = $false; retrievable = $true; analyzer = 'standard.lucene' }
        @{ name = 'content';      type = 'Edm.String';                                searchable = $true;  filterable = $false; sortable = $false; facetable = $false; retrievable = $true; analyzer = 'standard.lucene' }
        @{
            name = 'contentVector'
            type = 'Collection(Edm.Single)'
            searchable = $true
            retrievable = $true
            dimensions = 1536
            vectorSearchProfile = 'vector-profile-hnsw'
        }
    )
    vectorSearch = @{
        algorithms = @(
            @{
                name = 'hnsw-algorithm'
                kind = 'hnsw'
                hnswParameters = @{ m = 4; efConstruction = 400; efSearch = 500; metric = 'cosine' }
            }
        )
        profiles = @(
            @{ name = 'vector-profile-hnsw'; algorithm = 'hnsw-algorithm' }
        )
    }
    semantic = @{
        defaultConfiguration = 'default-semantic'
        configurations = @(
            @{
                name = 'default-semantic'
                prioritizedFields = @{
                    titleField = @{ fieldName = 'title' }
                    prioritizedContentFields = @(@{ fieldName = 'content' })
                    prioritizedKeywordsFields = @()
                }
            }
        )
    }
}
$body = $indexSchema | ConvertTo-Json -Depth 12

Write-Output "=== PUT index ==="
$url = "$searchEndpoint/indexes/$IndexName" + "?api-version=$ApiVersion"
$headers = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }
try {
    $response = Invoke-RestMethod -Method PUT -Uri $url -Headers $headers -Body $body
    Write-Output "INDEX_CREATED name=$($response.name) fields=$($response.fields.Count) vectorProfile=$($response.vectorSearch.profiles[0].name) semanticConfig=$($response.semantic.configurations[0].name)"
} catch {
    Write-Output "INDEX_FAILED: $($_.Exception.Message)"
    if ($_.ErrorDetails) { Write-Output $_.ErrorDetails.Message }
    exit 1
}

Write-Output "=== List indexes ==="
$listUrl = "$searchEndpoint/indexes?api-version=$ApiVersion&" + '$select=name'
$list = Invoke-RestMethod -Method GET -Uri $listUrl -Headers @{ 'Authorization' = "Bearer $token" }
Write-Output "INDEXES: $($list.value.name -join ', ')"
