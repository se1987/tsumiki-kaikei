# 消費税の集計テスト(tax_categories.sql / consumption_tax.sql)
#  実行: pip install pgserver && python tests/test_consumption_tax.py
#  正常系: 借方/貸方を符号として扱い、返品・取消・逆仕訳が課税売上/仕入税額控除を
#          正しく「減らす」こと(tax_sign)。
#  異常系: entries の金額3点整合性(税抜+税額=税込)と、非課税明細が税額を持てないこと。
from _harness import DB, Checker

db = DB(["schema.sql", "financial_statements.sql", "tax_categories.sql", "consumption_tax.sql"])
chk = Checker(db)

db.rows("""
INSERT INTO accounts(code,name,account_type,default_tax_code) VALUES
  ('CASH','現金','asset','OUTSIDE'),
  ('SALES','売上高','revenue','SALE_TAX10'),
  ('PUR','仕入高','expense','PUR_TAX10');
""")


def split(a, pct):
    if not pct:
        return "NULL,NULL"
    t = a * pct // (100 + pct)
    return f"{a - t},{t}"


def tx(desc, date, lines):
    """lines: (code, side, amount, invoice, pct)。ヘッダ→明細(複数行を1文で)の順で投入。"""
    db.rows(f"INSERT INTO transactions(transaction_date,description,status) "
            f"VALUES('{date}','{desc}','posted')")
    vals = []
    for code, side, amt, inv, pct in lines:
        vals.append(
            f"((SELECT id FROM transactions WHERE description='{desc}'),"
            f"(SELECT id FROM accounts WHERE code='{code}'),'{side}',{amt},{split(amt, pct)},'{inv}')")
    db.rows("INSERT INTO entries(transaction_id,account_id,side,amount,base_amount,tax_amount,invoice_status) "
            "VALUES " + ",".join(vals))


# ---------- 売上: 計上(貸方,税額300,000)→ 返品(借方,税額100,000) ----------
tx('受託売上', '2024-06-30',
   [('CASH', 'debit', 3300000, '対象外', None), ('SALES', 'credit', 3300000, '対象外', 10)])
tx('受託売上の返品', '2024-07-10',
   [('SALES', 'debit', 1100000, '対象外', 10), ('CASH', 'credit', 1100000, '対象外', None)])

# ---------- 課税仕入(適格): 計上(借方,税額200,000)→ 返品(貸方,税額50,000) ----------
tx('仕入', '2024-08-01',
   [('PUR', 'debit', 2200000, '適格', 10), ('CASH', 'credit', 2200000, '対象外', None)])
tx('仕入の返品', '2024-08-20',
   [('CASH', 'debit', 550000, '対象外', None), ('PUR', 'credit', 550000, '適格', 10)])

# ---------- 課税仕入(非適格・経過措置80%): 計上(税額100,000)→ 返品(税額50,000) ----------
tx('外注(非適格)', '2024-03-01',
   [('PUR', 'debit', 1100000, '非適格', 10), ('CASH', 'credit', 1100000, '対象外', None)])
tx('外注(非適格)の返品', '2024-04-01',
   [('CASH', 'debit', 550000, '対象外', None), ('PUR', 'credit', 550000, '非適格', 10)])

# (正常系) 売上税額 = 300,000(貸方) − 100,000(借方の返品) = 200,000
chk.eq("output_tax: 返品(借方)が課税売上を減らす",
       db.icol("SELECT output_tax(2024)"), [200000])

# (正常系) 仕入税額控除(全額) = 200,000(借方) − 50,000(貸方の返品) = 150,000
chk.eq("input_tax_full: 返品(貸方)が仕入税額控除を減らす",
       db.icol("SELECT input_tax_full(2024)"), [150000])

# (正常系) 経過措置(非適格80%) = floor(100,000*0.8) − floor(50,000*0.8) = 80,000 − 40,000 = 40,000
chk.eq("input_tax_transitional: 非適格の返品も経過措置率で減算",
       db.icol("SELECT input_tax_transitional(2024)"), [40000])

# (正常系) tax_summary の税額も正味(売上=200,000 / 仕入適格=150,000)
chk.eq("tax_summary: 売上(SALE_TAX10)の税額は正味200,000",
       db.icol("SELECT tax_amount::int FROM tax_summary('2024-01-01','2024-12-31') "
               "WHERE code='SALE_TAX10'"), [200000])

# (正常系) 逆仕訳で売上を全額取り消すと課税売上は 0 になる(符号で相殺)
tx('全額売上', '2024-09-01',
   [('CASH', 'debit', 1100000, '対象外', None), ('SALES', 'credit', 1100000, '対象外', 10)])
tx('全額売上の逆仕訳', '2024-09-02',
   [('SALES', 'debit', 1100000, '対象外', 10), ('CASH', 'credit', 1100000, '対象外', None)])
chk.eq("逆仕訳で当該売上の税額は相殺され output_tax は据え置き",
       db.icol("SELECT output_tax(2024)"), [200000])

# ====================================================================
#  entries の金額3点整合性(Finding: base_amount/tax_amount の整合性)
# ====================================================================
db.rows("INSERT INTO transactions(transaction_date,description,status) VALUES('2024-10-01','整合性検査','draft')")
TID = db.scalar("SELECT id FROM transactions WHERE description='整合性検査'")
SALES_ID = db.scalar("SELECT id FROM accounts WHERE code='SALES'")

# (異常系) 税抜+税額 ≠ 税込 は CHECK 違反
chk.error("base+tax≠amount は CHECK 違反",
          f"INSERT INTO entries(transaction_id,account_id,side,amount,base_amount,tax_amount) "
          f"VALUES({TID},{SALES_ID},'credit',110,100,5)",
          "entries_tax_amounts_consistent", sqlstate="23514")

# (異常系) 税抜だけ・税額だけの片方入力も CHECK 違反(両方NULLか両方必須)
chk.error("税抜だけ入力(税額NULL)は CHECK 違反",
          f"INSERT INTO entries(transaction_id,account_id,side,amount,base_amount) "
          f"VALUES({TID},{SALES_ID},'credit',110,100)",
          "entries_tax_amounts_consistent", sqlstate="23514")

# (異常系) 非課税(PUR_NONTAX)の明細が消費税額を持つのはトリガ違反(税抜+税額=税込は満たす)
chk.error("非課税明細が税額を持つのは拒否",
          f"INSERT INTO entries(transaction_id,account_id,side,amount,base_amount,tax_amount,tax_category_code) "
          f"VALUES({TID},{SALES_ID},'credit',300,200,100,'PUR_NONTAX')",
          "消費税額を持てません", sqlstate="P0001")

chk.done("consumption_tax")
