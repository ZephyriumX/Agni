import os
import pathlib
import sys

os.environ.setdefault("AGNI_ENV", "test")
os.environ.setdefault("AGNI_STORAGE", "memory")      # import-time app in main.py; tests build their own apps
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402

from config import Settings  # noqa: E402


@pytest.fixture(scope="session")
def pg_dsn():
    """A REAL PostgreSQL server: DATABASE_URL_TEST, or a throw-away cluster from system binaries."""
    from migrate import migrate
    url = os.getenv("DATABASE_URL_TEST")
    if url:
        migrate(url, quiet=True)
        yield url
        return
    from tests.pgtemp import TempPostgres
    try:
        pg = TempPostgres()
    except RuntimeError as e:
        pytest.skip(f"no PostgreSQL available: {e}")
    try:
        migrate(pg.dsn, quiet=True)
        yield pg.dsn
    finally:
        pg.stop()


def truncate(dsn):
    import psycopg
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute("TRUNCATE interventions, comparisons, scans, meals, users CASCADE")


@pytest.fixture(params=["memory", "postgres"])
def settings_store(request):
    from storage import MemoryStore, PostgresStore
    if request.param == "memory":
        yield Settings(env="test", storage="memory"), MemoryStore()
    else:
        dsn = request.getfixturevalue("pg_dsn")
        truncate(dsn)
        st = PostgresStore(dsn)
        yield Settings(env="test", storage="postgres", database_url=dsn), st
        st.close()


@pytest.fixture()
def client(settings_store):
    from fastapi.testclient import TestClient
    import main
    s, st = settings_store
    return TestClient(main.create_app(s, st))
