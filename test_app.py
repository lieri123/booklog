"""Whole test suite in one file — no conftest.py, no tests package.

Run:
    python main.py --migrate
    pytest -v
"""

import os

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

os.environ.setdefault("JWT_SECRET", "test-secret")

import db  # noqa: E402
import main  # noqa: E402

pytestmark = pytest.mark.asyncio(loop_scope="session")

DUNE = {"ol_work_key": "OL893415W", "title": "Dune",
        "authors": ["Frank Herbert"], "first_publish_year": 1965,
        "page_count": 604, "cover_id": 12345}
LOTR = {"ol_work_key": "OL27448W", "title": "The Lord of the Rings",
        "authors": ["J. R. R. Tolkien"], "first_publish_year": 1954,
        "page_count": 1178, "cover_id": 258027}
SHORT_BOOK = {"ol_work_key": "OL111111W", "title": "A Short Book",
              "authors": ["Someone"], "page_count": 120}
NO_PAGES = {"ol_work_key": "OL999999W", "title": "Book With Unknown Length",
            "authors": [], "page_count": None}


@pytest_asyncio.fixture(scope="session", autouse=True, loop_scope="session")
async def _pool():
    await db.connect()
    yield
    await db.disconnect()


@pytest_asyncio.fixture(autouse=True, loop_scope="session")
async def clean_db():
    """Truncate between tests. These run against a real Postgres, not mocks —
    the SQL is the part most worth testing."""
    await db.get_pool().execute(
        "TRUNCATE reading_events, library_entries, books, users "
        "RESTART IDENTITY CASCADE")
    yield


@pytest_asyncio.fixture(loop_scope="session")
async def client():
    async with AsyncClient(transport=ASGITransport(app=main.app),
                           base_url="http://test") as c:
        yield c


async def login_as(client, email: str, password: str = "correcthorse1") -> dict:
    await client.post("/register", json={"email": email, "password": password})
    r = await client.post("/login", json={"email": email, "password": password})
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest_asyncio.fixture(loop_scope="session")
async def auth(client):
    return await login_as(client, "alice@example.com")

# ops

async def test_healthz(client):
    assert (await client.get("/healthz")).status_code == 200


async def test_readyz(client):
    assert (await client.get("/readyz")).status_code == 200

# auth

async def test_register(client):
    r = await client.post("/register",
                          json={"email": "bob@example.com",
                                "password": "correcthorse1"})
    assert r.status_code == 201
    assert "hash" not in r.text


async def test_duplicate_email_rejected(client):
    body = {"email": "bob@example.com", "password": "correcthorse1"}
    await client.post("/register", json=body)
    assert (await client.post("/register", json=body)).status_code == 409


async def test_email_is_case_insensitive(client):
    await client.post("/register", json={"email": "Bob@Example.com",
                                         "password": "correcthorse1"})
    r = await client.post("/register", json={"email": "bob@example.com",
                                             "password": "correcthorse1"})
    assert r.status_code == 409


async def test_short_password_rejected(client):
    r = await client.post("/register",
                          json={"email": "c@example.com", "password": "short"})
    assert r.status_code == 422


async def test_unknown_email_same_response_as_wrong_password(client):
    await client.post("/register", json={"email": "bob@example.com",
                                         "password": "correcthorse1"})
    a = await client.post("/login", json={"email": "bob@example.com",
                                          "password": "wrongpassword"})
    b = await client.post("/login", json={"email": "nobody@example.com",
                                          "password": "correcthorse1"})
    assert a.status_code == b.status_code == 401
    assert a.json() == b.json()


async def test_missing_token_rejected(client):
    assert (await client.get("/library")).status_code == 401


async def test_malformed_token_rejected(client):
    r = await client.get("/library", headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401


async def test_forged_token_rejected(client):
    import jwt
    forged = jwt.encode({"sub": "1"}, "attacker-secret", algorithm="HS256")
    r = await client.get("/library", headers={"Authorization": f"Bearer {forged}"})
    assert r.status_code == 401


# library

async def test_add_book(client, auth):
    r = await client.post("/library", json=DUNE, headers=auth)
    assert r.status_code == 201
    body = r.json()
    assert body["book"]["title"] == "Dune"
    assert body["status"] == "want_to_read"
    assert "default=false" in body["book"]["cover_url"]


async def test_duplicate_book_conflicts(client, auth):
    await client.post("/library", json=DUNE, headers=auth)
    assert (await client.post("/library", json=DUNE, headers=auth)).status_code == 409


async def test_two_users_share_one_book_row(client):
    """The normalization decision, verified: books is shared, library_entries
    is per-user. Two people adding Dune produce one book row, two entries."""
    alice = await login_as(client, "a@x.com")
    bob = await login_as(client, "b@x.com")
    r1 = await client.post("/library", json=DUNE, headers=alice)
    r2 = await client.post("/library", json=DUNE, headers=bob)
    assert r1.json()["book"]["id"] == r2.json()["book"]["id"]
    assert r1.json()["id"] != r2.json()["id"]


async def test_other_user_cannot_touch_entry(client):
    alice = await login_as(client, "a@x.com")
    bob = await login_as(client, "b@x.com")
    eid = (await client.post("/library", json=DUNE, headers=alice)).json()["id"]

    assert (await client.get(f"/library/{eid}", headers=bob)).status_code == 404
    assert (await client.patch(f"/library/{eid}", json={"rating": 1},
                               headers=bob)).status_code == 404
    assert (await client.patch(f"/library/{eid}/status", json={"status": "finished"},
                               headers=bob)).status_code == 404
    assert (await client.patch(f"/library/{eid}/progress", json={"page": 50},
                               headers=bob)).status_code == 404
    assert (await client.delete(f"/library/{eid}", headers=bob)).status_code == 404
    assert (await client.get(f"/library/{eid}", headers=alice)).status_code == 200


async def test_started_at_set_once(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    r1 = await client.patch(f"/library/{eid}/status",
                            json={"status": "reading"}, headers=auth)
    first = r1.json()["started_at"]
    await client.patch(f"/library/{eid}/status",
                       json={"status": "finished"}, headers=auth)
    r3 = await client.patch(f"/library/{eid}/status",
                            json={"status": "reading"}, headers=auth)
    assert r3.json()["started_at"] == first


async def test_progress_percentage(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    r = await client.patch(f"/library/{eid}/progress",
                           json={"page": 302}, headers=auth)
    assert r.json()["percent_complete"] == 50.0


async def test_page_count_override_wins(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    await client.patch(f"/library/{eid}", json={"page_count_override": 1000},
                       headers=auth)
    r = await client.patch(f"/library/{eid}/progress", json={"page": 250},
                           headers=auth)
    assert r.json()["effective_page_count"] == 1000
    assert r.json()["percent_complete"] == 25.0


async def test_filter_by_status(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    await client.post("/library", json=LOTR, headers=auth)
    await client.patch(f"/library/{eid}/status", json={"status": "reading"},
                       headers=auth)
    r = await client.get("/library?status=reading", headers=auth)
    assert len(r.json()) == 1
    assert r.json()[0]["book"]["title"] == "Dune"


async def test_delete_entry(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    assert (await client.delete(f"/library/{eid}", headers=auth)).status_code == 204
    assert (await client.get(f"/library/{eid}", headers=auth)).status_code == 404

# stats

async def test_backlog_stats(client, auth):
    await client.post("/library", json=DUNE, headers=auth)   # 604
    await client.post("/library", json=LOTR, headers=auth)   # 1178
    b = (await client.get("/stats", headers=auth)).json()["backlog"]
    assert b["unread_books"] == 2
    assert b["unread_pages"] == 1782
    assert b["estimated_hours"] == pytest.approx(44.6, abs=0.1)


async def test_backlog_survives_null_page_counts(client, auth):
    """Without COALESCE the whole sum returns null the moment one book has an
    unknown page count — and Open Library leaves that field null very often."""
    await client.post("/library", json=DUNE, headers=auth)
    await client.post("/library", json=NO_PAGES, headers=auth)
    b = (await client.get("/stats", headers=auth)).json()["backlog"]
    assert b["unread_books"] == 2
    assert b["unread_pages"] == 604


async def test_finished_excluded_from_backlog(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    await client.post("/library", json=LOTR, headers=auth)
    await client.patch(f"/library/{eid}/status", json={"status": "finished"},
                       headers=auth)
    b = (await client.get("/stats", headers=auth)).json()["backlog"]
    assert b["unread_books"] == 1
    assert b["unread_pages"] == 1178


async def test_completion_by_length(client, auth):
    s = (await client.post("/library", json=SHORT_BOOK, headers=auth)).json()["id"]
    lg = (await client.post("/library", json=LOTR, headers=auth)).json()["id"]
    await client.patch(f"/library/{s}/status", json={"status": "finished"},
                       headers=auth)
    await client.patch(f"/library/{lg}/status", json={"status": "abandoned"},
                       headers=auth)
    buckets = {b["label"]: b for b in
               (await client.get("/stats", headers=auth)).json()["by_length"]}
    assert buckets["0-200 pages"]["completion_pct"] == 100.0
    assert buckets["1000+ pages"]["completion_pct"] == 0.0


async def test_weekly_pages_uses_deltas_not_totals(client, auth):
    """current_page is a running total, so weekly pages read is the delta
    between successive readings — not their sum."""
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    for page in (100, 250, 400):
        await client.patch(f"/library/{eid}/progress", json={"page": page},
                           headers=auth)
    weekly = (await client.get("/stats", headers=auth)).json()["weekly_pages"]
    assert len(weekly) == 1
    assert weekly[0]["pages_read"] == 400   # not 750


async def test_status_counts(client, auth):
    eid = (await client.post("/library", json=DUNE, headers=auth)).json()["id"]
    await client.post("/library", json=LOTR, headers=auth)
    await client.patch(f"/library/{eid}/status", json={"status": "reading"},
                       headers=auth)
    counts = (await client.get("/stats", headers=auth)).json()["status_counts"]
    assert counts == {"reading": 1, "want_to_read": 1}


async def test_stats_scoped_per_user(client):
    alice = await login_as(client, "a@x.com")
    bob = await login_as(client, "b@x.com")
    await client.post("/library", json=DUNE, headers=alice)
    await client.post("/library", json=LOTR, headers=bob)
    a = (await client.get("/stats", headers=alice)).json()["backlog"]
    b = (await client.get("/stats", headers=bob)).json()["backlog"]
    assert a["unread_pages"] == 604
    assert b["unread_pages"] == 1178
