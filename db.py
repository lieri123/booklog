"""Connection pool, schema, and every SQL statement in the app.
"""

import asyncpg

import config

_pool: asyncpg.Pool | None = None


# pool lifecycle

async def connect() -> asyncpg.Pool:
    global _pool
    _pool = await asyncpg.create_pool(
        dsn=config.DATABASE_URL,
        min_size=config.POOL_MIN_SIZE,
        max_size=config.POOL_MAX_SIZE,
        command_timeout=10,
    )
    return _pool


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("Database pool not initialised")
    return _pool


# schema

SCHEMA = """
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL PRIMARY KEY,
    email         CITEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS books (
    id                  BIGSERIAL PRIMARY KEY,
    ol_work_key         TEXT UNIQUE NOT NULL,
    title               TEXT NOT NULL,
    authors             TEXT[] NOT NULL DEFAULT '{}',
    first_publish_year  INT,
    page_count          INT,
    cover_id            INT,
    cover_s3_key        TEXT,
    subjects            TEXT[] NOT NULL DEFAULT '{}',
    enrichment_status   TEXT NOT NULL DEFAULT 'pending'
                        CHECK (enrichment_status IN ('pending','ok','failed')),
    enriched_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$ BEGIN
    CREATE TYPE reading_status AS ENUM
        ('want_to_read','reading','finished','abandoned');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS library_entries (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    book_id             BIGINT NOT NULL REFERENCES books(id),
    status              reading_status NOT NULL DEFAULT 'want_to_read',
    rating              SMALLINT CHECK (rating BETWEEN 1 AND 5),
    current_page        INT NOT NULL DEFAULT 0 CHECK (current_page >= 0),
    page_count_override INT CHECK (page_count_override > 0),
    edition_isbn        TEXT,
    format              TEXT CHECK (format IN ('paper','ebook','audio')),
    started_at          TIMESTAMPTZ,
    finished_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, book_id)
);

CREATE INDEX IF NOT EXISTS idx_library_entries_user_status
    ON library_entries (user_id, status);
CREATE INDEX IF NOT EXISTS idx_library_entries_user_created
    ON library_entries (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS reading_events (
    id               BIGSERIAL PRIMARY KEY,
    library_entry_id BIGINT NOT NULL REFERENCES library_entries(id) ON DELETE CASCADE,
    event_type       TEXT NOT NULL CHECK (event_type IN ('status_change','progress')),
    from_status      reading_status,
    to_status        reading_status,
    page             INT CHECK (page >= 0),
    occurred_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reading_events_entry_time
    ON reading_events (library_entry_id, occurred_at);
"""


async def apply_schema() -> None:
    conn = await asyncpg.connect(config.DATABASE_URL)
    await conn.execute(SCHEMA)
    await conn.close()

# users

async def create_user(conn, email: str, password_hash: str):
    return await conn.fetchrow(
        """
        INSERT INTO users (email, password_hash)
        VALUES ($1, $2)
        RETURNING id, email, created_at
        """,
        email,
        password_hash,
    )


async def get_user_by_email(conn, email: str):
    return await conn.fetchrow(
        "SELECT id, email, password_hash, created_at FROM users WHERE email = $1",
        email,
    )

# books and entries

ENTRY_SELECT = """
    SELECT le.id, le.status, le.rating, le.current_page,
           le.page_count_override, le.edition_isbn, le.format,
           le.started_at, le.finished_at, le.created_at,
           b.id AS book_id, b.ol_work_key, b.title, b.authors,
           b.first_publish_year, b.page_count, b.cover_id, b.enrichment_status
      FROM library_entries le
      JOIN books b ON b.id = le.book_id
"""


async def upsert_book(
    conn,
    ol_work_key: str,
    title: str,
    authors: list[str],
    first_publish_year: int | None,
    page_count: int | None,
    cover_id: int | None,
):
    """ON CONFLICT is doing the real work here.

    Two users adding the same book in the same second will race. The unique
    constraint on ol_work_key plus this upsert makes that safe. An
    application-level "check if it exists, then insert" has a window between
    the check and the insert and fails under concurrency - exactly the bug the
    phase 5 SQS worker would hit, since SQS delivers at-least-once and the
    same message will be processed twice.

    COALESCE on the update side means a later call carrying better metadata
    fills gaps, but a call carrying nulls never wipes good data.
    """
    return await conn.fetchrow(
        """
        INSERT INTO books (ol_work_key, title, authors, first_publish_year,
                           page_count, cover_id)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (ol_work_key) DO UPDATE
           SET title              = COALESCE(EXCLUDED.title, books.title),
               authors            = CASE WHEN cardinality(EXCLUDED.authors) > 0
                                         THEN EXCLUDED.authors ELSE books.authors END,
               first_publish_year = COALESCE(EXCLUDED.first_publish_year,
                                             books.first_publish_year),
               page_count         = COALESCE(EXCLUDED.page_count, books.page_count),
               cover_id           = COALESCE(EXCLUDED.cover_id, books.cover_id)
        RETURNING id
        """,
        ol_work_key,
        title,
        authors,
        first_publish_year,
        page_count,
        cover_id,
    )


async def create_entry(conn, user_id: int, book_id: int, fmt: str | None):
    """Returns None if the user already has this book. DO NOTHING plus the
    UNIQUE (user_id, book_id) constraint makes a double submit harmless."""
    row = await conn.fetchrow(
        """
        INSERT INTO library_entries (user_id, book_id, format)
        VALUES ($1, $2, $3)
        ON CONFLICT (user_id, book_id) DO NOTHING
        RETURNING id
        """,
        user_id,
        book_id,
        fmt,
    )
    return row["id"] if row else None


async def get_entry(conn, user_id: int, entry_id: int):
    """The user_id in the WHERE clause is the authorization check.

    Doing it in SQL rather than fetching first and comparing in Python means
    there is no code path where you can forget it. Callers turn None into a
    404, not a 403 - a 403 would confirm the entry exists and belongs to
    someone else, which leaks information.
    """
    return await conn.fetchrow(
        ENTRY_SELECT + " WHERE le.id = $1 AND le.user_id = $2", entry_id, user_id
    )


async def list_entries(conn, user_id: int, status: str | None, limit: int, offset: int):
    if status:
        return await conn.fetch(
            ENTRY_SELECT
            + """
             WHERE le.user_id = $1 AND le.status = $2::reading_status
             ORDER BY le.created_at DESC
             LIMIT $3 OFFSET $4
            """,
            user_id,
            status,
            limit,
            offset,
        )
    return await conn.fetch(
        ENTRY_SELECT
        + """
         WHERE le.user_id = $1
         ORDER BY le.created_at DESC
         LIMIT $2 OFFSET $3
        """,
        user_id,
        limit,
        offset,
    )


async def update_entry_fields(
    conn,
    user_id: int,
    entry_id: int,
    rating: int | None,
    fmt: str | None,
    page_count_override: int | None,
    edition_isbn: str | None,
):
    return await conn.fetchrow(
        """
        UPDATE library_entries
           SET rating              = COALESCE($3, rating),
               format              = COALESCE($4, format),
               page_count_override = COALESCE($5, page_count_override),
               edition_isbn        = COALESCE($6, edition_isbn),
               updated_at          = now()
         WHERE id = $1 AND user_id = $2
        RETURNING id
        """,
        entry_id,
        user_id,
        rating,
        fmt,
        page_count_override,
        edition_isbn,
    )


async def get_current_status(conn, user_id: int, entry_id: int):
    return await conn.fetchval(
        "SELECT status FROM library_entries WHERE id = $1 AND user_id = $2",
        entry_id,
        user_id,
    )


async def update_status(conn, user_id: int, entry_id: int, new_status: str):
    """started_at and finished_at are set on first transition into their
    respective states and never overwritten - re-reading a book should not
    erase when you first started it."""
    return await conn.fetchrow(
        """
        UPDATE library_entries
           SET status      = $3::reading_status,
               started_at  = CASE WHEN $3 = 'reading'  AND started_at  IS NULL
                                  THEN now() ELSE started_at END,
               finished_at = CASE WHEN $3 = 'finished' AND finished_at IS NULL
                                  THEN now() ELSE finished_at END,
               updated_at  = now()
         WHERE id = $1 AND user_id = $2
        RETURNING id
        """,
        entry_id,
        user_id,
        new_status,
    )


async def update_progress(conn, user_id: int, entry_id: int, page: int):
    return await conn.fetchrow(
        """
        UPDATE library_entries
           SET current_page = $3, updated_at = now()
         WHERE id = $1 AND user_id = $2
        RETURNING id
        """,
        entry_id,
        user_id,
        page,
    )


async def delete_entry(conn, user_id: int, entry_id: int) -> bool:
    row = await conn.fetchrow(
        "DELETE FROM library_entries WHERE id = $1 AND user_id = $2 RETURNING id",
        entry_id,
        user_id,
    )
    return row is not None


async def record_event(
    conn,
    entry_id: int,
    event_type: str,
    from_status: str | None = None,
    to_status: str | None = None,
    page: int | None = None,
) -> None:
    await conn.execute(
        """
        INSERT INTO reading_events
            (library_entry_id, event_type, from_status, to_status, page)
        VALUES ($1, $2, $3::reading_status, $4::reading_status, $5)
        """,
        entry_id,
        event_type,
        from_status,
        to_status,
        page,
    )

# stats 

async def backlog_stats(conn, user_id: int, pages_per_hour: int):
    """Headline number: how many hours of unread books you own.

    COALESCE on page_count matters. number_of_pages_median is null for a large
    fraction of Open Library works, and without the fallback the whole sum
    returns null rather than a partial answer.
    """
    return await conn.fetchrow(
        """
        SELECT count(*) AS unread_books,
               COALESCE(sum(COALESCE(le.page_count_override, b.page_count)), 0)
                   AS unread_pages,
               round(
                 COALESCE(sum(COALESCE(le.page_count_override, b.page_count)), 0)
                 / $2::numeric, 1
               ) AS estimated_hours
          FROM library_entries le
          JOIN books b ON b.id = le.book_id
         WHERE le.user_id = $1
           AND le.status = 'want_to_read'
        """,
        user_id,
        pages_per_hour,
    )


async def completion_by_length(conn, user_id: int):
    """Do you abandon long books? NULLIF guards the divide-by-zero when a
    bucket holds only books that are still in progress."""
    return await conn.fetch(
        """
        SELECT width_bucket(b.page_count, 0, 1000, 5) AS length_bucket,
               count(*) FILTER (WHERE le.status = 'finished')  AS finished,
               count(*) FILTER (WHERE le.status = 'abandoned') AS abandoned,
               round(
                 100.0 * count(*) FILTER (WHERE le.status = 'finished')
                 / NULLIF(count(*) FILTER (
                     WHERE le.status IN ('finished','abandoned')), 0), 1
               ) AS completion_pct
          FROM library_entries le
          JOIN books b ON b.id = le.book_id
         WHERE le.user_id = $1
           AND b.page_count IS NOT NULL
         GROUP BY length_bucket
         ORDER BY length_bucket
        """,
        user_id,
    )


async def weekly_pages(conn, user_id: int, weeks: int = 12):
    """Pages read per week, derived from progress events.

    current_page is a running total per book, so the weekly delta is end_page
    minus the previous week's end_page for that same book - a window function
    partitioned by entry. The deltas need their own CTE before summing,
    because you cannot aggregate over a window function in the same SELECT.
    """
    return await conn.fetch(
        """
        WITH weekly AS (
            SELECT date_trunc('week', re.occurred_at) AS week,
                   re.library_entry_id,
                   max(re.page) AS end_page
              FROM reading_events re
              JOIN library_entries le ON le.id = re.library_entry_id
             WHERE le.user_id = $1
               AND re.event_type = 'progress'
               AND re.occurred_at >= now() - ($2 || ' weeks')::interval
             GROUP BY 1, 2
        ),
        deltas AS (
            SELECT week,
                   greatest(
                     end_page - COALESCE(
                       lag(end_page) OVER (
                         PARTITION BY library_entry_id ORDER BY week
                       ), 0
                     ), 0
                   ) AS pages
              FROM weekly
        )
        SELECT week, sum(pages)::bigint AS pages_read
          FROM deltas
         GROUP BY week
         ORDER BY week
        """,
        user_id,
        str(weeks),
    )


async def status_counts(conn, user_id: int):
    return await conn.fetch(
        """
        SELECT status::text AS status, count(*) AS n
          FROM library_entries
         WHERE user_id = $1
         GROUP BY status
        """,
        user_id,
    )
