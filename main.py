"""FastAPI app and all HTTP routes.
"""

import asyncio
import logging
import sys
from contextlib import asynccontextmanager

import asyncpg
from fastapi import Depends, FastAPI, HTTPException, Query, Response, status

import config
import db
from models import (
    AddToLibraryRequest,
    BacklogStats,
    LengthBucketStats,
    LibraryEntryResponse,
    LoginRequest,
    RegisterRequest,
    SearchResult,
    StatsResponse,
    TokenResponse,
    UpdateEntryRequest,
    UpdateProgressRequest,
    UpdateStatusRequest,
    UserResponse,
    WeeklyPages,
)
from models import BUCKET_LABELS, VALID_STATUSES, entry_response
from openlibrary import OpenLibraryError, search_books
from security import create_access_token, current_user_id, hash_password, verify_password

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.connect()
    yield
    await db.disconnect()


app = FastAPI(title="Book Backlog Tracker", version="0.1.0", lifespan=lifespan)


# ops

@app.get("/healthz", tags=["ops"])
async def healthz():
    """Liveness. Returns 200 without touching the database - deliberately.

    This is the endpoint the ALB target group health check hits. If it queried
    Postgres, a slow database would fail health checks across every task, the
    ALB would deregister all of them, and a degraded database would become a
    total outage. Liveness answers "is this process alive", nothing more.
    """
    return {"status": "ok"}


@app.get("/readyz", tags=["ops"])
async def readyz(response: Response):
    """Readiness. Actually checks the database. Never wire this to the ALB."""
    try:
        await db.get_pool().fetchval("SELECT 1")
        return {"status": "ready", "database": "ok"}
    except Exception as exc:  # noqa: BLE001
        response.status_code = 503
        return {"status": "not ready", "database": str(exc)}


# auth

@app.post("/register", response_model=UserResponse, status_code=201, tags=["auth"])
async def register(body: RegisterRequest):
    try:
        async with db.get_pool().acquire() as conn:
            row = await db.create_user(
                conn, str(body.email), hash_password(body.password)
            )
    except asyncpg.UniqueViolationError as exc:
        raise HTTPException(409, "Email already registered") from exc
    return UserResponse(**dict(row))


@app.post("/login", response_model=TokenResponse, tags=["auth"])
async def login(body: LoginRequest):
    async with db.get_pool().acquire() as conn:
        row = await db.get_user_by_email(conn, str(body.email))

    # Identical response whether the email is unknown or the password is
    # wrong, so this can't be used to enumerate registered accounts.
    if row is None or not verify_password(body.password, row["password_hash"]):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "Incorrect email or password"
        )
    return TokenResponse(access_token=create_access_token(row["id"]))


# library

@app.get("/search", response_model=list[SearchResult], tags=["library"])
async def search(q: str = Query(min_length=1, max_length=200), limit: int = 10):
    """Returns candidates rather than auto-picking the top hit.

    Open Library relevance on short queries is poor - searching "dune" often
    surfaces an obscure edition above the Herbert novel.
    """
    try:
        results = await search_books(q, limit=min(limit, 20))
    except OpenLibraryError as exc:
        raise HTTPException(503, "Book search is unavailable") from exc
    return [SearchResult(**r) for r in results]


@app.post("/library", response_model=LibraryEntryResponse, status_code=201,
          tags=["library"])
async def add_to_library(body: AddToLibraryRequest,
                         user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        async with conn.transaction():
            book = await db.upsert_book(
                conn,
                ol_work_key=body.ol_work_key,
                title=body.title or body.ol_work_key,
                authors=body.authors or [],
                first_publish_year=body.first_publish_year,
                page_count=body.page_count,
                cover_id=body.cover_id,
            )
            entry_id = await db.create_entry(conn, user_id, book["id"], body.format)
            if entry_id is None:
                raise HTTPException(409, "Book already in your library")
            await db.record_event(
                conn, entry_id, "status_change",
                from_status=None, to_status="want_to_read",
            )
        row = await db.get_entry(conn, user_id, entry_id)
    return entry_response(row)


@app.get("/library", response_model=list[LibraryEntryResponse], tags=["library"])
async def list_library(
    user_id: int = Depends(current_user_id),
    status_filter: str | None = Query(default=None, alias="status"),
    limit: int = Query(default=50, le=200),
    offset: int = Query(default=0, ge=0),
):
    if status_filter and status_filter not in VALID_STATUSES:
        raise HTTPException(422, "Invalid status filter")
    async with db.get_pool().acquire() as conn:
        rows = await db.list_entries(conn, user_id, status_filter, limit, offset)
    return [entry_response(r) for r in rows]


@app.get("/library/{entry_id}", response_model=LibraryEntryResponse, tags=["library"])
async def get_one(entry_id: int, user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        row = await db.get_entry(conn, user_id, entry_id)
    if row is None:
        raise HTTPException(404, "Entry not found")
    return entry_response(row)


@app.patch("/library/{entry_id}", response_model=LibraryEntryResponse, tags=["library"])
async def update_entry(entry_id: int, body: UpdateEntryRequest,
                       user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        updated = await db.update_entry_fields(
            conn, user_id, entry_id, body.rating, body.format,
            body.page_count_override, body.edition_isbn,
        )
        if updated is None:
            raise HTTPException(404, "Entry not found")
        row = await db.get_entry(conn, user_id, entry_id)
    return entry_response(row)


@app.patch("/library/{entry_id}/status", response_model=LibraryEntryResponse,
           tags=["library"])
async def change_status(entry_id: int, body: UpdateStatusRequest,
                        user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        async with conn.transaction():
            previous = await db.get_current_status(conn, user_id, entry_id)
            if previous is None:
                raise HTTPException(404, "Entry not found")

            await db.update_status(conn, user_id, entry_id, body.status)
            await db.record_event(
                conn, entry_id, "status_change",
                from_status=previous, to_status=body.status,
            )
        row = await db.get_entry(conn, user_id, entry_id)
    return entry_response(row)


@app.patch("/library/{entry_id}/progress", response_model=LibraryEntryResponse,
           tags=["library"])
async def change_progress(entry_id: int, body: UpdateProgressRequest,
                          user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        async with conn.transaction():
            updated = await db.update_progress(conn, user_id, entry_id, body.page)
            if updated is None:
                raise HTTPException(404, "Entry not found")
            await db.record_event(conn, entry_id, "progress", page=body.page)
        row = await db.get_entry(conn, user_id, entry_id)
    return entry_response(row)


@app.delete("/library/{entry_id}", status_code=204, tags=["library"])
async def remove_entry(entry_id: int, user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        deleted = await db.delete_entry(conn, user_id, entry_id)
    if not deleted:
        raise HTTPException(404, "Entry not found")


@app.get("/stats", response_model=StatsResponse, tags=["library"])
async def stats(user_id: int = Depends(current_user_id)):
    async with db.get_pool().acquire() as conn:
        backlog = await db.backlog_stats(conn, user_id, config.PAGES_PER_HOUR)
        by_length = await db.completion_by_length(conn, user_id)
        weekly = await db.weekly_pages(conn, user_id)
        counts = await db.status_counts(conn, user_id)

    return StatsResponse(
        backlog=BacklogStats(
            unread_books=backlog["unread_books"],
            unread_pages=int(backlog["unread_pages"]),
            estimated_hours=float(backlog["estimated_hours"]),
        ),
        by_length=[
            LengthBucketStats(
                label=BUCKET_LABELS.get(r["length_bucket"], "unknown"),
                finished=r["finished"],
                abandoned=r["abandoned"],
                completion_pct=(
                    float(r["completion_pct"])
                    if r["completion_pct"] is not None else None
                ),
            )
            for r in by_length
        ],
        weekly_pages=[
            WeeklyPages(week=r["week"], pages_read=int(r["pages_read"]))
            for r in weekly
        ],
        status_counts={r["status"]: r["n"] for r in counts},
    )

# entrypoint

if __name__ == "__main__":
    if "--migrate" in sys.argv:
        asyncio.run(db.apply_schema())
        print("schema applied")
    else:
        import uvicorn

        uvicorn.run(app, host="0.0.0.0", port=8080)
