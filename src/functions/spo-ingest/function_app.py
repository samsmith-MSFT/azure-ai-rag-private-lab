"""Azure Functions app for SharePoint-to-Azure AI Search ingestion.

The app uses managed identity for every Azure and Microsoft Graph call. It scans
SharePoint on a timer, enqueues changed PDF/DOCX files, parses each document with
Document Intelligence Layout v4.0, embeds chunks with Azure OpenAI in Foundry, and
uploads deterministic chunk documents into Azure AI Search.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, Sequence

import azure.functions as func
import httpx
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import AnalyzeDocumentRequest
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.storage.blob import BlobServiceClient
from azure.storage.queue import QueueClient
from openai import AzureOpenAI

try:
    import tiktoken
except ImportError:  # pragma: no cover - requirements includes tiktoken; fallback is defensive.
    tiktoken = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

app = func.FunctionApp()

GRAPH_BASE_URL = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"
COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"
DOC_INTEL_MODEL_ID = "prebuilt-layout"
DOC_INTEL_OUTPUT_FORMAT = "markdown"
EMBEDDING_DIMENSIONS = 1536
MAX_CHUNK_TOKENS = 800
CHUNK_OVERLAP_TOKENS = 80
SUPPORTED_EXTENSIONS = (".docx", ".pdf")

# ragdocs schema observed in scripts\s1-create-index-imds.ps1:
# id (key Edm.String), sourceDoc (Edm.String), sourceUrl (Edm.String),
# chunkIndex (Edm.Int32), title (Edm.String), content (Edm.String),
# contentVector (Collection(Edm.Single), dimensions=1536).

QUEUE_NAME = os.getenv("INGEST_QUEUE_NAME", "ingest-queue")
MANIFEST_CONTAINER = os.getenv("INGEST_MANIFEST_CONTAINER", "rag-content")
MANIFEST_BLOB = os.getenv("INGEST_MANIFEST_BLOB", "ingest-state/manifest.json")
EMBEDDING_DEPLOYMENT_NAME = os.getenv("EMBEDDING_DEPLOYMENT_NAME", "text-embedding-3-small")

credential = DefaultAzureCredential()
_token_provider = get_bearer_token_provider(credential, COGNITIVE_SERVICES_SCOPE)

_search_client: SearchClient | None = None
_doc_intel_client: DocumentIntelligenceClient | None = None
_blob_service_client: BlobServiceClient | None = None
_queue_client: QueueClient | None = None
_openai_client: AzureOpenAI | None = None
_http_client: httpx.Client | None = None
_encoding: Any | None = None


def _required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required app setting: {name}")
    return value


def _get_http_client() -> httpx.Client:
    global _http_client
    if _http_client is None:
        _http_client = httpx.Client(timeout=httpx.Timeout(180.0), follow_redirects=True)
    return _http_client


def _get_search_client() -> SearchClient:
    global _search_client
    if _search_client is None:
        _search_client = SearchClient(
            endpoint=_required_env("AZURE_SEARCH_ENDPOINT"),
            index_name=_required_env("AZURE_SEARCH_INDEX"),
            credential=credential,
        )
    return _search_client


def _get_doc_intel_client() -> DocumentIntelligenceClient:
    global _doc_intel_client
    if _doc_intel_client is None:
        _doc_intel_client = DocumentIntelligenceClient(
            endpoint=_required_env("DOC_INTELLIGENCE_ENDPOINT"),
            credential=credential,
        )
    return _doc_intel_client


def _get_blob_service_client() -> BlobServiceClient:
    global _blob_service_client
    if _blob_service_client is None:
        blob_service_uri = os.getenv("AzureWebJobsStorage__blobServiceUri")
        if blob_service_uri:
            account_url = blob_service_uri
        else:
            account_name = os.getenv("BLOB_STORAGE_ACCOUNT") or _required_env("AzureWebJobsStorage__accountName")
            account_url = f"https://{account_name}.blob.core.windows.net"
        _blob_service_client = BlobServiceClient(account_url=account_url, credential=credential)
    return _blob_service_client


def _get_queue_client() -> QueueClient:
    global _queue_client
    if _queue_client is None:
        _queue_client = QueueClient(
            account_url=_required_env("AzureWebJobsStorage__queueServiceUri"),
            queue_name=QUEUE_NAME,
            credential=credential,
        )
    return _queue_client


def _get_openai_client() -> AzureOpenAI:
    global _openai_client
    if _openai_client is None:
        _openai_client = AzureOpenAI(
            azure_endpoint=_required_env("AZURE_FOUNDRY_ENDPOINT"),
            azure_ad_token_provider=_token_provider,
            api_version="2024-10-21",
        )
    return _openai_client


def _get_encoding() -> Any | None:
    global _encoding
    if _encoding is None and tiktoken is not None:
        _encoding = tiktoken.get_encoding("cl100k_base")
    return _encoding


def _token_count(text: str) -> int:
    encoding = _get_encoding()
    if encoding is not None:
        return len(encoding.encode(text))
    return max(1, int(len(text) / 4))


def _overlap_suffix(text: str, overlap_tokens: int = CHUNK_OVERLAP_TOKENS) -> str:
    encoding = _get_encoding()
    if encoding is not None:
        tokens = encoding.encode(text)
        if len(tokens) <= overlap_tokens:
            return text.strip()
        return encoding.decode(tokens[-overlap_tokens:]).strip()
    return text[-overlap_tokens * 4 :].strip()


def _parse_datetime(value: str | None) -> datetime:
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    normalized = value.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _graph_headers() -> dict[str, str]:
    logger.info("Requesting Microsoft Graph access token")
    try:
        token = credential.get_token(GRAPH_SCOPE).token
        logger.info("Acquired Microsoft Graph access token")
        return {"Authorization": f"Bearer {token}"}
    except Exception:
        logger.exception("Failed to acquire Microsoft Graph token")
        raise


def _graph_get_json(url_or_path: str) -> dict[str, Any]:
    url = url_or_path if url_or_path.startswith("https://") else f"{GRAPH_BASE_URL}{url_or_path}"
    logger.info("Calling Microsoft Graph JSON endpoint: %s", url)
    try:
        response = _get_http_client().get(url, headers=_graph_headers())
        response.raise_for_status()
        logger.info("Microsoft Graph JSON call succeeded: %s status=%d", url, response.status_code)
        return response.json()
    except Exception:
        logger.exception("Microsoft Graph JSON call failed: %s", url)
        raise


def _graph_get_bytes(path: str) -> bytes:
    url = f"{GRAPH_BASE_URL}{path}"
    logger.info("Calling Microsoft Graph content endpoint: %s", url)
    try:
        response = _get_http_client().get(url, headers=_graph_headers())
        response.raise_for_status()
        logger.info("Microsoft Graph content call succeeded: %s status=%d bytes=%d", url, response.status_code, len(response.content))
        if len(response.content) < 200 or response.content[:1] == b"<":
            logger.warning("Suspiciously small or HTML-like content returned for %s", path)
        return response.content
    except Exception:
        logger.exception("Microsoft Graph content call failed: %s", url)
        raise


def _list_sharepoint_documents() -> list[dict[str, Any]]:
    site_id = _required_env("SPO_SITE_ID")
    path = f"/sites/{site_id}/drive/root/children"
    documents: list[dict[str, Any]] = []
    logger.info("Listing SharePoint drive root children for site %s", site_id)
    try:
        while path:
            page = _graph_get_json(path)
            for item in page.get("value", []):
                name = str(item.get("name", ""))
                if item.get("file") and name.lower().endswith(SUPPORTED_EXTENSIONS):
                    documents.append(item)
            path = page.get("@odata.nextLink", "")
        logger.info("Found %d supported SharePoint documents", len(documents))
        return documents
    except Exception:
        logger.exception("Failed to list SharePoint documents")
        raise


def _load_manifest() -> dict[str, str]:
    blob_client = _get_blob_service_client().get_blob_client(MANIFEST_CONTAINER, MANIFEST_BLOB)
    logger.info("Downloading manifest blob: %s/%s", MANIFEST_CONTAINER, MANIFEST_BLOB)
    try:
        data = blob_client.download_blob().readall()
        manifest = json.loads(data.decode("utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("Manifest JSON must be an object keyed by SharePoint item ID")
        logger.info("Loaded manifest with %d entries", len(manifest))
        return {str(k): str(v) for k, v in manifest.items()}
    except ResourceNotFoundError:
        logger.info("Manifest blob does not exist yet; starting with an empty manifest")
        return {}
    except Exception:
        logger.exception("Failed to load manifest blob")
        raise


def _save_manifest(manifest: Mapping[str, str]) -> None:
    blob_client = _get_blob_service_client().get_blob_client(MANIFEST_CONTAINER, MANIFEST_BLOB)
    payload = json.dumps(dict(sorted(manifest.items())), indent=2).encode("utf-8")
    logger.info("Uploading manifest blob: %s/%s (%d entries)", MANIFEST_CONTAINER, MANIFEST_BLOB, len(manifest))
    try:
        blob_client.upload_blob(payload, overwrite=True, content_type="application/json")
        logger.info("Uploaded manifest blob successfully: %s/%s", MANIFEST_CONTAINER, MANIFEST_BLOB)
    except Exception:
        logger.exception("Failed to upload manifest blob")
        raise


def _enqueue_document(item: Mapping[str, Any]) -> None:
    payload = {
        "itemId": item["id"],
        "name": item["name"],
        "lastModifiedDateTime": item.get("lastModifiedDateTime", ""),
    }
    encoded_message = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    logger.info("Enqueuing document %s (%s) to %s", payload["name"], payload["itemId"], QUEUE_NAME)
    try:
        _get_queue_client().send_message(encoded_message)
        logger.info("Enqueued document %s successfully", payload["itemId"])
    except Exception:
        logger.exception("Failed to enqueue document %s", payload["itemId"])
        raise


def _decode_queue_message(msg: func.QueueMessage) -> dict[str, Any]:
    raw = msg.get_body()
    logger.info("Decoding queue message with %d bytes", len(raw))
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        return json.loads(base64.b64decode(raw).decode("utf-8"))


def _extract_markdown(filename: str, data: bytes) -> str:
    logger.info("Calling Document Intelligence Layout for %s (%d bytes)", filename, len(data))
    try:
        poller = _get_doc_intel_client().begin_analyze_document(
            DOC_INTEL_MODEL_ID,
            AnalyzeDocumentRequest(bytes_source=data),
            output_content_format=DOC_INTEL_OUTPUT_FORMAT,
        )
        result = poller.result()
        content = result.content or ""
        logger.info("Document Intelligence returned %d markdown characters for %s", len(content), filename)
        return content
    except Exception:
        logger.exception("Document Intelligence extraction failed for %s", filename)
        raise


def _split_long_paragraph(paragraph: str, max_tokens: int = MAX_CHUNK_TOKENS) -> Iterable[str]:
    if _token_count(paragraph) <= max_tokens:
        yield paragraph
        return

    words = paragraph.split()
    current: list[str] = []
    for word in words:
        candidate = " ".join([*current, word])
        if current and _token_count(candidate) > max_tokens:
            chunk = " ".join(current).strip()
            yield chunk
            overlap = _overlap_suffix(chunk).split()
            current = [*overlap, word]
        else:
            current.append(word)
    if current:
        yield " ".join(current).strip()


def chunk_markdown(markdown: str) -> list[str]:
    paragraphs = [p.strip() for p in markdown.split("\n\n") if p.strip()]
    expanded: list[str] = []
    for paragraph in paragraphs:
        expanded.extend(_split_long_paragraph(paragraph))

    chunks: list[str] = []
    current_parts: list[str] = []
    for paragraph in expanded:
        candidate_parts = [*current_parts, paragraph]
        candidate = "\n\n".join(candidate_parts).strip()
        if current_parts and _token_count(candidate) > MAX_CHUNK_TOKENS:
            chunk = "\n\n".join(current_parts).strip()
            chunks.append(chunk)
            overlap = _overlap_suffix(chunk)
            current_parts = [overlap, paragraph] if overlap else [paragraph]
        else:
            current_parts = candidate_parts
    if current_parts:
        chunks.append("\n\n".join(current_parts).strip())

    logger.info("Chunked markdown into %d chunks", len(chunks))
    return chunks


def _embed_chunk(text: str, chunk_index: int) -> list[float]:
    logger.info("Calling Azure OpenAI embeddings for chunk %d", chunk_index)
    try:
        response = _get_openai_client().embeddings.create(
            model=EMBEDDING_DEPLOYMENT_NAME,
            input=text,
        )
        vector = response.data[0].embedding
        if len(vector) != EMBEDDING_DIMENSIONS:
            logger.warning("Embedding dimension mismatch for chunk %d: expected %d, got %d", chunk_index, EMBEDDING_DIMENSIONS, len(vector))
        logger.info("Azure OpenAI embeddings call succeeded for chunk %d with %d dimensions", chunk_index, len(vector))
        return vector
    except Exception:
        logger.exception("Azure OpenAI embedding call failed for chunk %d", chunk_index)
        raise


def _build_search_documents(
    item_id: str,
    name: str,
    chunks: Sequence[str],
    last_modified: str,
) -> list[dict[str, Any]]:
    source_url = f"graph://sites/{_required_env('SPO_SITE_ID')}/drive/items/{item_id}"
    title = name.rsplit(".", 1)[0]
    docs: list[dict[str, Any]] = []
    for chunk_index, chunk_text in enumerate(chunks):
        vector = _embed_chunk(chunk_text, chunk_index)
        docs.append(
            {
                "id": f"{item_id}-{chunk_index}",
                "sourceDoc": name,
                "sourceUrl": source_url,
                "chunkIndex": chunk_index,
                "title": title,
                "content": chunk_text,
                "contentVector": vector,
            }
        )
    logger.info("Built %d Search documents for %s; lastModified=%s", len(docs), name, last_modified)
    return docs


def _upload_search_documents(documents: Sequence[dict[str, Any]], name: str) -> int:
    if not documents:
        logger.info("No Search documents to upload for %s", name)
        return 0
    logger.info("Uploading %d documents to Azure AI Search for %s", len(documents), name)
    try:
        results = _get_search_client().upload_documents(documents=list(documents))
        succeeded = sum(1 for result in results if result.succeeded)
        if succeeded != len(documents):
            failures = [result for result in results if not result.succeeded]
            raise RuntimeError(f"Azure AI Search upload had {len(failures)} failed documents for {name}: {failures}")
        logger.info("Uploaded %d/%d documents to Azure AI Search for %s", succeeded, len(documents), name)
        return succeeded
    except Exception:
        logger.exception("Azure AI Search upload failed for %s", name)
        raise


@app.function_name(name="ScanSharePoint")
@app.timer_trigger(schedule="0 */5 * * * *", arg_name="timer", run_on_startup=False, use_monitor=True)
def scan_sharepoint(timer: func.TimerRequest) -> None:
    """Scan SharePoint and enqueue changed supported files.

    Input: Azure Functions TimerRequest fired every five minutes.
    Side effects: reads the manifest blob, lists `/sites/{SPO_SITE_ID}/drive/root/children`,
    writes base64-encoded JSON messages to `INGEST_QUEUE_NAME`, and overwrites the manifest.
    Invariant: only DOCX/PDF files with newer `lastModifiedDateTime` than the manifest are enqueued.
    """
    logger.info("ScanSharePoint started; past_due=%s", timer.past_due)
    try:
        manifest = _load_manifest()
        next_manifest = dict(manifest)
        enqueued = 0

        for item in _list_sharepoint_documents():
            item_id = str(item["id"])
            name = str(item["name"])
            last_modified = str(item.get("lastModifiedDateTime", ""))
            previous = manifest.get(item_id)
            next_manifest[item_id] = last_modified

            if previous is None or _parse_datetime(last_modified) > _parse_datetime(previous):
                logger.info("Document changed or new: %s (%s > %s)", name, last_modified, previous)
                _enqueue_document(item)
                enqueued += 1
            else:
                logger.info("Document unchanged: %s (%s)", name, last_modified)

        _save_manifest(next_manifest)
        logger.info("ScanSharePoint completed; enqueued=%d manifest_entries=%d", enqueued, len(next_manifest))
    except Exception:
        logger.exception("ScanSharePoint failed")
        raise


@app.function_name(name="ProcessDocument")
@app.queue_trigger(arg_name="msg", queue_name=QUEUE_NAME, connection="AzureWebJobsStorage")
def process_document(msg: func.QueueMessage) -> None:
    """Process one SharePoint document queue message into Azure AI Search chunks.

    Input: base64-decoded JSON containing `itemId`, `name`, and `lastModifiedDateTime`.
    Side effects: downloads the file through Microsoft Graph, parses with Document Intelligence,
    creates Foundry embeddings, and uploads deterministic chunk documents to Azure AI Search.
    Invariant: document IDs are `{itemId}-{chunkIndex}`, so re-processing overwrites idempotently.
    """
    logger.info("ProcessDocument started; message_id=%s", msg.id)
    try:
        payload = _decode_queue_message(msg)
        item_id = str(payload["itemId"])
        name = str(payload["name"])
        last_modified = str(payload.get("lastModifiedDateTime", ""))

        bytes_data = _graph_get_bytes(f"/sites/{_required_env('SPO_SITE_ID')}/drive/items/{item_id}/content")
        markdown = _extract_markdown(name, bytes_data)
        chunks = chunk_markdown(markdown)
        documents = _build_search_documents(item_id, name, chunks, last_modified)
        uploaded = _upload_search_documents(documents, name)
        logger.info("ProcessDocument completed for %s; chunks=%d uploaded=%d", name, len(chunks), uploaded)
    except Exception:
        logger.exception("ProcessDocument failed")
        raise

