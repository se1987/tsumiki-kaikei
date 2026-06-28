# 中核スキーマの制約・派生列・ビューのテスト(schema.sql)
#  実行: pip install pgserver && python tests/test_schema_constraints.py
#  正常系: 貸借一致した posted 仕訳の登録 / normal_balance 生成列 / transaction_search 集計
#          / filing_deadlines の休日順延の不変条件
#  異常系: posted の貸借不一致(遅延制約) / amount<=0 / audit_logs の追記専用(更新・削除禁止)
from _harness import DB, Checker

db = DB(["schema.sql"])
chk = Checker(db)

# ---------- 勘定科目: normal_balance は account_type からの生成列 ----------
db.rows("""
INSERT INTO accounts(code,name,account_type) VALUES
  ('CASH','現金','asset'),
  ('SALES','売上高','revenue'),
  ('EXP','消耗品費','expense'),
  ('LOAN','借入金','liability');
""")
chk.eq("normal_balance: 資産=借方/費用=借方/収益=貸方/負債=貸方",
       db.col("SELECT normal_balance FROM accounts "
              "WHERE code IN ('CASH','EXP','SALES','LOAN') ORDER BY code"),
       # CASH, EXP, LOAN, SALES の順(コード昇順)
       ["debit", "debit", "credit", "credit"])

# ---------- (正常系) 貸借一致した posted 仕訳は登録できる ----------
db.rows("""
BEGIN;
WITH t AS (
  INSERT INTO transactions(transaction_date, counterparty, description, status)
  VALUES ('2024-05-01','顧客A','売上計上','posted') RETURNING id)
INSERT INTO entries(transaction_id, account_id, side, amount)
SELECT t.id, a.id, s.side::balance_side, 10000
FROM t, accounts a
JOIN (VALUES ('CASH','debit'),('SALES','credit')) s(code,side) ON s.code = a.code;
COMMIT;
""")
chk.eq("貸借一致 posted 仕訳が1件登録される",
       db.icol("SELECT count(*)::int FROM transactions WHERE status='posted'"), [1])

# (正常系) transaction_search は伝票単位の借方合計を返す。
chk.eq("transaction_search の取引金額=借方合計(10000)",
       db.icol("SELECT total_amount::int FROM transaction_search WHERE counterparty='顧客A'"),
       [10000])

# ---------- (異常系) posted で貸借不一致 → コミット時に遅延制約で停止 ----------
chk.error("posted の貸借不一致はコミット時に拒否", """
BEGIN;
WITH t AS (
  INSERT INTO transactions(transaction_date, description, status)
  VALUES ('2024-06-01','片落ち','posted') RETURNING id)
INSERT INTO entries(transaction_id, account_id, side, amount)
SELECT t.id, a.id, 'debit', 5000 FROM t, accounts a WHERE a.code='CASH';
COMMIT;
""", "貸借不一致")

# ---------- (異常系) entries.amount は正数のみ ----------
db.rows("INSERT INTO transactions(transaction_date,status) VALUES ('2024-07-01','draft')")
chk.error("amount<=0 は CHECK 違反",
          "INSERT INTO entries(transaction_id,account_id,side,amount) "
          "SELECT (SELECT max(id) FROM transactions), a.id,'debit',0 "
          "FROM accounts a WHERE a.code='CASH'",
          "amount")

# ---------- (異常系) audit_logs は追記専用(UPDATE/DELETE 禁止) ----------
#  ここまでの INSERT 群で audit_logs には行が存在する。
chk.true("audit_logs に記録が存在する",
         int(db.scalar("SELECT count(*) FROM audit_logs")) > 0)
chk.error("audit_logs の UPDATE は禁止",
          "UPDATE audit_logs SET changed_by='x' WHERE id=(SELECT min(id) FROM audit_logs)",
          "追記専用")
chk.error("audit_logs の DELETE は禁止",
          "DELETE FROM audit_logs WHERE id=(SELECT min(id) FROM audit_logs)",
          "追記専用")

# ---------- (正常系/不変条件) 申告期限は休日順延後、土日にならない ----------
chk.eq("filing_deadlines: 実際の申告期限は土日でない",
       db.col("SELECT DISTINCT actual_weekday FROM filing_deadlines "
              "WHERE actual_weekday IN ('土','日')"),
       [])
chk.eq("filing_deadlines: 法定期限は翌年3/15(2024年分)",
       db.col("SELECT statutory_date::text FROM filing_deadlines WHERE tax_year=2024"),
       ["2025-03-15"])

chk.done("schema_constraints")
