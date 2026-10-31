"""Apply db/migrations/*.sql in order, once each, one transaction per file.

    python migrate.py            # uses DATABASE_URL
"""
import hashlib
import os
import pathlib
import sys

import psycopg

MIG_DIR = next((p for p in (pathlib.Path(__file__).resolve().parent.parent / "db" / "migrations",
                            pathlib.Path("/db/migrations")) if p.is_dir()), pathlib.Path("db/migrations"))


def migrate(dsn: str, quiet: bool = False) -> list[str]:
    applied = []
    with psycopg.connect(dsn, autocommit=False) as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations ("
                     "name TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ DEFAULT NOW())")
        conn.commit()
        done = {r[0]: r[1] for r in conn.execute("SELECT name, checksum FROM schema_migrations")}
        for f in sorted(MIG_DIR.glob("*.sql")):
            sql = f.read_text()
            digest = hashlib.sha256(sql.encode()).hexdigest()
            if f.name in done:
                if done[f.name] != digest:
                    raise RuntimeError(f"migration {f.name} was modified after being applied")
                continue
            with conn.transaction():
                conn.execute(sql)
                conn.execute("INSERT INTO schema_migrations(name, checksum) VALUES (%s,%s)", (f.name, digest))
            applied.append(f.name)
            if not quiet:
                print("applied", f.name)
    return applied


if __name__ == "__main__":
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        sys.exit("DATABASE_URL is not set")
    migrate(dsn)
