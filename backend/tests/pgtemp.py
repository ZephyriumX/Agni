"""Throw-away real PostgreSQL cluster for tests (uses system PostgreSQL server binaries).

Order of preference: DATABASE_URL_TEST env var -> a temp cluster started from /usr/lib/postgresql/*/bin
(or `pg_config --bindir`). PostgreSQL refuses to run as root, so when tests run as root the cluster is
created as an unprivileged user (PGTEST_USER, default: the first of claude/postgres/nobody that exists).
"""
from __future__ import annotations

import glob
import os
import pwd
import shutil
import subprocess
import tempfile


def find_bindir() -> str | None:
    cands = sorted(glob.glob("/usr/lib/postgresql/*/bin"), reverse=True) + glob.glob("/opt/homebrew/opt/postgresql*/bin")
    cands += glob.glob("/usr/local/pgsql/bin") + glob.glob("/Program Files/PostgreSQL/*/bin")
    for d in cands:
        if os.path.exists(os.path.join(d, "initdb")) and os.path.exists(os.path.join(d, "postgres")):
            return d
    pc = shutil.which("pg_config")
    if pc:
        d = subprocess.run([pc, "--bindir"], capture_output=True, text=True).stdout.strip()
        if os.path.exists(os.path.join(d, "initdb")):
            return d
    return None


class TempPostgres:
    def __init__(self):
        self.bindir = find_bindir()
        if not self.bindir:
            raise RuntimeError("no PostgreSQL server binaries found")
        self.dir = tempfile.mkdtemp(prefix="agni_pg_")
        self.user = None
        if os.geteuid() == 0:
            for u in (os.getenv("PGTEST_USER"), "claude", "postgres", "nobody"):
                if u:
                    try:
                        pwd.getpwnam(u); self.user = u; break
                    except KeyError:
                        pass
            if not self.user:
                raise RuntimeError("running as root and no unprivileged user available for PostgreSQL")
            shutil.chown(self.dir, self.user)
        self.port = 54000 + (os.getpid() % 900)
        self.data = os.path.join(self.dir, "data")
        self._run("initdb", "-D", self.data, "-U", "postgres", "--auth=trust", "-E", "UTF8")
        self._run("pg_ctl", "-D", self.data, "-w", "-l", os.path.join(self.dir, "log"),
                  "-o", f"-c listen_addresses='' -c unix_socket_directories={self.dir} -p {self.port} -c fsync=off",
                  "start")

    def _run(self, exe, *args):
        cmd = [os.path.join(self.bindir, exe), *args]
        if self.user:
            cmd = ["runuser", "-u", self.user, "--", *cmd]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"{exe} failed: {r.stderr or r.stdout}")

    @property
    def dsn(self) -> str:
        return f"postgresql://postgres@/postgres?host={self.dir}&port={self.port}"

    def stop(self):
        try:
            self._run("pg_ctl", "-D", self.data, "-m", "immediate", "stop")
        finally:
            shutil.rmtree(self.dir, ignore_errors=True)
