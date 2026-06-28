# 共有テストハーネス
#  pgserver をその場に起動し、SQL をロードして、テストから問い合わせ・異常系検査を行う。
#  pgserver.psql は ON_ERROR_STOP を付けず stderr も握りつぶす(SQL エラーでも例外にならない)。
#  そのため異常系(例外・制約違反)を検査できるよう、psql を直接 -v ON_ERROR_STOP=1 で呼び、
#  終了コードと stderr を取得するハーネスを用意する。
import subprocess, pathlib, tempfile, sys
import pgserver

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQLDIR = ROOT / "sql"
# pgserver 同梱の PostgreSQL バイナリ(pginstall/bin)。別途 PostgreSQL を立てる必要はない。
PG_BIN = pathlib.Path(pgserver.__file__).resolve().parent / "pginstall" / "bin"
PSQL = str(PG_BIN / "psql")


class DB:
    """pgserver を起動し SQL をロードした検証用データベース。"""

    def __init__(self, sql_files):
        self.server = pgserver.get_server(pathlib.Path(tempfile.mkdtemp(prefix="ttest_")))
        self.uri = self.server.get_uri()
        for f in sql_files:
            r = self._run((SQLDIR / f).read_text())
            if r.returncode != 0:
                raise RuntimeError(f"SQL ロード失敗 {f}:\n{r.stderr.decode('utf-8')}")

    def _run(self, sql, tuples=False):
        args = [PSQL, self.uri, "-v", "ON_ERROR_STOP=1"]
        if tuples:
            args += ["-At", "-F", "|"]   # 非整列・タプルのみ・区切り '|'
        return subprocess.run(args, input=sql.encode("utf-8"), capture_output=True)

    def rows(self, sql):
        """成功前提のクエリ。行のリスト(各行は文字列タプル)を返す。"""
        r = self._run(sql, tuples=True)
        if r.returncode != 0:
            raise AssertionError(f"クエリ失敗: {sql}\n{r.stderr.decode('utf-8')}")
        out = r.stdout.decode("utf-8").splitlines()
        return [tuple(line.split("|")) for line in out if line != ""]

    def col(self, sql):
        """1列クエリの結果を文字列リストで返す。"""
        return [row[0] for row in self.rows(sql)]

    def icol(self, sql):
        """1列クエリの結果を整数リストで返す。"""
        return [int(x) for x in self.col(sql)]

    def scalar(self, sql):
        c = self.col(sql)
        return c[0] if c else None


class Checker:
    """テスト結果を集計し、最後に終了コードへ反映する簡易アサータ。"""

    def __init__(self, db):
        self.db = db
        self.ok = True

    def _record(self, name, passed, detail=None):
        self.ok = self.ok and passed
        print(f"[{'PASS' if passed else 'FAIL'}] {name}")
        if not passed and detail:
            print(detail)

    def eq(self, name, got, expected):
        self._record(name, got == expected,
                     f"        期待: {expected}\n        実際: {got}")

    def true(self, name, cond, detail=""):
        self._record(name, bool(cond), f"        {detail}")

    def error(self, name, sql, substr):
        """sql が失敗し、stderr に substr を含むことを検査(異常系)。"""
        r = self.db._run(sql)
        msg = r.stderr.decode("utf-8")
        passed = r.returncode != 0 and substr in msg
        detail = (f"        期待エラー含む: {substr}\n"
                  f"        実際(rc={r.returncode}): {msg.strip()[:400] or '(エラー無し)'}")
        self._record(name, passed, detail)

    def done(self, title):
        print("\n" + (f"{title}: 全テストPASS" if self.ok else f"{title}: 失敗あり"))
        sys.exit(0 if self.ok else 1)
