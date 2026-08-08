# Book backlog tracker

FastAPI service tracking a reading backlog, backed by Postgres. Deploys to
AWS ECS Fargate in later phases.

## Setup

```powershell
pip install -r requirements.txt

docker compose up -d db

$env:DATABASE_URL = "postgresql://booktracker:devpassword@localhost:5433/booktracker"
$env:JWT_SECRET   = "dev-only-secret"

python main.py --migrate     # create the schema
pytest -v                    # 26 tests
python main.py               # http://localhost:8080/docs
```

## Modules

All flat in one directory — no packages, so no `__init__.py` and no import
path problems.

| File | Lines | |
|---|---|---|
| `config.py` | ~30 | Environment variables, all config in one place |
| `security.py` | ~80 | argon2 hashing, JWT issue/verify, auth dependency |
| `openlibrary.py` | ~90 | Open Library client, timeouts, defensive parsing |
| `models.py` | ~150 | Pydantic request/response models |
| `db.py` | ~380 | Connection pool, schema, every SQL statement |
| `main.py` | ~260 | FastAPI app and all routes |
| `test_app.py` | ~330 | All 26 tests |

Import direction runs one way: `main` → `db`/`models`/`security`/`openlibrary`
→ `config`. Nothing imports `main`, so there are no circular imports.

## Design decisions

**Works vs editions.** Open Library separates works (*Dune*, the novel) from
editions (a specific printing with its own ISBN and page count). `books` is
keyed on the work and stores the median page count; a user's specific edition
lives on their `library_entries` row. This keeps `books` genuinely shared —
one row for *Dune* regardless of how many users add it.

**`/healthz` does not touch the database.** It's the ALB health check target.
If it queried Postgres, a slow database would fail health checks on every
task and turn a degraded database into a total outage. `/readyz` does check,
and is for deployment tooling only.

**404, not 403, for another user's entry.** A 403 confirms the record exists.
Authorization is enforced by putting `user_id` in the `WHERE` clause rather
than fetching and comparing in Python.

**Constraints, not application checks.** Registration catches
`UniqueViolationError`; `upsert_book` uses `ON CONFLICT`. A check-then-insert
has a race window. This matters in phase 5: SQS delivers at-least-once, so
the same enrichment message will be processed twice.

**Raw SQL, no ORM.** The stats queries are the interesting part of this
project.

## Roadmap

- [x] Phase 1 — service, schema, tests, Docker, CI
- [ ] Phase 2 — VPC, subnets, RDS in private subnets (Terraform)
- [ ] Phase 3 — ECR, ECS Fargate, ALB, GitHub Actions deploy via OIDC
- [ ] Phase 4 — CloudWatch dashboards, alarms, autoscaling, k6 load test
- [ ] Phase 5 — SQS enrichment worker, S3 cover cache, DLQ
