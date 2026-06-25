# 通しデモ: 個人事業主(フリーランスのエンジニア・第5種)の令和6年(2024)1年分を
# 仕訳→試算表→P/L・B/S→青色決算書→固定資産台帳→消費税(中間表・3方式)まで一気に流す。
# 実行: pip install pgserver --break-system-packages && python demo_run.py
import pgserver, pathlib, tempfile
OUT = str(pathlib.Path(__file__).resolve().parent.parent / "sql") + "/"
db = pgserver.get_server(pathlib.Path(tempfile.mkdtemp(prefix="acctdemo_")))
for f in ["schema.sql","financial_statements.sql","depreciation.sql","household_proration.sql",
          "inventory.sql","aozora_statement.sql","fixed_asset.sql","tax_categories.sql","consumption_tax.sql"]:
    db.psql(pathlib.Path(OUT+f).read_text())

def split(a,pct):  # 税込→(税抜,税額) 整数演算
    if not pct: return a,0
    t=a*pct//(100+pct); return a-t,t

# 勘定科目(税区分の既定値つき)
db.psql("""
INSERT INTO accounts(code,name,account_type,default_tax_code) VALUES
 ('111','普通預金','asset','OUTSIDE'),('130','売掛金','asset','OUTSIDE'),('110','現金','asset','OUTSIDE'),
 ('150','工具器具備品','asset','PUR_TAX10'),('180','減価償却累計額','asset','OUTSIDE'),
 ('190','事業主貸','asset','OUTSIDE'),('310','元入金','equity','OUTSIDE'),
 ('410','売上高','revenue','SALE_TAX10'),
 ('520','通信費','expense','PUR_TAX10'),('530','消耗品費','expense','PUR_TAX10'),
 ('550','旅費交通費','expense','PUR_TAX10'),('560','外注費','expense','PUR_TAX10'),
 ('570','地代家賃','expense','PUR_NONTAX'),('540','減価償却費','expense','OUTSIDE');
-- 青色決算書の経費行マッピング
INSERT INTO account_statement_map(account_code,line_code) VALUES
 ('520','COMM'),('530','SUPPLY'),('550','TRAVEL'),('560','OUTSOURCE'),('570','RENT'),('540','DEP');
""")

def tx(desc,date,lines):
    db.psql("INSERT INTO transactions(transaction_date,description,status) VALUES ('%s','%s','posted');"%(date,desc))
    v=[]
    for code,side,amt,inv,pct in lines:
        bt="NULL,NULL" if pct is None else "%d,%d"%split(amt,pct)
        v.append(f"((SELECT id FROM transactions WHERE description='{desc}'),(SELECT id FROM accounts WHERE code='{code}'),'{side}',{amt},{bt},'{inv}')")
    db.psql("INSERT INTO entries(transaction_id,account_id,side,amount,base_amount,tax_amount,invoice_status) VALUES "+",".join(v)+";")

# --- 期中取引 ---
tx('元入れ','2024-01-01',[('111','debit',1000000,'対象外',None),('310','credit',1000000,'対象外',None)])
tx('受託開発売上(上期)','2024-06-30',[('111','debit',3300000,'対象外',None),('410','credit',3300000,'対象外',10)])
tx('受託開発売上(下期)','2024-12-20',[('130','debit',3300000,'対象外',None),('410','credit',3300000,'対象外',10)])
tx('PC購入','2024-06-15',[('150','debit',300000,'適格',10),('111','credit',300000,'対象外',None)])
tx('通信費(年間)','2024-12-31',[('520','debit',132000,'適格',10),('111','credit',132000,'対象外',None)])
tx('消耗品費','2024-09-01',[('530','debit',55000,'適格',10),('111','credit',55000,'対象外',None)])
tx('旅費交通費(公共交通)','2024-10-01',[('550','debit',33000,'公共交通',10),('111','credit',33000,'対象外',None)])
tx('外注費(非適格の個人へ)','2024-08-01',[('560','debit',220000,'非適格',10),('111','credit',220000,'対象外',None)])
tx('地代家賃(自宅・非課税)','2024-12-31',[('570','debit',1200000,'対象外',None),('111','credit',1200000,'対象外',None)])

# --- 決算整理 ---
# (1) 固定資産台帳に登録 → 全資産の減価償却を自動計上
db.psql("""INSERT INTO fixed_assets(name,asset_account_code,accum_account_code,expense_account_code,
  acquisition_date,service_start_date,acquisition_cost,method,useful_life,rate,business_use_ratio)
  VALUES ('業務用PC','150','180','540','2024-06-15','2024-06-15',300000,'定額法',4,0.250,1.0);""")
db.psql("SELECT post_depreciation(2024,'2024-12-31','190');")
# (2) 家事按分: 自宅家賃は事業40%。家事60%(720,000)を事業主貸へ振替
tx('家事按分(地代家賃 事業40%)','2024-12-31',[('190','debit',720000,'対象外',None),('570','credit',720000,'対象外',None)])

def show(title,sql):
    print("\n"+"="*70+"\n"+title+"\n"+"="*70)
    print(db.psql(sql))

show("① 試算表(合計残高試算表)",
 "SELECT name 科目,debit_total 借方,credit_total 貸方,balance 残高 FROM trial_balance('2024-01-01','2024-12-31') WHERE debit_total<>0 OR credit_total<>0 ORDER BY code;")
show("② 損益計算書(要点)",
 "SELECT * FROM income_statement_summary(2024);")
show("③ 貸借対照表（②の利益が純資産に入り均衡する）",
 """SELECT (SELECT asset_total FROM balance_sheet_summary('2024-12-31')) 資産合計,
        (SELECT amount FROM balance_sheet('2024-12-31') WHERE line_name='元入金') 元入金,
        (SELECT amount FROM balance_sheet('2024-12-31') WHERE line_name='当期純利益') \"当期純利益(=2)\",
        (SELECT liability_equity_total FROM balance_sheet_summary('2024-12-31')) 純資産合計,
        (SELECT balanced FROM balance_sheet_summary('2024-12-31')) 均衡;""")
show("④ 青色決算書(損益・主要行)",
 "SELECT code 欄,item 項目,amount 金額 FROM aozora_income_statement(2024,0,0,650000) ORDER BY ord;")
show("⑤ 固定資産台帳(減価償却費の計算)",
 "SELECT name 名称,method 方法,full_dep 本年償却,business_ratio 事業割合,deductible 必要経費,closing_bv 期末簿価 FROM asset_register(2024);")
show("⑥ 消費税 申告書中間表",
 "SELECT line 項目,amount 税額,note 備考 FROM consumption_tax_worksheet(2024);")
show("⑦ 消費税 3方式の比較(第5種・みなし50%)",
 "SELECT method 方式,payable 納付税額,note 内訳 FROM consumption_tax_compare(2024,0.50);")
print("\n[完了] 仕訳→試算表→決算書→台帳→消費税まで、1シナリオで通しました。")
