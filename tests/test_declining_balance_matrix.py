# 定率法(200%)スケジュールの網羅的回帰テスト
#  実行: pip install pgserver && python tests/test_declining_balance_matrix.py
#  目的: エンジン(declining_balance_schedule)の挙動を、耐用年数3〜20年 ×
#        取得時期(期首/期中/期末) × 複数の取得価額の全組合せで固定・検証する。
#        会計上常に成り立つ不変条件を全ケースで検査し、代表ケースは完全な
#        スケジュール(年度・償却費・期末簿価)を期待値で固定する。
#  本ファイルは『エンジン修正の前後で不変であるべき性質』に限定して固定する
#  (リファクタの安全網)。改定後最終年の端数繰越(微小テール)が無いことの検査は、
#  その修正と同時に追加する(末尾の「微小テール」セクション)。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql"])
chk = Checker(db)

RATES = {int(n): (r, rev, g) for n, r, rev, g in db.rows(
    "SELECT useful_life, rate, revised_rate, guarantee_rate "
    "FROM depreciation_rates WHERE method='定率法' ORDER BY useful_life")}
STARTS = {"期首": "2024-01-01", "期中": "2024-07-01", "期末": "2024-12-31"}
COSTS = [1000000, 1234567, 333333, 87654321]


def fetch(cost, d, n, r, g, rev):
    rows = db.rows(f"SELECT fiscal_year, depreciation, accumulated, closing_book_value "
                   f"FROM declining_balance_schedule({cost},'{d}',{n},{r},{g},{rev})")
    return [tuple(int(x) for x in row) for row in rows]


# ---------- 全マトリクスで「常に成り立つ不変条件」を検査 ----------
#  これらは丸めテールの有無に関わらず必ず成立し、エンジン修正の前後で不変であるべき。
bad = []
for n in sorted(RATES):
    r, rev, g = RATES[n]
    for label, d in STARTS.items():
        for cost in COSTS:
            rows = fetch(cost, d, n, r, g, rev)
            why = None
            if not rows:
                why = "0行"
            elif rows[-1][3] != 1:
                why = f"最終簿価={rows[-1][3]}(≠1)"
            elif sum(x[1] for x in rows) != cost - 1:
                why = f"Σ償却={sum(x[1] for x in rows)}(≠{cost-1})"
            else:
                prev = cost
                for (y, dep, acc, close) in rows:
                    if dep < 0 or close > prev or acc + close != cost:
                        why = f"不変条件違反 @{y}: dep={dep} close={close} acc={acc}"
                        break
                    prev = close
            if why:
                bad.append(f"{n}年{label}/cost{cost}: {why}")
chk.eq("全マトリクス(3〜20年×期首/期中/期末×4価額)で完全償却・単調・累計整合",
       bad, [])

# ---------- 代表ケース(テールの無い年数)の完全なスケジュールを期待値で固定 ----------
#  修正で変わってはならない挙動。値は現行エンジンから取得した golden。
GOLDENS = [
  ("期首_6年", "declining_balance_schedule(1000000,'2024-01-01',6,0.33300,0.09911,0.33400)",
   [(2024,333000,667000),(2025,222111,444889),(2026,148148,296741),(2027,99111,197630),(2028,99111,98519),(2029,98518,1)]),
  ("期首_10年", "declining_balance_schedule(1000000,'2024-01-01',10,0.20000,0.06552,0.25000)",
   [(2024,200000,800000),(2025,160000,640000),(2026,128000,512000),(2027,102400,409600),(2028,81920,327680),(2029,65536,262144),(2030,65536,196608),(2031,65536,131072),(2032,65536,65536),(2033,65535,1)]),
  ("期首_20年", "declining_balance_schedule(1000000,'2024-01-01',20,0.10000,0.03486,0.11200)",
   [(2024,100000,900000),(2025,90000,810000),(2026,81000,729000),(2027,72900,656100),(2028,65610,590490),(2029,59049,531441),(2030,53144,478297),(2031,47829,430468),(2032,43046,387422),(2033,38742,348680),(2034,34868,313812),(2035,35146,278666),(2036,35146,243520),(2037,35146,208374),(2038,35146,173228),(2039,35146,138082),(2040,35146,102936),(2041,35146,67790),(2042,35146,32644),(2043,32643,1)]),
  ("期中_6年", "declining_balance_schedule(1000000,'2024-07-01',6,0.33300,0.09911,0.33400)",
   [(2024,166500,833500),(2025,277555,555945),(2026,185129,370816),(2027,123481,247335),(2028,82609,164726),(2029,82609,82117),(2030,82116,1)]),
  ("期末_6年", "declining_balance_schedule(1000000,'2024-12-31',6,0.33300,0.09911,0.33400)",
   [(2024,27750,972250),(2025,323759,648491),(2026,215947,432544),(2027,144037,288507),(2028,96361,192146),(2029,96361,95785),(2030,95784,1)]),
]
for name, call, expected in GOLDENS:
    rows = db.rows(f"SELECT fiscal_year, depreciation, closing_book_value FROM {call}")
    chk.eq(f"golden {name}", [(int(y), int(dp), int(c)) for y, dp, c in rows], expected)

chk.done("declining_balance_matrix")
