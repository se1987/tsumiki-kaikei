#  減価償却スケジュールの回帰テスト
#  実行: pip install pgserver && python tests/test_depreciation_regression.py
#  目的: 定額法/定率法(期首・期中・期末取得)/一括償却の各スケジュールを期待値で固定する。
#        特に「期末近く取得時に定率法が誤って改定切替する」不具合の再発を防ぐ。
#
#  本テストは「期待値固定の回帰テスト」と「全ケース共通の不変条件(Invariant)」の二段構えで、
#  実装が変わらないこと(回帰)と、変わったとしても会計上あり得ない壊れ方をしないこと(不変条件)を
#  別々に保証する。レビュー指摘を踏まえ、次の点を担保する:
#    ① 償却費だけでなく fiscal_year と期末簿価まで、行ごとに期待値で固定する(ORDER BY 事故も検出)
#    ② 期末簿価は「最終行の min」ではなく全行を固定する(途中の壊れも検出)
#    ③ 期待値リストとの完全一致により行数・年度の並びも検証する
#    ④ テスト名に入力条件(取得価額・取得時期)を明示する
#    ⑤ psql の整形に依存しない -At(タプルのみ)出力で取得する(_harness 経由。StopIteration を排除)
#    ⑥ 端数の出やすい取得価額(1,234,567 等)を複数含める
#    ⑦ 境界条件(耐用年数1年・取得価額1円・12/31 と 1/1 取得・うるう年取得)を含める
#  ※少額減価償却資産の境界(10万/20万/30万)は test_classify_depreciation.py で検証している。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "depreciation.sql"])
chk = Checker(db)

# 通常償却(定額法・定率法)の残存簿価は備忘1円、一括償却は0円。
R_MEMO, R_ZERO = 1, 0

# 各ケース: 入力(取得価額・取得時期)・期待値(行ごとの (年度, 償却費, 期末簿価))・残存簿価。
#   expected を完全一致で照合することで、償却費・期末簿価・行数・年度の昇順をまとめて固定する。
CASES = [
    # --- 定率法(200%): 取得時期で初年度按分が変わる。期末取得が回帰の主対象。 ---
    dict(name="定率法_5年_100万円_期首(1月)",
         call="declining_balance_schedule(1000000,'2024-01-01',5,0.400,0.10800,0.500)",
         cost=1000000, residual=R_MEMO,
         expected=[(2024, 400000, 600000), (2025, 240000, 360000), (2026, 144000, 216000),
                   (2027, 108000, 108000), (2028, 107999, 1)]),
    dict(name="定率法_5年_100万円_期中(7月)",
         call="declining_balance_schedule(1000000,'2024-07-01',5,0.400,0.10800,0.500)",
         cost=1000000, residual=R_MEMO,
         expected=[(2024, 200000, 800000), (2025, 320000, 480000), (2026, 192000, 288000),
                   (2027, 115200, 172800), (2028, 86400, 86400), (2029, 86399, 1)]),
    dict(name="定率法_5年_100万円_期末(12月)_★回帰対象",
         call="declining_balance_schedule(1000000,'2024-12-01',5,0.400,0.10800,0.500)",
         cost=1000000, residual=R_MEMO,
         # ★ 期末近く取得でも初年度に誤って改定償却へ切り替わらないことを固定する。
         expected=[(2024, 33333, 966667), (2025, 386666, 580001), (2026, 232000, 348001),
                   (2027, 139200, 208801), (2028, 104400, 104401), (2029, 104400, 1)]),
    dict(name="定率法_5年_1234567円_期首(端数)",
         call="declining_balance_schedule(1234567,'2024-01-01',5,0.400,0.10800,0.500)",
         cost=1234567, residual=R_MEMO,
         expected=[(2024, 493826, 740741), (2025, 296296, 444445), (2026, 177778, 266667),
                   (2027, 133333, 133334), (2028, 133333, 1)]),

    # --- 定額法 ---
    dict(name="定額法_5年_100万円_期首(1月)",
         call="straight_line_schedule(1000000,'2024-01-01',5,0.200)",
         cost=1000000, residual=R_MEMO,
         expected=[(2024, 200000, 800000), (2025, 200000, 600000), (2026, 200000, 400000),
                   (2027, 200000, 200000), (2028, 199999, 1)]),
    dict(name="定額法_5年_1234567円_期首(端数)",
         call="straight_line_schedule(1234567,'2024-01-01',5,0.200)",
         cost=1234567, residual=R_MEMO,
         expected=[(2024, 246913, 987654), (2025, 246913, 740741), (2026, 246913, 493828),
                   (2027, 246913, 246915), (2028, 246913, 2), (2029, 1, 1)]),
    dict(name="定額法_5年_987654円_期首(端数)",
         call="straight_line_schedule(987654,'2024-01-01',5,0.200)",
         cost=987654, residual=R_MEMO,
         expected=[(2024, 197530, 790124), (2025, 197530, 592594), (2026, 197530, 395064),
                   (2027, 197530, 197534), (2028, 197530, 4), (2029, 3, 1)]),

    # --- 境界条件(改善⑦) ---
    dict(name="定額法_耐用年数1年_100万円_期首",
         call="straight_line_schedule(1000000,'2024-01-01',1,1.000)",
         cost=1000000, residual=R_MEMO,
         expected=[(2024, 999999, 1)]),
    dict(name="定額法_5年_取得価額1円_期首(償却対象なし=0行)",
         call="straight_line_schedule(1,'2024-01-01',5,0.200)",
         cost=1, residual=R_MEMO,
         expected=[]),     # 既に備忘1円。償却の余地がないため0行であることを固定。
    dict(name="定額法_5年_100万円_12月31日取得",
         call="straight_line_schedule(1000000,'2024-12-31',5,0.200)",
         cost=1000000, residual=R_MEMO,
         expected=[(2024, 16666, 983334), (2025, 200000, 783334), (2026, 200000, 583334),
                   (2027, 200000, 383334), (2028, 200000, 183334), (2029, 183333, 1)]),
    dict(name="定額法_5年_100万円_うるう年2月29日取得",
         call="straight_line_schedule(1000000,'2024-02-29',5,0.200)",
         cost=1000000, residual=R_MEMO,
         # 月割は「日」でなく「月」基準。うるう日でも 13-2=11か月で計算される。
         expected=[(2024, 183333, 816667), (2025, 200000, 616667), (2026, 200000, 416667),
                   (2027, 200000, 216667), (2028, 200000, 16667), (2029, 16666, 1)]),

    # --- 一括償却(3年均等・備忘価額なし・端数は3年目で吸収) ---
    dict(name="一括償却_20万円(3年均等)",
         call="lump_sum_schedule(200000,2024)", cost=200000, residual=R_ZERO,
         expected=[(2024, 66666, 133334), (2025, 66666, 66668), (2026, 66668, 0)]),
    dict(name="一括償却_10万円(端数)",
         call="lump_sum_schedule(100000,2024)", cost=100000, residual=R_ZERO,
         expected=[(2024, 33333, 66667), (2025, 33333, 33334), (2026, 33334, 0)]),
    dict(name="一括償却_111111円(端数)",
         call="lump_sum_schedule(111111,2024)", cost=111111, residual=R_ZERO,
         expected=[(2024, 37037, 74074), (2025, 37037, 37037), (2026, 37037, 0)]),
]


def fetch(call):
    """スケジュールを (年度, 償却費, 累計, 期末簿価) の整数タプル列で取得する。
    ORDER BY を付けず、関数が返した順序のまま検証する(順序の事故も検出するため)。"""
    rows = db.rows(f"SELECT fiscal_year, depreciation, accumulated, closing_book_value FROM {call}")
    return [tuple(int(x) for x in r) for r in rows]


def check_invariants(name, rows, cost, residual):
    """全ケース共通の会計的不変条件。期待値固定では拾いにくい壊れ方を検出する。"""
    if not rows:
        return   # 0行ケース(取得価額1円等)は期待値[]側で固定済み。
    nonneg = all(d >= 0 for _, d, _, _ in rows)
    mono = dep_id = acc_id = years_seq = True
    prev_close, prev_year = cost, None
    for (year, dep, acc, close) in rows:
        if close > prev_close:            mono = False        # 簿価は増えない
        if dep != prev_close - close:     dep_id = False      # 当年償却 = 期首簿価 - 期末簿価
        if acc + close != cost:           acc_id = False      # 累計償却 + 期末簿価 = 取得価額
        if prev_year is not None and year != prev_year + 1:  years_seq = False
        prev_close, prev_year = close, year
    chk.true(f"{name}: [不変] 償却費は非負", nonneg)
    chk.true(f"{name}: [不変] 簿価は単調非増加", mono)
    chk.true(f"{name}: [不変] 当年償却=期首簿価-期末簿価", dep_id)
    chk.true(f"{name}: [不変] 累計償却+期末簿価=取得価額", acc_id)
    chk.true(f"{name}: [不変] 年度は連続昇順", years_seq)
    chk.true(f"{name}: [不変] 最終簿価>=残存簿価({residual})", rows[-1][3] >= residual)
    chk.true(f"{name}: [不変] Σ償却費=取得価額-最終簿価",
             sum(d for _, d, _, _ in rows) == cost - rows[-1][3])


for c in CASES:
    rows = fetch(c["call"])
    pinned = [(y, d, close) for (y, d, _a, close) in rows]   # (年度, 償却費, 期末簿価)を固定
    chk.eq(c["name"], pinned, c["expected"])
    check_invariants(c["name"], rows, c["cost"], c["residual"])

chk.done("depreciation_regression")
