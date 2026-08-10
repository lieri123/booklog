import os
from urllib.parse import quote_plus


def _database_url() -> str:
    """DATABASE_URL wins if set (local dev, CI, docker compose).
    """
    explicit = os.getenv("DATABASE_URL")
    if explicit:
        return explicit

    host = os.getenv("DB_HOST")
    if not host:
        return "postgresql://booktracker:devpassword@localhost:5433/booktracker"

    user = os.getenv("DB_USER", "booktracker")
    password = quote_plus(os.getenv("DB_PASSWORD", ""))
    port = os.getenv("DB_PORT", "5432")
    name = os.getenv("DB_NAME", "booktracker")
    return f"postgresql://{user}:{password}@{host}:{port}/{name}"


DATABASE_URL = _database_url()

JWT_SECRET = os.getenv("JWT_SECRET", "dev-only-secret-change-me")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", 60 * 24 * 7))

POOL_MIN_SIZE = int(os.getenv("POOL_MIN_SIZE", 2))
POOL_MAX_SIZE = int(os.getenv("POOL_MAX_SIZE", 10))

PAGES_PER_HOUR = int(os.getenv("PAGES_PER_HOUR", 40))

OL_BASE = "https://openlibrary.org"
OL_COVERS = "https://covers.openlibrary.org"
OL_TIMEOUT = 5.0
USER_AGENT = os.getenv("USER_AGENT", "BookBacklogTracker/0.1 (you@example.com)")
