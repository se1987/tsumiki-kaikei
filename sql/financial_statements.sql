-- =============================================================================
--  青色決算書(P/L・B/S)集計レイヤ   ※ schema.sql を先に適用すること
-- =============================================================================
--  設計の核:
--    - P/L = 収益・費用(フロー勘定)を「会計年度」で集計したもの
--    - B/S = 資産・負債・純資産(ストック勘定)を「期末時点」で集計したもの
--    - 両者は「当期純利益(=青色申告特別控除前の所得金額)」で必ず一致する
--      (資産 = 負債 + 純資産 + 当期純利益)。これが複式簿記の自己検証性。
--
--  【この層の責務の境界】
--    ここは "posted の仕訳を集計するだけ"。減価償却費・家事按分・棚卸・引当金・
--    青色申告特別控除額の決定といった「税務判断」は、決算整理仕訳として事前に
--    posted されている前提。税ロジック(=元税務職の強みが出る所)はその仕訳を
--    生成する上流に住んでいて、この集計層には持ち込まない。
--    なお B/S が表示するのは「青色申告特別控除前」の所得。控除の適用は申告書側。
-- =============================================================================

-- ---------- 残高の基礎: 勘定ごとの「自然残高」(指定日までの累計) --------------
-- account_type で借方正/貸方正を吸収する。資産・費用=借方残、それ以外=貸方残。
CREATE OR REPLACE FUNCTION account_balance(p_asof date)
RETURNS TABLE(account_id bigint, code text, name text,
              account_type account_type, balance bigint)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code, a.name, a.account_type,
         CASE WHEN a.account_type IN ('asset','expense')
              THEN COALESCE(SUM(m.amount) FILTER (WHERE m.side = 'debit'),  0)
                 - COALESCE(SUM(m.amount) FILTER (WHERE m.side = 'credit'), 0)
              ELSE COALESCE(SUM(m.amount) FILTER (WHERE m.side = 'credit'), 0)
                 - COALESCE(SUM(m.amount) FILTER (WHERE m.side = 'debit'),  0)
         END
  FROM accounts a
  LEFT JOIN (
    SELECT e.account_id, e.side, e.amount
    FROM entries e
    JOIN transactions t ON t.id = e.transaction_id
    WHERE t.status = 'posted' AND t.transaction_date <= p_asof
  ) m ON m.account_id = a.id
  GROUP BY a.id, a.code, a.name, a.account_type
$$;

-- ---------- 損益計算書(P/L): 会計年度内の収益・費用フロー ---------------------
CREATE OR REPLACE FUNCTION profit_loss(p_year int)
RETURNS TABLE(code text, name text, account_type account_type, amount bigint)
LANGUAGE sql STABLE AS $$
  SELECT a.code, a.name, a.account_type,
         CASE WHEN a.account_type = 'expense'
              THEN COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'debit'),  0)
                 - COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'credit'), 0)
              ELSE COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'credit'), 0)
                 - COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'debit'),  0)
         END AS amount
  FROM accounts a
  JOIN entries e      ON e.account_id = a.id
  JOIN transactions t ON t.id = e.transaction_id
  WHERE a.account_type IN ('revenue','expense')
    AND t.status = 'posted'
    AND t.transaction_date >= make_date(p_year, 1, 1)
    AND t.transaction_date <= make_date(p_year, 12, 31)
  GROUP BY a.code, a.name, a.account_type
$$;

CREATE OR REPLACE FUNCTION income_statement_summary(p_year int)
RETURNS TABLE(revenue bigint, expense bigint, income_before_deduction bigint)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(amount) FILTER (WHERE account_type = 'revenue'), 0),
         COALESCE(SUM(amount) FILTER (WHERE account_type = 'expense'), 0),
         COALESCE(SUM(amount) FILTER (WHERE account_type = 'revenue'), 0)
       - COALESCE(SUM(amount) FILTER (WHERE account_type = 'expense'), 0)
  FROM profit_loss(p_year)
$$;

-- ---------- 貸借対照表(B/S): 期末時点のストック + 当期純利益 ------------------
-- 決算振替を切らない方式。純資産に会計上の「当期純利益」を明示計上して資産=負債+純資産
-- を成立させる。青色申告特別控除は税務上の所得計算で適用されB/Sには反映しない
-- (様式のB/S表示名『青色申告特別控除前の所得金額』への読み替えは出力層で行う)。
CREATE OR REPLACE FUNCTION balance_sheet(p_asof date)
RETURNS TABLE(section text, line_name text, amount bigint)
LANGUAGE sql STABLE AS $$
  SELECT CASE ab.account_type
           WHEN 'asset'     THEN '資産'
           WHEN 'liability' THEN '負債'
           WHEN 'equity'    THEN '純資産'
         END,
         ab.name, ab.balance
  FROM account_balance(p_asof) ab
  WHERE ab.account_type IN ('asset','liability','equity')
    AND ab.balance <> 0
  UNION ALL
  SELECT '純資産', '当期純利益',
         COALESCE((SELECT SUM(CASE WHEN account_type = 'revenue' THEN amount
                                   WHEN account_type = 'expense' THEN -amount END)
                   FROM profit_loss(EXTRACT(YEAR FROM p_asof)::int)), 0)
$$;

-- 検算: 資産合計 と 負債+純資産合計 が一致するか(複式簿記の自己検証)
CREATE OR REPLACE FUNCTION balance_sheet_summary(p_asof date)
RETURNS TABLE(asset_total bigint, liability_equity_total bigint, balanced boolean)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(amount) FILTER (WHERE section = '資産'), 0),
         COALESCE(SUM(amount) FILTER (WHERE section IN ('負債','純資産')), 0),
         COALESCE(SUM(amount) FILTER (WHERE section = '資産'), 0)
       = COALESCE(SUM(amount) FILTER (WHERE section IN ('負債','純資産')), 0)
  FROM balance_sheet(p_asof)
$$;
