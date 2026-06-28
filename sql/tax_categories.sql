-- =============================================================================
--  税区分マスタ(消費税・インボイスの土台)   ※ schema.sql / financial_statements.sql 前提
-- =============================================================================
--  消費税エンジンの流れ:
--    仕訳 → 試算表 → 税区分集計(tax_summary) → 申告基礎数値(tax_base_summary)
--         → 本則課税 / 簡易課税 / 2割特例
--  本ファイルは「税区分集計」と「申告基礎数値の中間層」までを担う。税額計算(割戻し/
--  積上げ・経過措置の率・みなし仕入率・2割特例)は次段の消費税エンジン。
--
--  設計思想(レビュー反映):
--    - 税区分は「税率」ではなく「申告書への集計ルール」。区分自身が
--      applies_to(売上/仕入) と affects_output_tax / affects_input_tax を持つ。
--      → 売上か仕入かを科目タイプで近似しない。固定資産売却(課税売上)、租税公課
--        (課税仕入でない)等の厄介な論点に強くなる。
--    - 科目に既定区分、仕訳で上書き。対の科目(現金・売掛金)は OUTSIDE で集計から除外。
--    - 金額は amount(税込) / base_amount(税抜) / tax_amount(税額) の3点で保持し、
--      端数(割戻し時の100円未満等)を保存時に確定させる。
--    - インボイスは適格/非適格に加え、少額特例・帳簿のみ保存も区別できる文字列区分。
-- =============================================================================

-- ---------- 税区分マスタ:申告書への集計ルールを保持 --------------------------
CREATE TABLE tax_categories (
  code               text PRIMARY KEY,
  name               text NOT NULL,
  applies_to         text NOT NULL CHECK (applies_to IN ('sale','purchase','common')),
  kind               text NOT NULL CHECK (kind IN ('taxable','export','nontaxable','outside')),
  rate               numeric(4,3),               -- 0.100 / 0.080 / 0.000 / NULL
  affects_output_tax boolean NOT NULL,            -- 課税売上(課税資産の譲渡等)へ集計するか
  affects_input_tax  boolean NOT NULL,            -- 課税仕入へ集計するか(仕入税額控除の対象)
  sort_order         int NOT NULL
);
INSERT INTO tax_categories(code,name,applies_to,kind,rate,affects_output_tax,affects_input_tax,sort_order) VALUES
 ('SALE_TAX10','課税売上10%(標準)','sale',    'taxable',   0.100, true,  false, 1),
 ('SALE_TAX8', '課税売上8%(軽減)', 'sale',    'taxable',   0.080, true,  false, 2),
 ('SALE_EXP0', '輸出免税売上0%',   'sale',    'export',    0.000, true,  false, 3),
 ('SALE_NONTAX','非課税売上',      'sale',    'nontaxable',NULL,  false, false, 4),
 ('PUR_TAX10', '課税仕入10%(標準)','purchase','taxable',   0.100, false, true,  5),
 ('PUR_TAX8',  '課税仕入8%(軽減)', 'purchase','taxable',   0.080, false, true,  6),
 ('PUR_NONTAX','非課税仕入',       'purchase','nontaxable',NULL,  false, false, 7),
 ('OUTSIDE',   '不課税(対象外)',   'common',  'outside',   NULL,  false, false, 8);
COMMENT ON TABLE tax_categories IS '消費税の税区分マスタ。税率ではなく「申告書への集計ルール」として設計(applies_to・affects_output_tax・affects_input_tax)。売上か仕入かを科目タイプで判定しない。';

-- ---------- 科目に既定区分、仕訳で上書き＋金額3点＋インボイス区分 ------------
ALTER TABLE accounts ADD COLUMN default_tax_code text REFERENCES tax_categories(code);

ALTER TABLE entries DROP COLUMN tax,
                    DROP COLUMN tax_rate,
                    DROP COLUMN qualified_invoice;
ALTER TABLE entries ADD COLUMN tax_category_code text REFERENCES tax_categories(code), -- 科目既定の上書き
                    ADD COLUMN base_amount bigint,   -- 税抜
                    ADD COLUMN tax_amount  bigint,   -- 消費税額(保存時に確定、端数対策)
                    ADD COLUMN invoice_status text NOT NULL DEFAULT '対象外'
                        CHECK (invoice_status IN ('適格','非適格','少額特例','公共交通','自販機','従業員旅費','対象外'));
CREATE INDEX idx_entries_tax ON entries (tax_category_code);
COMMENT ON COLUMN entries.tax_category_code IS '税区分の上書き。NULLなら科目の既定、それもなければOUTSIDE。';
COMMENT ON COLUMN entries.invoice_status IS '課税仕入の証憑区分。適格/少額特例/公共交通/自販機/従業員旅費=帳簿等で全額控除、非適格=経過措置、対象外=売上側や不課税。「帳簿のみ」を具体的特例に細分化。';

-- ---------- 金額3点(税込/税抜/税額)の整合性をDBで担保 ----------------------
--  下流(tax_summary/output_tax 等)は明示の base_amount/tax_amount を優先して集計する
--  ため、1行の入力ミスがそのまま消費税計算に出る。税抜+税額=税込 を制約で保証する。
--  両方NULL(=保存時に未確定。集計側が split_tax_inclusive で割戻す)も許可する。
ALTER TABLE entries ADD CONSTRAINT entries_tax_amounts_consistent CHECK (
  (base_amount IS NULL AND tax_amount IS NULL)
  OR (base_amount IS NOT NULL AND tax_amount IS NOT NULL
      AND base_amount >= 0 AND tax_amount >= 0
      AND base_amount + tax_amount = amount)
);

-- 税区分と税額の整合性: 非課税・輸出免税・不課税(対象外)の明細は消費税額を持てない。
--  実効区分(明細の上書き > 科目既定 > OUTSIDE)を解決して検査する。CHECK では科目・税区分
--  への結合ができないためトリガで担保する。
CREATE OR REPLACE FUNCTION check_entry_tax_category() RETURNS trigger AS $$
DECLARE v_kind text;
BEGIN
  SELECT tc.kind INTO v_kind
  FROM tax_categories tc
  WHERE tc.code = COALESCE(NEW.tax_category_code,
                           (SELECT default_tax_code FROM accounts WHERE id = NEW.account_id),
                           'OUTSIDE');
  IF v_kind IN ('nontaxable','export','outside') AND COALESCE(NEW.tax_amount, 0) <> 0 THEN
    RAISE EXCEPTION '税区分 kind=% の明細は消費税額を持てません(tax_amount は 0 か NULL のみ): tax_amount=%',
                    v_kind, NEW.tax_amount;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_entries_tax_category
  BEFORE INSERT OR UPDATE ON entries
  FOR EACH ROW EXECUTE FUNCTION check_entry_tax_category();

-- ---------- 税込→(税抜, 税額) の割戻し(端数切捨て) -------------------------
CREATE OR REPLACE FUNCTION split_tax_inclusive(p_amount bigint, p_rate numeric)
RETURNS TABLE(base_amount bigint, tax_amount bigint)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN COALESCE(p_rate,0)=0 THEN p_amount
              ELSE p_amount - floor(p_amount * p_rate / (1 + p_rate))::bigint END,
         CASE WHEN COALESCE(p_rate,0)=0 THEN 0
              ELSE floor(p_amount * p_rate / (1 + p_rate))::bigint END
$$;

-- ---------- 借方/貸方を符号に変換(返品・取消・逆仕訳を正しく減算する) ----------
--  消費税の集計は金額の絶対値ではなく「正味」で行う必要がある。売上の戻し・仕入の
--  戻し・逆仕訳(voided の相手)は反対側に計上されるため、これを符号で吸収しないと
--  課税売上・仕入税額控除が過大になる。
--    売上 (applies_to='sale')     … 貸方=+1 / 借方=-1(売上の戻しは借方)
--    仕入 (applies_to='purchase') … 借方=+1 / 貸方=-1(仕入の戻しは貸方)
--  common(OUTSIDE 等)は集計対象外のため 0(呼び出し側で kind='outside' を除外済み)。
CREATE OR REPLACE FUNCTION tax_sign(p_applies_to text, p_side balance_side)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_applies_to='sale'     AND p_side='credit' THEN  1
    WHEN p_applies_to='sale'     AND p_side='debit'  THEN -1
    WHEN p_applies_to='purchase' AND p_side='debit'  THEN  1
    WHEN p_applies_to='purchase' AND p_side='credit' THEN -1
    ELSE 0
  END
$$;

-- ---------- 税区分別の明細集計(区分マスタ駆動。科目タイプを使わない) --------
CREATE OR REPLACE FUNCTION tax_summary(p_from date, p_to date)
RETURNS TABLE(side text, code text, name text, kind text, rate numeric, invoice_status text,
              amount bigint, base_amount bigint, tax_amount bigint)
LANGUAGE sql STABLE AS $$
  SELECT CASE tc.applies_to WHEN 'sale' THEN '売上' WHEN 'purchase' THEN '仕入' ELSE '対象外' END,
         tc.code, tc.name, tc.kind, tc.rate, e.invoice_status,
         SUM(e.amount * tax_sign(tc.applies_to, e.side))::bigint,
         SUM(COALESCE(e.base_amount, s.base_amount) * tax_sign(tc.applies_to, e.side))::bigint,
         SUM(COALESCE(e.tax_amount,  s.tax_amount)  * tax_sign(tc.applies_to, e.side))::bigint
  FROM entries e
  JOIN transactions t ON t.id = e.transaction_id AND t.status = 'posted'
                     AND t.transaction_date BETWEEN p_from AND p_to
  JOIN accounts a        ON a.id = e.account_id
  JOIN tax_categories tc ON tc.code = COALESCE(e.tax_category_code, a.default_tax_code, 'OUTSIDE')
  CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) s
  WHERE tc.kind <> 'outside'
  GROUP BY tc.applies_to, tc.code, tc.name, tc.kind, tc.rate, e.invoice_status, tc.sort_order
  ORDER BY tc.applies_to, tc.sort_order, e.invoice_status
$$;

-- ---------- 申告基礎数値の中間層(消費税エンジンの入力。制度改正は計算側だけ差替) -
CREATE OR REPLACE FUNCTION tax_base_summary(p_year int)
RETURNS TABLE(box text, rate numeric, invoice_status text, base_amount bigint, tax_amount bigint)
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN tc.applies_to='sale'     AND tc.kind='taxable'    THEN '課税売上'
              WHEN tc.applies_to='sale'     AND tc.kind='export'     THEN '輸出売上'
              WHEN tc.applies_to='sale'     AND tc.kind='nontaxable' THEN '非課税売上'
              WHEN tc.applies_to='purchase' AND tc.kind='taxable'    THEN '課税仕入'
              WHEN tc.applies_to='purchase' AND tc.kind='nontaxable' THEN '非課税仕入' END,
         tc.rate,
         CASE WHEN tc.applies_to='purchase' AND tc.kind='taxable' THEN e.invoice_status ELSE '対象外' END,
         SUM(COALESCE(e.base_amount, s.base_amount) * tax_sign(tc.applies_to, e.side))::bigint,
         SUM(COALESCE(e.tax_amount,  s.tax_amount)  * tax_sign(tc.applies_to, e.side))::bigint
  FROM entries e
  JOIN transactions t ON t.id = e.transaction_id AND t.status = 'posted'
                     AND t.transaction_date BETWEEN make_date(p_year,1,1) AND make_date(p_year,12,31)
  JOIN accounts a        ON a.id = e.account_id
  JOIN tax_categories tc ON tc.code = COALESCE(e.tax_category_code, a.default_tax_code, 'OUTSIDE')
  CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) s
  WHERE tc.kind <> 'outside'
  GROUP BY 1, 2, 3
  ORDER BY 1, 2, 3
$$;

-- ---------- 課税売上割合(簡易試算) ------------------------------------------
--  簡易試算: 税抜ベースで (課税売上+免税売上)/(課税+免税+非課税売上)。
--  正式には非課税資産の譲渡・有価証券(対価の5%)等の調整が要る。精緻化は消費税エンジンで。
CREATE OR REPLACE FUNCTION taxable_sales_ratio_simple(p_from date, p_to date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT tc.kind, SUM(COALESCE(e.base_amount, sp.base_amount) * tax_sign(tc.applies_to, e.side)) AS amt
    FROM entries e
    JOIN transactions t ON t.id = e.transaction_id AND t.status = 'posted'
                       AND t.transaction_date BETWEEN p_from AND p_to
    JOIN accounts a        ON a.id = e.account_id
    JOIN tax_categories tc ON tc.code = COALESCE(e.tax_category_code, a.default_tax_code, 'OUTSIDE')
    CROSS JOIN LATERAL split_tax_inclusive(e.amount, tc.rate) sp
    WHERE tc.applies_to = 'sale' AND tc.kind IN ('taxable','export','nontaxable')
    GROUP BY tc.kind
  )
  SELECT ROUND(
    COALESCE(SUM(amt) FILTER (WHERE kind IN ('taxable','export')),0)::numeric
    / NULLIF(SUM(amt),0), 4)
  FROM s
$$;
