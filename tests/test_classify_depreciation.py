# classify_depreciation(取得価額による経理方法の判定)のテスト
#  実行: pip install pgserver && python tests/test_classify_depreciation.py
#  正常系・境界値(10万/20万/30万)・青色/非青色のエッジを固定する。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql"])
chk = Checker(db)

IMMEDIATE = "即時経費(少額減価償却資産)"
LUMP      = "一括償却資産(3年均等)"
SPECIAL   = "措置法28の2(青色30万円特例)"
NORMAL    = "通常償却(定額法/定率法)"


def treatments(cost, is_blue):
    # 順序非依存で比較するためソートして集合的に扱う。
    return sorted(db.col(
        f"SELECT treatment FROM classify_depreciation({cost}, {str(is_blue).lower()})"))


# --- 10万円未満: 取得価額・青色可否によらず即時経費のみ ---
chk.eq("1円: 即時経費のみ",        treatments(1, True),     [IMMEDIATE])
chk.eq("99,999円: 即時経費のみ",    treatments(99999, True), [IMMEDIATE])
chk.eq("99,999円(非青色)も同じ",   treatments(99999, False),[IMMEDIATE])

# --- 10万円以上20万円未満 ---
chk.eq("10万円(青色): 一括/通常/30万特例", treatments(100000, True),  sorted([LUMP, NORMAL, SPECIAL]))
chk.eq("10万円(非青色): 一括/通常",        treatments(100000, False), sorted([LUMP, NORMAL]))
chk.eq("199,999円(青色): 一括/通常/30万特例", treatments(199999, True), sorted([LUMP, NORMAL, SPECIAL]))

# --- 20万円以上30万円未満 ---
chk.eq("20万円(青色): 通常/30万特例", treatments(200000, True),  sorted([NORMAL, SPECIAL]))
chk.eq("20万円(非青色): 通常のみ",    treatments(200000, False), [NORMAL])
chk.eq("299,999円(青色): 通常/30万特例", treatments(299999, True), sorted([NORMAL, SPECIAL]))

# --- 30万円以上: 青色でも通常償却のみ(30万特例は 30万円「未満」) ---
chk.eq("30万円(青色): 通常のみ",   treatments(300000, True),  [NORMAL])
chk.eq("30万円(非青色): 通常のみ", treatments(300000, False), [NORMAL])
chk.eq("100万円(青色): 通常のみ",  treatments(1000000, True), [NORMAL])

chk.done("classify_depreciation")
