-- =============================================================================
--  青色申告決算書マッピング層   ※ schema.sql / financial_statements.sql 等を前提
-- =============================================================================
--  目的: エンジンの勘定科目別集計を、青色申告決算書(一般用)の「行項目」へ写像する。
--        これが「決算書を自動入力 → e-Tax取込形式」へ向かう出力側の入口になる。
--  考え方:
--    - 各勘定科目を決算書の行(statement_lines)に対応づける(account_statement_map)。
--    - 損益計算書は 売上原価ブロック(②③④⑤⑥)を期首・期末棚卸から復元して様式化。
--    - 貸借対照表は financial_statements.balance_sheet() を様式の区分に並べ替える。
--    - 青色申告特別控除は所得を超えない範囲でP/Lの所得計算に適用。B/Sには反映しない
--      (B/Sは会計上の当期純利益。控除は税務上の所得計算であり会計B/Sとは別概念)。
--  前提/限界:
--    - 本実装は三分法を前提とする。売上原価対立法・複数仕入勘定では別実装となる。
--    - 出力できるのは青色決算書の『主要行項目』(専従者給与・引当金等は今後)。
-- =============================================================================

-- ---------- 決算書の行定義(様式の固定行。経費は実際はさらに多い) -------------
CREATE TABLE statement_lines (
  code       text PRIMARY KEY,
  label      text NOT NULL,
  statement  text NOT NULL CHECK (statement IN ('PL','BS')),
  section    text NOT NULL,            -- 原価/経費/資産/負債資本 など
  sort_order int  NOT NULL
);
INSERT INTO statement_lines(code,label,statement,section,sort_order) VALUES
 ('COGS','売上原価(差引原価)','PL','原価',0),
 ('TAX','租税公課','PL','経費',1),
 ('FREIGHT','荷造運賃','PL','経費',2),
 ('UTIL','水道光熱費','PL','経費',3),
 ('TRAVEL','旅費交通費','PL','経費',4),
 ('COMM','通信費','PL','経費',5),
 ('AD','広告宣伝費','PL','経費',6),
 ('ENT','接待交際費','PL','経費',7),
 ('INS','損害保険料','PL','経費',8),
 ('REPAIR','修繕費','PL','経費',9),
 ('SUPPLY','消耗品費','PL','経費',10),
 ('DEP','減価償却費','PL','経費',11),
 ('WELFARE','福利厚生費','PL','経費',12),
 ('SALARY','給料賃金','PL','経費',13),
 ('OUTSOURCE','外注工賃','PL','経費',14),
 ('INTEREST','利子割引料','PL','経費',15),
 ('RENT','地代家賃','PL','経費',16),
 ('BADDEBT','貸倒金','PL','経費',17),
 ('MISC','雑費','PL','経費',20);

-- ---------- 勘定科目 → 決算書行 の対応づけ(利用者ごと) ----------------------
CREATE TABLE account_statement_map (
  account_code text PRIMARY KEY,       -- accounts.code
  line_code    text NOT NULL REFERENCES statement_lines(code)
);

-- ---------- 損益計算書(青色決算書の様式に整形) ------------------------------
--  p_opening/p_closing: 期首/期末商品棚卸高(棚卸モジュールの結果を渡す)
--  p_deduction: 青色申告特別控除額(65万/75万等。所得を超えない範囲で適用)
CREATE OR REPLACE FUNCTION aozora_income_statement(
  p_year int, p_opening bigint, p_closing bigint, p_deduction bigint)
RETURNS TABLE(ord int, code text, item text, amount bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sales bigint; v_cogs bigint; v_purchase bigint;
  v_subtotal bigint; v_gross bigint; v_exp_total bigint; v_pre bigint; v_ded bigint;
BEGIN
  SELECT COALESCE(revenue,0) INTO v_sales FROM income_statement_summary(p_year);

  -- ③当期仕入額: COGS科目への当期の借方計から三分法の期首振替分を除く(一次データ優先)
  SELECT COALESCE(SUM(e.amount),0) INTO v_purchase
  FROM entries e
  JOIN transactions t          ON t.id = e.transaction_id
  JOIN accounts a              ON a.id = e.account_id
  JOIN account_statement_map m ON m.account_code = a.code
  WHERE m.line_code = 'COGS' AND e.side = 'debit' AND t.status = 'posted'
    AND t.transaction_date BETWEEN make_date(p_year,1,1) AND make_date(p_year,12,31);
  v_purchase := v_purchase - p_opening;               -- ③仕入金額(期首振替を除いた当期仕入)
  v_cogs     := p_opening + v_purchase - p_closing;   -- ⑥差引原価 = ②+③-⑤(順算で導出)
  v_subtotal := p_opening + v_purchase;               -- ④小計
  v_gross    := v_sales - v_cogs;                     -- ⑦差引金額(売上総利益)

  ord:=10; code:='1';  item:='売上(収入)金額';            amount:=v_sales;    RETURN NEXT;
  ord:=20; code:='2';  item:='期首商品棚卸高';            amount:=p_opening;  RETURN NEXT;
  ord:=30; code:='3';  item:='仕入金額';                  amount:=v_purchase; RETURN NEXT;
  ord:=40; code:='4';  item:='小計(2+3)';                amount:=v_subtotal; RETURN NEXT;
  ord:=50; code:='5';  item:='期末商品棚卸高';            amount:=p_closing;  RETURN NEXT;
  ord:=60; code:='6';  item:='差引原価(4-5)=売上原価';   amount:=v_cogs;     RETURN NEXT;
  ord:=70; code:='7';  item:='差引金額(1-6)=売上総利益'; amount:=v_gross;    RETURN NEXT;

  RETURN QUERY                                          -- 経費明細(COGS以外)
    SELECT 100 + sl.sort_order, ''::text, sl.label, SUM(pl.amount)::bigint
    FROM profit_loss(p_year) pl
    JOIN account_statement_map m ON m.account_code = pl.code
    JOIN statement_lines sl       ON sl.code = m.line_code
    WHERE pl.account_type = 'expense' AND m.line_code <> 'COGS'
    GROUP BY sl.sort_order, sl.label
    ORDER BY sl.sort_order;

  SELECT COALESCE(SUM(pl.amount),0) INTO v_exp_total
  FROM profit_loss(p_year) pl
  JOIN account_statement_map m ON m.account_code = pl.code
  WHERE pl.account_type = 'expense' AND m.line_code <> 'COGS';

  v_pre := v_gross - v_exp_total;
  v_ded := LEAST(GREATEST(p_deduction,0), GREATEST(v_pre,0));   -- 控除は所得を超えない

  ord:=300; code:=''; item:='経費計';                       amount:=v_exp_total;     RETURN NEXT;
  ord:=310; code:=''; item:='差引金額(7-経費計)';          amount:=v_pre;           RETURN NEXT;
  ord:=320; code:=''; item:='青色申告特別控除前の所得金額'; amount:=v_pre;           RETURN NEXT;
  ord:=330; code:=''; item:='青色申告特別控除額';           amount:=v_ded;           RETURN NEXT;
  ord:=340; code:=''; item:='所得金額';                     amount:=v_pre - v_ded;   RETURN NEXT;
END;
$$;

-- ---------- 貸借対照表(様式の区分に並べ替え) --------------------------------
CREATE OR REPLACE FUNCTION aozora_balance_sheet(p_asof date)
RETURNS TABLE(part text, item text, amount bigint)
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN bs.section = '資産' THEN '資産の部' ELSE '負債・資本の部' END,
         CASE WHEN bs.line_name = '当期純利益'
              THEN '青色申告特別控除前の所得金額' ELSE bs.line_name END,   -- 様式のB/S行名へ
         bs.amount
  FROM balance_sheet(p_asof) bs
  ORDER BY CASE WHEN bs.section = '資産' THEN 0 ELSE 1 END, bs.line_name
$$;
