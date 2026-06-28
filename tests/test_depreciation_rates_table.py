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

# --- 一次情報突合(ゴールデン): 国税庁「減価償却資産の償却率等表」2100_02.pdf の値と完全一致 ---
#  下表は同PDFから転記した公表値。テーブルの全行がこの値と一致することを検査する
#  (将来の編集ミスや、別表からの誤転記を検出する)。
OFFICIAL_SL = {  # 定額法(平成19年4月1日以後): 耐用年数 -> 償却率
 2:'0.500',3:'0.334',4:'0.250',5:'0.200',6:'0.167',7:'0.143',8:'0.125',9:'0.112',
 10:'0.100',11:'0.091',12:'0.084',13:'0.077',14:'0.072',15:'0.067',16:'0.063',
 17:'0.059',18:'0.056',19:'0.053',20:'0.050'}
OFFICIAL_DB = {  # 200%定率法(平成24年4月1日以後): 耐用年数 -> (償却率,改定償却率,保証率)
 3:('0.667','1.000','0.11089'),4:('0.500','1.000','0.12499'),5:('0.400','0.500','0.10800'),
 6:('0.333','0.334','0.09911'),7:('0.286','0.334','0.08680'),8:('0.250','0.334','0.07909'),
 9:('0.222','0.250','0.07126'),10:('0.200','0.250','0.06552'),11:('0.182','0.200','0.05992'),
 12:('0.167','0.200','0.05566'),13:('0.154','0.167','0.05180'),14:('0.143','0.167','0.04854'),
 15:('0.133','0.143','0.04565'),16:('0.125','0.143','0.04294'),17:('0.118','0.125','0.04038'),
 18:('0.111','0.112','0.03884'),19:('0.105','0.112','0.03693'),20:('0.100','0.112','0.03486')}

vals = [f"('定額法',{n},{r}::numeric,NULL::numeric,NULL::numeric)" for n, r in OFFICIAL_SL.items()]
vals += [f"('定率法',{n},{r}::numeric,{rev}::numeric,{g}::numeric)" for n, (r, rev, g) in OFFICIAL_DB.items()]
mismatch = db.col(f"""
  WITH official(method,useful_life,rate,revised_rate,guarantee_rate) AS (VALUES {','.join(vals)})
  SELECT COALESCE(o.method,d.method)||' '||COALESCE(o.useful_life,d.useful_life)::text
  FROM official o
  FULL JOIN depreciation_rates d ON o.method=d.method AND o.useful_life=d.useful_life
  WHERE o.method IS NULL OR d.method IS NULL
     OR o.rate           IS DISTINCT FROM d.rate
     OR o.revised_rate   IS DISTINCT FROM d.revised_rate
     OR o.guarantee_rate IS DISTINCT FROM d.guarantee_rate
  ORDER BY 1""")
chk.eq("別表の全値が国税庁2100_02.pdfと完全一致(差異なし)", mismatch, [])

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
