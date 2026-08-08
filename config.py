import os

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://booktracker:devpassword@localhost:5433/booktracker"
)

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
