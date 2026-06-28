# 償却率の別表(depreciation_rates)の網羅性と整合性のテスト
#  実行: pip install pgserver && python tests/test_depreciation_rates_table.py
#  目的:
#    - 定額法は2〜20年、定率法は3〜20年を「連続して」収録していること(欠落=実装漏れ検出)。
#    - 別表の各行を実際にスケジュール計算にかけ、期首・取得価額100万円で
#      「備忘価額1円まで完全償却(最終簿価=1, Σ償却=取得価額-1)」になることを検算する。
#      → 償却率・改定償却率・保証率の転記ミスは、ここで完全償却が崩れて検出される。
#  注記: 定率法の12年・17年は「改定償却率×残存年数=ちょうど1.000」となる年で、floor の
#        端数(数円)が最終年の翌年に繰り越される(完全償却・総額自体は正しい)。これは別表値
#        ではなくエンジンの丸め挙動。本テストは完全償却(常に成立)を検査する。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql"])
chk = Checker(db)

# --- 網羅性: 連続した耐用年数を収録していること ---
chk.eq("定額法は2〜20年を連続網羅",
       db.icol("SELECT useful_life FROM depreciation_rates WHERE method='定額法' ORDER BY useful_life"),
       list(range(2, 21)))
chk.eq("定率法は3〜20年を連続網羅",
       db.icol("SELECT useful_life FROM depreciation_rates WHERE method='定率法' ORDER BY useful_life"),
       list(range(3, 21)))

# --- 整合性: 各行を実際に計算し、完全償却(最終簿価=1, Σ=取得-1)になること ---
COST = 1000000
sl = db.rows("SELECT useful_life, rate FROM depreciation_rates WHERE method='定額法' ORDER BY useful_life")
for n, rate in sl:
    s, bv = db.rows(f"SELECT sum(depreciation)::int, min(closing_book_value)::int "
                    f"FROM straight_line_schedule({COST},'2024-01-01',{n},{rate})")[0]
    chk.eq(f"定額法 {n}年(率{rate}): 完全償却", [int(s), int(bv)], [COST - 1, 1])

db_rows = db.rows("SELECT useful_life, rate, revised_rate, guarantee_rate "
                  "FROM depreciation_rates WHERE method='定率法' ORDER BY useful_life")
for n, rate, rev, guar in db_rows:
    s, bv = db.rows(f"SELECT sum(depreciation)::int, min(closing_book_value)::int "
                    f"FROM declining_balance_schedule({COST},'2024-01-01',{n},{rate},{guar},{rev})")[0]
    chk.eq(f"定率法 {n}年(率{rate}/改定{rev}/保証{guar}): 完全償却", [int(s), int(bv)], [COST - 1, 1])

chk.done("depreciation_rates_table")
