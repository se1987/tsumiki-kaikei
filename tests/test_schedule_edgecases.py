# 償却スケジュール関数のエッジケース・追加正常系テスト
#  実行: pip install pgserver && python tests/test_schedule_edgecases.py
#  既存の test_depreciation_regression.py を補完する。
#    - 定額法: 償却率NULL(1/n近似)/最短2年/期中・期末取得(n+1年化)/p_through_year 打切り
#    - 一括償却: 端数の3年目吸収(10万/30万)
#    - 定率法: 4年(期首)で改定切替に至る系列
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql"])
chk = Checker(db)

# ---------- 定額法 ----------
# 償却率を NULL にすると round(1/n,3) で近似する。n=5 → 0.200 と一致するはず。
chk.eq("定額法 償却率NULL=1/n近似(5年)",
       db.icol("SELECT depreciation FROM straight_line_schedule(1000000,'2024-01-01',5,NULL)"),
       [200000, 200000, 200000, 200000, 199999])

# 最短の耐用年数2年。最終年は備忘1円まで。
chk.eq("定額法 2年 期首取得",
       db.icol("SELECT depreciation FROM straight_line_schedule(1000000,'2024-01-01',2,0.500)"),
       [500000, 499999])

# 期末(12月)取得は初年度が1か月按分となり、結果として n+1 年に渡る。
chk.eq("定額法 5年 期末(12月)取得 → 6年に按分",
       db.icol("SELECT depreciation FROM straight_line_schedule(1000000,'2024-12-01',5,0.200)"),
       [16666, 200000, 200000, 200000, 200000, 183333])

# p_through_year で計算を途中打切りできる。
chk.eq("定額法 5年 2025年まで打切り",
       db.icol("SELECT depreciation FROM straight_line_schedule(1000000,'2024-01-01',5,0.200,2025)"),
       [200000, 200000])

# 検算: 合計と最終簿価(備忘1円)
chk.eq("定額法 5年 合計=取得-1, 最終簿価=1",
       [int(x) for x in db.rows("SELECT sum(depreciation)::int, min(closing_book_value)::int "
               "FROM straight_line_schedule(1000000,'2024-01-01',5,0.200)")[0]],
       [999999, 1])

# ---------- 一括償却(3年均等・備忘価額なし・端数は3年目で吸収) ----------
chk.eq("一括償却 10万(3年均等)",
       db.icol("SELECT depreciation FROM lump_sum_schedule(100000,2024)"),
       [33333, 33333, 33334])
chk.eq("一括償却 30万(割り切れ)",
       db.icol("SELECT depreciation FROM lump_sum_schedule(300000,2024)"),
       [100000, 100000, 100000])
chk.eq("一括償却 20万 合計=全額, 最終簿価=0",
       [int(x) for x in db.rows("SELECT sum(depreciation)::int, min(closing_book_value)::int "
               "FROM lump_sum_schedule(200000,2024)")[0]],
       [200000, 0])

# ---------- 定率法(200%) 4年・期首取得で改定償却率へ切替 ----------
#  Y1..Y3 は通常の定率、Y4 で調整前償却額が保証額を下回り改定(改定率1.000)に切替。
chk.eq("定率法 4年 期首取得(改定切替あり)",
       db.icol("SELECT depreciation FROM declining_balance_schedule"
               "(1000000,'2024-01-01',4,0.500,0.12499,1.000)"),
       [500000, 250000, 125000, 124999])

chk.done("schedule_edgecases")
