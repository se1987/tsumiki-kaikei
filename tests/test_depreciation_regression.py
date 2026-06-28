#  減価償却スケジュールの回帰テスト
#  実行: pip install pgserver && python tests/test_depreciation_regression.py
#  目的: 定額法/定率法(期首・期中・期末取得)/一括償却の各スケジュールを期待値で固定する。
#        特に「期末近く取得時に定率法が誤って改定切替する」不具合の再発を防ぐ。
import pgserver, pathlib, tempfile, sys

# このファイルは tests/ 配下にあるため、sql/ はリポジトリ直下(=親の親)を見る。
SQLDIR = str(pathlib.Path(__file__).resolve().parent.parent / "sql") + "/"
db = pgserver.get_server(pathlib.Path(tempfile.mkdtemp(prefix="depreg_")))
for f in ["schema.sql", "financial_statements.sql", "depreciation.sql"]:
    db.psql(pathlib.Path(SQLDIR + f).read_text())

def col(sql):
    """1列クエリの結果を整数のリストで返す(psql整形出力をパース)。"""
    out = db.psql(sql)
    lines = [l.strip() for l in out.splitlines()]
    sep = next(i for i, l in enumerate(lines) if l and set(l) <= set("-+"))
    vals = []
    for l in lines[sep + 1:]:
        if not l or l.startswith("("):
            break
        vals.append(int(l))
    return vals

CASES = [
    ("定率法 5年 期首(1月)取得",
     "SELECT depreciation FROM declining_balance_schedule(1000000,'2024-01-01',5,0.400,0.10800,0.500)",
     [400000, 240000, 144000, 108000, 107999]),
    ("定率法 5年 期中(7月)取得",
     "SELECT depreciation FROM declining_balance_schedule(1000000,'2024-07-01',5,0.400,0.10800,0.500)",
     [200000, 320000, 192000, 115200, 86400, 86399]),
    ("定率法 5年 期末(12月)取得 ★回帰対象",
     "SELECT depreciation FROM declining_balance_schedule(1000000,'2024-12-01',5,0.400,0.10800,0.500)",
     [33333, 386666, 232000, 139200, 104400, 104400]),
    ("定額法 5年 期首取得",
     "SELECT depreciation FROM straight_line_schedule(1000000,'2024-01-01',5,0.200)",
     [200000, 200000, 200000, 200000, 199999]),
    ("一括償却 20万(3年均等)",
     "SELECT depreciation FROM lump_sum_schedule(200000,2024)",
     [66666, 66666, 66668]),
]

ok = True
for name, sql, expected in CASES:
    got = col(sql)
    passed = got == expected
    ok = ok and passed
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")
    if not passed:
        print(f"        期待: {expected}")
        print(f"        実際: {got}")

# 検算: 償却費合計と最終簿価
INV = [
    ("定率法5年(期首)", 999999, 1,
     "declining_balance_schedule(1000000,'2024-01-01',5,0.400,0.10800,0.500)"),
    ("一括償却20万",   200000, 0, "lump_sum_schedule(200000,2024)"),
]
for name, exp_sum, exp_bv, fn in INV:
    s = col(f"SELECT sum(depreciation)::int FROM {fn}")[0]
    bv = col(f"SELECT min(closing_book_value)::int FROM {fn}")[0]
    passed = (s == exp_sum and bv == exp_bv)
    ok = ok and passed
    print(f"[{'PASS' if passed else 'FAIL'}] 検算 {name}: 合計={s} 最終簿価={bv}")

print("\n" + ("全テストPASS" if ok else "失敗あり"))
sys.exit(0 if ok else 1)
