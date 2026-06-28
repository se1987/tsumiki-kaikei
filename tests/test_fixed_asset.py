# 固定資産台帳レイヤーのテスト(fixed_asset.sql)
#  実行: pip install pgserver && python tests/test_fixed_asset.py
#  正常系: 別表からの償却率解決 / 事業専用割合の按分 / 自動仕訳の冪等な計上
#  異常系: 定率法の率未設定で例外 / CHECK 制約(取得価額・事業割合・償却方法) / 二重計上の UNIQUE
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql", "fixed_asset.sql"])
chk = Checker(db)

# ---------- 前提マスタ: 必要な勘定科目 ----------
db.rows("""
INSERT INTO accounts(code,name,account_type) VALUES
  ('FUR','工具器具備品','asset'),
  ('ACC','減価償却累計額','asset'),
  ('DEP','減価償却費','expense'),
  ('DRAW','事業主貸','asset');
""")

# ---------- 資産A: 定額法5年・償却率は資産個別NULL → 別表(0.200)から解決・事業割合80% ----------
asset_a = db.scalar("""
INSERT INTO fixed_assets
  (name, asset_account_code, accum_account_code, expense_account_code,
   acquisition_date, service_start_date, acquisition_cost, method,
   useful_life, business_use_ratio)
VALUES ('ノートPC','FUR','ACC','DEP','2024-01-10','2024-01-10',1000000,'定額法',5,0.8)
RETURNING id;
""")

# (正常系) asset_schedule が別表の率(0.200)を使って定額法スケジュールを返す。
chk.eq("資産A: 別表から定額法0.200を解決",
       db.icol(f"SELECT depreciation FROM asset_schedule({asset_a}) ORDER BY fiscal_year"),
       [200000, 200000, 200000, 200000, 199999])

# (正常系/エッジ) 事業専用割合80%: 全額200000 → 事業160000 / 家事40000。
chk.eq("資産A: 2024年の全額/事業/家事の按分",
       [int(x) for x in db.rows(
           f"SELECT full_dep, business_dep, private_dep FROM asset_depreciation({asset_a},2024)")[0]],
       [200000, 160000, 40000])

# ---------- 自動仕訳の計上 + 冪等性 ----------
# 1回目: 資産1件を処理 → 戻り値1。減価償却+家事振替の2リンクが作られる。
chk.eq("post_depreciation 初回は1件計上", db.icol(
    "SELECT post_depreciation(2024, DATE '2024-12-31', 'DRAW')"), [1])
chk.eq("初回後: 資産Aの2024リンクは2種(償却+家事振替)",
       sorted(db.col(f"SELECT kind FROM asset_depreciation_postings "
                     f"WHERE asset_id={asset_a} AND fiscal_year=2024")),
       ["depreciation", "private_transfer"])
# 計上された仕訳の貸借が一致している(減価償却費200000 / 家事振替40000 が両建て)。
chk.true("計上仕訳の借方合計=貸方合計",
         db.scalar("SELECT (SELECT COALESCE(sum(amount),0) FROM entries WHERE side='debit') "
                   "= (SELECT COALESCE(sum(amount),0) FROM entries WHERE side='credit')") == "t")

# 2回目: 既に計上済みなのでスキップ → 戻り値0、リンク数も増えない。
chk.eq("post_depreciation 再実行は0件(冪等)", db.icol(
    "SELECT post_depreciation(2024, DATE '2024-12-31', 'DRAW')"), [0])
chk.eq("再実行後もリンクは2件のまま",
       db.icol(f"SELECT count(*)::int FROM asset_depreciation_postings "
               f"WHERE asset_id={asset_a} AND fiscal_year=2024"),
       [2])

# (異常系) UNIQUE(資産,年度,種別): 既存リンクと同一の組み合わせを直接挿入すると拒否される。
chk.error("UNIQUE で同年同種別の二重計上を拒否",
          "INSERT INTO asset_depreciation_postings(asset_id,transaction_id,fiscal_year,kind) "
          f"SELECT asset_id,transaction_id,fiscal_year,kind FROM asset_depreciation_postings "
          f"WHERE asset_id={asset_a} AND fiscal_year=2024 AND kind='depreciation'",
          "duplicate key value")

# ---------- (異常系) 定率法で率が資産にも別表にも無い → 実行時例外 ----------
asset_b = db.scalar("""
INSERT INTO fixed_assets
  (name, asset_account_code, accum_account_code, expense_account_code,
   acquisition_date, service_start_date, acquisition_cost, method, useful_life)
VALUES ('特殊機械','FUR','ACC','DEP','2024-03-01','2024-03-01',2000000,'定率法',99)
RETURNING id;
""")
chk.error("定率法で率未設定なら asset_schedule が例外で停止",
          f"SELECT * FROM asset_schedule({asset_b})",
          "定率法の率が未設定です")

# ---------- (異常系) fixed_assets の CHECK 制約 ----------
BASE = ("INSERT INTO fixed_assets"
        "(name,asset_account_code,accum_account_code,expense_account_code,"
        "acquisition_date,service_start_date,acquisition_cost,method,useful_life{cols}) "
        "VALUES ('x','FUR','ACC','DEP','2024-01-01','2024-01-01',{cost},'{method}',5{vals})")

chk.error("取得価額0は CHECK 違反",
          BASE.format(cols="", vals="", cost=0, method="定額法"),
          "acquisition_cost")
chk.error("事業専用割合>1 は CHECK 違反",
          BASE.format(cols=",business_use_ratio", vals=",1.5", cost=1000, method="定額法"),
          "business_use_ratio")
chk.error("事業専用割合0 は CHECK 違反",
          BASE.format(cols=",business_use_ratio", vals=",0", cost=1000, method="定額法"),
          "business_use_ratio")
chk.error("未対応の償却方法は CHECK 違反",
          BASE.format(cols="", vals="", cost=1000, method="生産高比例法"),
          "fixed_assets_method_check")

chk.done("fixed_asset")
