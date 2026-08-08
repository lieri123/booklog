"""Open Library client.
"""

import logging

import httpx

import config

log = logging.getLogger(__name__)

SEARCH_FIELDS = (
    "key,title,author_name,first_publish_year,"
    "number_of_pages_median,cover_i,subject,edition_count"
)


class OpenLibraryError(RuntimeError):
    pass


def work_key_from_path(raw: str | None) -> str | None:
    """Open Library returns '/works/OL27448W'; we store 'OL27448W'.

    Normalise at the boundary or you end up with both forms in the database
    and a UNIQUE constraint that quietly stops working.
    """
    if not raw:
        return None
    return raw.rstrip("/").split("/")[-1] or None


def cover_url(cover_id: int | None, size: str = "M") -> str | None:
    """Note ?default=false.

    Without it, a missing cover returns a blank placeholder JPEG with HTTP
    200. The phase 5 worker would cache thousands of identical blank images
    to S3 and nobody would notice for weeks.
    """
    if cover_id is None:
        return None
    return f"{config.OL_COVERS}/b/id/{cover_id}-{size}.jpg?default=false"


def _parse_doc(doc: dict) -> dict | None:
    key = work_key_from_path(doc.get("key"))
    title = doc.get("title")
    if not key or not title:
        return None
    cover_id = doc.get("cover_i")
    return {
        "ol_work_key": key,
        "title": title,
        "authors": doc.get("author_name") or [],
        "first_publish_year": doc.get("first_publish_year"),
        "page_count": doc.get("number_of_pages_median"),
        "cover_id": cover_id,
        "cover_url": cover_url(cover_id),
        "edition_count": doc.get("edition_count"),
    }


async def search_books(query: str, limit: int = 10) -> list[dict]:
    try:
        async with httpx.AsyncClient(timeout=config.OL_TIMEOUT) as client:
            resp = await client.get(
                f"{config.OL_BASE}/search.json",
                params={"q": query, "fields": SEARCH_FIELDS, "limit": limit},
                headers={"User-Agent": config.USER_AGENT},
            )
            resp.raise_for_status()
            payload = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("open library search failed: %s", exc)
        raise OpenLibraryError(str(exc)) from exc

    docs = payload.get("docs") or []
    return [p for doc in docs if (p := _parse_doc(doc)) is not None]
