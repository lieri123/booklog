"""Request and response models, plus the row-to-response mapper."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field

from openlibrary import cover_url

ReadingStatus = Literal["want_to_read", "reading", "finished", "abandoned"]
BookFormat = Literal["paper", "ebook", "audio"]
VALID_STATUSES = {"want_to_read", "reading", "finished", "abandoned"}

BUCKET_LABELS = {
    1: "0-200 pages",
    2: "200-400 pages",
    3: "400-600 pages",
    4: "600-800 pages",
    5: "800-1000 pages",
    6: "1000+ pages",
}


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=200)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserResponse(BaseModel):
    id: int
    email: str
    created_at: datetime


class BookResponse(BaseModel):
    id: int
    ol_work_key: str
    title: str
    authors: list[str]
    first_publish_year: int | None
    page_count: int | None
    cover_url: str | None
    enrichment_status: str


class AddToLibraryRequest(BaseModel):
    """Only the work key is required. Title and authors are accepted as a hint
    from the search result so the entry looks right immediately, but the
    enrichment worker is the source of truth."""

    ol_work_key: str = Field(min_length=1, max_length=64)
    title: str | None = None
    authors: list[str] | None = None
    first_publish_year: int | None = None
    page_count: int | None = Field(default=None, gt=0)
    cover_id: int | None = None
    format: BookFormat | None = None


class UpdateEntryRequest(BaseModel):
    rating: int | None = Field(default=None, ge=1, le=5)
    format: BookFormat | None = None
    page_count_override: int | None = Field(default=None, gt=0)
    edition_isbn: str | None = Field(default=None, max_length=20)


class UpdateStatusRequest(BaseModel):
    status: ReadingStatus


class UpdateProgressRequest(BaseModel):
    page: int = Field(ge=0)


class LibraryEntryResponse(BaseModel):
    id: int
    status: ReadingStatus
    rating: int | None
    current_page: int
    effective_page_count: int | None
    percent_complete: float | None
    format: BookFormat | None
    edition_isbn: str | None
    started_at: datetime | None
    finished_at: datetime | None
    created_at: datetime
    book: BookResponse


class SearchResult(BaseModel):
    ol_work_key: str
    title: str
    authors: list[str]
    first_publish_year: int | None
    page_count: int | None
    cover_id: int | None
    cover_url: str | None
    edition_count: int | None


class BacklogStats(BaseModel):
    unread_books: int
    unread_pages: int
    estimated_hours: float


class LengthBucketStats(BaseModel):
    label: str
    finished: int
    abandoned: int
    completion_pct: float | None


class WeeklyPages(BaseModel):
    week: datetime
    pages_read: int


class StatsResponse(BaseModel):
    backlog: BacklogStats
    by_length: list[LengthBucketStats]
    weekly_pages: list[WeeklyPages]
    status_counts: dict[str, int]


def entry_response(row) -> LibraryEntryResponse:
    """Map a joined library_entries + books row to the API shape.

    The user's own edition (page_count_override) wins over the work-level
    median page count from Open Library.
    """
    effective = row["page_count_override"] or row["page_count"]
    pct = None
    if effective and effective > 0:
        pct = round(min(row["current_page"] / effective * 100, 100.0), 1)

    return LibraryEntryResponse(
        id=row["id"],
        status=row["status"],
        rating=row["rating"],
        current_page=row["current_page"],
        effective_page_count=effective,
        percent_complete=pct,
        format=row["format"],
        edition_isbn=row["edition_isbn"],
        started_at=row["started_at"],
        finished_at=row["finished_at"],
        created_at=row["created_at"],
        book=BookResponse(
            id=row["book_id"],
            ol_work_key=row["ol_work_key"],
            title=row["title"],
            authors=list(row["authors"]),
            first_publish_year=row["first_publish_year"],
            page_count=row["page_count"],
            cover_url=cover_url(row["cover_id"]),
            enrichment_status=row["enrichment_status"],
        ),
    )
