-- =============================================================================
--  消費税エンジン(本則/簡易/2割・3割特例)   ※ tax_categories.sql を前提
-- =============================================================================
--  流れ: tax_base_summary → consumption_tax_worksheet(申告書中間表) → 各方式の納付税額
--  改正に弱い「率・期間」はコードに埋め込まず tax_relief_rules テーブルで管理する
--  (令和8年度改正で経過措置スケジュールが80→70→50→30→0%に変わった実例があるため)。
--
--  制度(国税庁・令和8年度税制改正特集、2026-06時点で確認):
--    - 経過措置(免税事業者等からの課税仕入の控除割合・7・5・3割控除、取引日で判定):
--        〜R8/9=80%, R8/10〜R10/9=70%, R10/10〜R12/9=50%, R12/10〜R13/9=30%, R13/10〜=0%
--    - 2割特例: 個人は令和8年分まで。納付=売上税額×20%。基準期間課税売上1,000万円以下等。
--    - 3割特例(改正で新設・個人のみ): 令和9・10年分。納付=売上税額×30%。
--    - みなし仕入率(簡易課税): 1種90/2種80/3種70/4種60/5種50/6種40 [%]。
--  簡略化(正直な注釈):
--    - 本則は課税売上割合95%以上・全額控除前提。個別対応方式/一括比例配分方式は未実装。
--    - 国税7.8%(軽減6.24%)/地方の分離、課税標準の千円未満・差引税額の百円未満切捨は未実装
--      (合算税率10%/8%で算定)。簡易課税は単一みなし率前提(複数事業区分の加重平均は今後)。
--    - 経過措置の「一の免税事業者から年1億円超は対象外」(R8/10〜)は未実装。
-- =============================================================================

-- ---------- 税制特例マスタ(率・期間をデータ管理。改正は行追加/更新で吸収) -----
CREATE TABLE tax_relief_rules (
  rule_type  text NOT NULL CHECK (rule_type IN ('keizo','special')),  -- 経過措置 / 特例
  label      text NOT NULL,
  start_date date NOT NULL,
  end_date   date,                       -- NULL = 期限なし
  rate       numeric NOT NULL,           -- keizo:控除割合 / special:納付率
  applies_to text NOT NULL DEFAULT 'all' CHECK (applies_to IN ('all','individual')),
  note       text
);
INSERT INTO tax_relief_rules(rule_type,label,start_date,end_date,rate,applies_to,note) VALUES
 ('keizo','経過措置80%','2023-10-01','2026-09-30',0.80,'all',''),
 ('keizo','経過措置70%','2026-10-01','2028-09-30',0.70,'all','令和8年度改正で新設'),
 ('keizo','経過措置50%','2028-10-01','2030-09-30',0.50,'all',''),
 ('keizo','経過措置30%','2030-10-01','2031-09-30',0.30,'all','令和8年度改正で新設'),
 ('keizo','経過措置0%', '2031-10-01',NULL,        0.00,'all','控除なし'),
 ('special','2割特例','2023-01-01','2026-12-31',0.20,'individual','令和5〜8年分'),
 ('special','3割特例','2027-01-01','2028-12-31',0.30,'individual','改正で新設・個人のみ');
COMMENT ON TABLE tax_relief_rules IS '消費税の経過措置(控除割合)と特例(2割/3割)の率・期間をデータ管理。制度改正はこの表の更新で吸収し、計算ロジックは触らない。';

-- ---------- 経過措置率(取引日で判定。マスタ参照) ----------------------------
CREATE OR REPLACE FUNCTION keizo_measure_rate(p_date date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT rate FROM tax_relief_rules
                   WHERE rule_type='keizo'
                     AND p_date >= start_date AND (end_date IS NULL OR p_date <= end_date)
                   ORDER BY start_date DESC LIMIT 1), 1.0)   -- 制度開始前は全額
$$;

-- ---------- 特例(年分で2割/3割を判定。マスタ参照) --------------------------
CREATE OR REPLACE FUNCTION special_relief(p_year int)
RETURNS TABLE(label text, rate numeric)
LANGUAGE sql STABLE AS $$
  SELECT label, rate FROM tax_relief_rules
  WHERE rule_type='special' AND make_date(p_year,7,1) BETWEEN start_date AND end_date
  ORDER BY start_date DESC LIMIT 1
$$;

-- ---------- 売上税額・仕入税額控除(証憑区分で全額/経過措置を振り分け) --------
CREATE OR REPLACE FUNCTION output_tax(p_year int)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(COALESCE(e.tax_amount, s.tax_amount) * tax_sign(tc.applies_to, e.side)),0)::bigint
  FROM entries e
  JOIN transactions t ON t.id=e.transaction_id AND t.status='posted'
                     AND t.transaction_date BETWEEN make_date(p_year,1,1) AND make_date(p_year,12,31)
  JOIN accounts a        ON a.id=e.account_id
  JOIN tax_categories tc ON tc.code=COALESCE(e.tax_category_code,a.default_tax_code,'OUTSIDE')
  CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) s
  WHERE tc.applies_to='sale' AND tc.affects_output_tax
$$;

-- 全額控除(適格・少額特例・公共交通・自販機・従業員旅費)
CREATE OR REPLACE FUNCTION input_tax_full(p_year int)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(COALESCE(e.tax_amount, s.tax_amount) * tax_sign(tc.applies_to, e.side)),0)::bigint
  FROM entries e
  JOIN transactions t ON t.id=e.transaction_id AND t.status='posted'
                     AND t.transaction_date BETWEEN make_date(p_year,1,1) AND make_date(p_year,12,31)
  JOIN accounts a        ON a.id=e.account_id
  JOIN tax_categories tc ON tc.code=COALESCE(e.tax_category_code,a.default_tax_code,'OUTSIDE')
  CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) s
  WHERE tc.applies_to='purchase' AND tc.kind='taxable'
    AND e.invoice_status IN ('適格','少額特例','公共交通','自販機','従業員旅費')
$$;

-- 経過措置(非適格)。取引日の経過措置率を乗じる
CREATE OR REPLACE FUNCTION input_tax_transitional(p_year int)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(tax_sign(tc.applies_to, e.side)
                      * floor(COALESCE(e.tax_amount, s.tax_amount)
                              * keizo_measure_rate(t.transaction_date))::bigint),0)::bigint
  FROM entries e
  JOIN transactions t ON t.id=e.transaction_id AND t.status='posted'
                     AND t.transaction_date BETWEEN make_date(p_year,1,1) AND make_date(p_year,12,31)
  JOIN accounts a        ON a.id=e.account_id
  JOIN tax_categories tc ON tc.code=COALESCE(e.tax_category_code,a.default_tax_code,'OUTSIDE')
  CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) s
  WHERE tc.applies_to='purchase' AND tc.kind='taxable' AND e.invoice_status='非適格'
$$;

-- ---------- 申告書中間表(様式や税率が変わっても安定する中間層) ---------------
CREATE OR REPLACE FUNCTION consumption_tax_worksheet(p_year int)
RETURNS TABLE(line text, amount bigint, note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE r record; v_out bigint; v_full bigint; v_trans bigint;
BEGIN
  FOR r IN SELECT box, rate, SUM(base_amount) b, SUM(tax_amount) t
           FROM tax_base_summary(p_year)
           WHERE box IN ('課税売上','輸出売上','非課税売上')
           GROUP BY box, rate ORDER BY box, rate LOOP
    line := r.box || COALESCE('('||(r.rate*100)::int||'%)','');
    amount := r.t; note := '税抜 '||r.b; RETURN NEXT;
  END LOOP;

  v_out:=output_tax(p_year); v_full:=input_tax_full(p_year); v_trans:=input_tax_transitional(p_year);
  line:='売上税額 計';                       amount:=v_out;          note:=''; RETURN NEXT;
  line:='課税仕入 控除(適格等・全額)';        amount:=v_full;         note:='適格/少額特例/公共交通等'; RETURN NEXT;
  line:='課税仕入 控除(非適格・経過措置後)';  amount:=v_trans;        note:='取引日の経過措置率を適用'; RETURN NEXT;
  line:='仕入税額控除 計';                    amount:=v_full+v_trans; note:=''; RETURN NEXT;
  line:='課税売上割合(簡易)';                 amount:=NULL;
    note := taxable_sales_ratio_simple(make_date(p_year,1,1), make_date(p_year,12,31))::text; RETURN NEXT;
END;
$$;

-- ---------- 3方式の納付税額を一覧(中間表の値を使用) --------------------------
CREATE OR REPLACE FUNCTION consumption_tax_compare(p_year int, p_deemed_rate numeric)
RETURNS TABLE(method text, payable bigint, note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_out bigint; v_credit bigint; v_ratio numeric; sp record;
BEGIN
  v_out    := output_tax(p_year);
  v_credit := input_tax_full(p_year) + input_tax_transitional(p_year);
  v_ratio  := taxable_sales_ratio_simple(make_date(p_year,1,1), make_date(p_year,12,31));

  method:='本則課税'; payable:=v_out - v_credit;
    note:='売上税額'||v_out||'−控除'||v_credit
        ||CASE WHEN v_ratio < 0.95 THEN ' ※課税売上割合95%未満:個別対応/一括比例が必要(未実装)'
               ELSE ' (課税売上割合95%以上・全額控除前提)' END;
    RETURN NEXT;

  IF p_deemed_rate IS NOT NULL THEN
    method:='簡易課税'; payable:=v_out - floor(v_out*p_deemed_rate)::bigint;
      note:='売上税額×(1−みなし'||(p_deemed_rate*100)::int||'%)・単一区分前提'; RETURN NEXT;
  END IF;

  FOR sp IN SELECT * FROM special_relief(p_year) LOOP
    method:=sp.label; payable:=floor(v_out*sp.rate)::bigint;
      note:='売上税額×'||(sp.rate*100)::int||'%(要件: 基準期間課税売上1000万円以下等)'; RETURN NEXT;
  END LOOP;
END;
$$;
