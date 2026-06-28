# post_depreciation の勘定科目コード検証(異常系)
#  実行: pip install pgserver && python tests/test_post_depreciation_accounts.py
#  資産に設定した勘定科目コードが accounts に存在しない場合、以前は INSERT...SELECT が
#  0行挿入で正常終了し、借方=貸方=0 のまま「空の償却仕訳が計上済み扱い」になっていた
#  (沈黙の未計上)。本テストは、各科目の欠落で明示的に例外停止し、かつ空の取引・リンクを
#  一切残さない(全ロールバック)ことを固定する。正常系(全科目あり)も併せて確認する。
from _harness import DB, Checker

SQL = ["schema.sql", "financial_statements.sql", "depreciation.sql", "fixed_asset.sql"]
chk = Checker(DB(SQL))   # 集計用。各シナリオは独立した DB で実行する。

ASSET = ("INSERT INTO fixed_assets"
         "(name,asset_account_code,accum_account_code,expense_account_code,"
         " acquisition_date,service_start_date,acquisition_cost,method,useful_life,business_use_ratio)"
         " VALUES ('PC','FUR','ACC','DEP','2024-01-01','2024-01-01',1000000,'定額法',5,{ratio})")
POST = "SELECT post_depreciation(2024, DATE '2024-12-31', 'DRAW')"


def scenario(accounts_sql, ratio):
    """新しい DB に、指定の勘定科目だけを作って資産を1件登録した状態を用意する。"""
    db = DB(SQL)
    if accounts_sql:
        db.rows(accounts_sql)
    db.rows(ASSET.format(ratio=ratio))
    return db


def assert_no_side_effects(name, db):
    """例外で停止した後、空の取引・仕訳・リンクが残っていないこと(全ロールバック)。"""
    n = [int(x) for x in db.rows(
        "SELECT (SELECT count(*) FROM transactions), "
        "(SELECT count(*) FROM entries), "
        "(SELECT count(*) FROM asset_depreciation_postings)")[0]]
    chk.eq(f"{name}: 取引/仕訳/リンクを一切残さない", n, [0, 0, 0])


# --- 1. 全科目欠落: 減価償却費の科目が無い時点で停止 ---
db1 = scenario("", ratio=1.0)
chk.error("全科目欠落: 減価償却費の科目欠落で例外", POST,
          "減価償却費の勘定科目が存在しません", sqlstate="P0001", db=db1)
assert_no_side_effects("全科目欠落", db1)

# --- 2. 累計額科目だけ欠落 ---
db2 = scenario("INSERT INTO accounts(code,name,account_type) VALUES ('DEP','減価償却費','expense')",
               ratio=1.0)
chk.error("累計額科目欠落で例外", POST,
          "減価償却累計額の勘定科目が存在しません", sqlstate="P0001", db=db2)
assert_no_side_effects("累計額科目欠落", db2)

# --- 3. 事業主貸欠落かつ家事使用分あり(business_use_ratio<1) ---
db3 = scenario("INSERT INTO accounts(code,name,account_type) VALUES "
               "('DEP','減価償却費','expense'),('ACC','減価償却累計額','asset')",
               ratio=0.5)   # private_dep>0 になるので事業主貸が必要
chk.error("事業主貸欠落(家事分あり)で例外", POST,
          "事業主貸の勘定科目が存在しません", sqlstate="P0001", db=db3)
assert_no_side_effects("事業主貸欠落", db3)

# --- 4. (正常系) 全科目そろっていれば従来どおり計上できる(ガードが happy path を壊さない) ---
db4 = scenario("INSERT INTO accounts(code,name,account_type) VALUES "
               "('FUR','工具器具備品','asset'),('ACC','減価償却累計額','asset'),"
               "('DEP','減価償却費','expense'),('DRAW','事業主貸','asset')",
               ratio=0.8)
chk.eq("全科目あり: post_depreciation は1件計上", db4.icol(POST), [1])
chk.eq("全科目あり: 償却仕訳の明細が作られている(>0)",
       [db4.icol("SELECT count(*)::int FROM entries")[0] > 0], [True])

chk.done("post_depreciation_accounts")
