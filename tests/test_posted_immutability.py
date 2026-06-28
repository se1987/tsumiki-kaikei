# 確定(posted)済み帳簿の不変性テスト(schema.sql)
#  実行: pip install pgserver && python tests/test_posted_immutability.py
#  真実性(改ざん防止)を「コメント」ではなく「DB制約(トリガ)」で担保していることを検査する。
#   正常系: draft は自由に修正・削除 / posted→voided の取消 / 逆仕訳(新規 posted)
#   異常系: posted の内容UPDATE・DELETE / posted 明細の UPDATE・DELETE
#           / voided の再変更 / posted 取引の DELETE で明細が連鎖削除されないこと
from _harness import DB, Checker

db = DB(["schema.sql"])
chk = Checker(db)

db.rows("""
INSERT INTO accounts(code,name,account_type) VALUES
  ('CASH','現金','asset'),
  ('SALES','売上高','revenue');
""")


def post_txn(desc, date="2024-05-01", amount=10000):
    """貸借一致した posted 仕訳を1件作って id を返す。"""
    db.rows(f"""
    BEGIN;
    WITH t AS (
      INSERT INTO transactions(transaction_date, description, status)
      VALUES ('{date}','{desc}','posted') RETURNING id)
    INSERT INTO entries(transaction_id, account_id, side, amount)
    SELECT t.id, a.id, s.side::balance_side, {amount}
    FROM t, accounts a
    JOIN (VALUES ('CASH','debit'),('SALES','credit')) s(code,side) ON s.code = a.code;
    COMMIT;
    """)
    return db.scalar(f"SELECT id FROM transactions WHERE description='{desc}'")


# ---------- (異常系) posted 取引の内容は書き換えられない ----------
t1 = post_txn("売上計上")
chk.error("posted 取引の内容UPDATEは拒否",
          f"UPDATE transactions SET description='改ざん' WHERE id={t1}",
          "確定済み取引", sqlstate="P0001")
chk.error("posted 取引の DELETE は拒否",
          f"DELETE FROM transactions WHERE id={t1}",
          "削除できません", sqlstate="P0001")

# ---------- (異常系) posted 取引の明細は書き換え・削除できない ----------
chk.error("posted 明細の UPDATE は拒否",
          f"UPDATE entries SET amount=99999 WHERE transaction_id={t1} AND side='debit'",
          "確定済み取引", sqlstate="P0001")
chk.error("posted 明細の DELETE は拒否",
          f"DELETE FROM entries WHERE transaction_id={t1} AND side='credit'",
          "確定済み取引", sqlstate="P0001")

# ---------- (異常系) posted 取引を消しても明細は連鎖削除されない(ON DELETE CASCADE封じ) -
chk.eq("DELETE 拒否後も明細は2件のまま残る",
       db.icol(f"SELECT count(*)::int FROM entries WHERE transaction_id={t1}"), [2])

# ---------- (正常系) 唯一許可される変更: posted -> voided の取消 ----------
db.rows(f"UPDATE transactions SET status='voided' WHERE id={t1}")
chk.eq("posted -> voided の取消は許可される",
       db.col(f"SELECT status FROM transactions WHERE id={t1}"), ["voided"])

# ---------- (異常系) voided は内容も状態も再変更できない / 明細も不変 ----------
chk.error("voided 取引の再変更は拒否",
          f"UPDATE transactions SET description='x' WHERE id={t1}",
          "取消済み取引", sqlstate="P0001")
chk.error("voided 取引の明細 DELETE も拒否",
          f"DELETE FROM entries WHERE transaction_id={t1}",
          "確定済み取引", sqlstate="P0001")

# ---------- (正常系) 訂正の正攻法: 逆仕訳(借貸を入替えた新規 posted)は通る ----------
db.rows("""
BEGIN;
WITH t AS (
  INSERT INTO transactions(transaction_date, description, status)
  VALUES ('2024-05-02','売上計上の取消(逆仕訳)','posted') RETURNING id)
INSERT INTO entries(transaction_id, account_id, side, amount)
SELECT t.id, a.id, s.side::balance_side, 10000
FROM t, accounts a
JOIN (VALUES ('CASH','credit'),('SALES','debit')) s(code,side) ON s.code = a.code;
COMMIT;
""")
chk.eq("逆仕訳(新規 posted)は計上できる",
       db.icol("SELECT count(*)::int FROM transactions WHERE description='売上計上の取消(逆仕訳)'"),
       [1])

# ---------- (正常系) draft は自由に修正・削除できる ----------
db.rows("INSERT INTO transactions(transaction_date,description,status) VALUES('2024-06-01','下書き','draft')")
draft_id = db.scalar("SELECT id FROM transactions WHERE description='下書き'")
db.rows(f"INSERT INTO entries(transaction_id,account_id,side,amount) "
        f"SELECT {draft_id},a.id,'debit',5000 FROM accounts a WHERE code='CASH'")
db.rows(f"UPDATE entries SET amount=6000 WHERE transaction_id={draft_id}")
chk.eq("draft 明細は UPDATE できる",
       db.icol(f"SELECT amount::int FROM entries WHERE transaction_id={draft_id}"), [6000])
db.rows(f"DELETE FROM entries WHERE transaction_id={draft_id}")
chk.eq("draft 明細は DELETE できる",
       db.icol(f"SELECT count(*)::int FROM entries WHERE transaction_id={draft_id}"), [0])
db.rows(f"DELETE FROM transactions WHERE id={draft_id}")
chk.eq("draft 取引は DELETE できる",
       db.icol(f"SELECT count(*)::int FROM transactions WHERE id={draft_id}"), [0])

# ---------- (正常系) draft -> posted への確定は通る ----------
db.rows("INSERT INTO transactions(transaction_date,description,status) VALUES('2024-06-02','確定前','draft')")
fix_id = db.scalar("SELECT id FROM transactions WHERE description='確定前'")
db.rows(f"""
INSERT INTO entries(transaction_id,account_id,side,amount)
SELECT {fix_id}, a.id, s.side::balance_side, 7000
FROM accounts a JOIN (VALUES('CASH','debit'),('SALES','credit')) s(code,side) ON s.code=a.code;
""")
db.rows(f"UPDATE transactions SET status='posted' WHERE id={fix_id}")
chk.eq("draft -> posted の確定は許可される",
       db.col(f"SELECT status FROM transactions WHERE id={fix_id}"), ["posted"])

chk.done("posted_immutability")
