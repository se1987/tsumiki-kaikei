# 固定資産台帳の「表示償却率」テスト(fixed_asset.sql)
#  実行: pip install pgserver && python tests/test_asset_register_rate.py
#  asset_register が表示する償却率は、asset_schedule が実計算で使う率と一致しなければ
#  ならない(解決順: 資産個別 fa.rate > 別表 depreciation_rates > 1/n近似)。
#  耐用年数3年は別表が0.334、1/3近似は0.333。台帳表示が0.333だと別表値とズレる。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql", "fixed_asset.sql"])
chk = Checker(db)

db.rows("""
INSERT INTO accounts(code,name,account_type) VALUES
  ('FUR','工具器具備品','asset'),
  ('ACC','減価償却累計額','asset'),
  ('DEP','減価償却費','expense');
""")

# 定額法3年・資産個別の率はNULL → 別表(0.334)から解決される資産。
db.rows("""
INSERT INTO fixed_assets
  (name, asset_account_code, accum_account_code, expense_account_code,
   acquisition_date, service_start_date, acquisition_cost, method, useful_life)
VALUES ('工具(3年)','FUR','ACC','DEP','2024-01-10','2024-01-10',900000,'定額法',3);
""")
# 定額法4年・資産個別の率を明示(0.250) → 個別優先で表示されることの確認。
db.rows("""
INSERT INTO fixed_assets
  (name, asset_account_code, accum_account_code, expense_account_code,
   acquisition_date, service_start_date, acquisition_cost, method, useful_life, rate)
VALUES ('器具(4年/個別率)','FUR','ACC','DEP','2024-01-10','2024-01-10',800000,'定額法',4,0.250);
""")

# (正常系) 3年: 台帳の表示率 = 別表の0.334(1/3近似の0.333ではない)
chk.eq("asset_register 3年の表示率は別表0.334(0.333ではない)",
       db.col("SELECT round(rate,3)::text FROM asset_register(2024) WHERE name='工具(3年)'"),
       ["0.334"])

# (正常系) 表示率は asset_schedule の実計算と一致(初年度償却 = 900000*0.334 = 300600)
chk.eq("asset_schedule 3年の初年度償却は表示率0.334と整合(300600)",
       db.icol("SELECT depreciation FROM asset_schedule("
               "(SELECT id FROM fixed_assets WHERE name='工具(3年)')) ORDER BY fiscal_year LIMIT 1"),
       [300600])

# (正常系) 資産個別の率は別表より優先して表示される
chk.eq("asset_register は資産個別率0.250を優先表示",
       db.col("SELECT round(rate,3)::text FROM asset_register(2024) WHERE name='器具(4年/個別率)'"),
       ["0.250"])

chk.done("asset_register_rate")
