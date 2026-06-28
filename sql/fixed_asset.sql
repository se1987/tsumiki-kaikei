-- =============================================================================
--  固定資産台帳(減価償却の実運用化)   ※ schema.sql / depreciation.sql 等を前提
-- =============================================================================
--  目的: 資産を一度登録すれば、各年の減価償却仕訳を全資産まとめて自動生成する。
--        青色申告決算書3ページ「減価償却費の計算」欄の主要項目に対応する
--        (本年中の償却期間など一部の欄は今後)。
--  税務の要点:
--    - 償却方法ごとに depreciation.sql のスケジュール関数を使い分ける。
--    - 事業専用割合: 償却費の全額で簿価は減るが、必要経費になるのは事業割合分のみ。
--      償却費は全額認識(簿価は全額減る)し、家事分を家事按分と同じ思想で「事業主貸」へ
--      振り替える(経費にしない)。
--        (借)減価償却費[全額] /(貸)減価償却累計額[全額]
--        (借)事業主貸[家事分] /(貸)減価償却費[家事分]
--      ※事業主貸は資本振替勘定(本来は資本系で翌期に元入金へ振替)。ただし青色決算書
--        のB/S様式では資産の部に表示されるため、本実装でも資産区分で扱う。
--    - 償却率・改定償却率・保証率は耐用年数省令の別表値を登録する(要確認)。
--    - 除却・売却(除却損等)は本実装では未対応(今後)。
--    - 償却方法は定額法/定率法/一括償却に対応(asset_schedule が分岐)。少額減価償却
--      資産は即時経費のため償却対象外(台帳に載せない)。判定は depreciation.sql の
--      classify_depreciation を参照。
-- =============================================================================

CREATE TABLE fixed_assets (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name                 text NOT NULL,
  asset_account_code   text NOT NULL,   -- 資産勘定(工具器具備品・車両運搬具 等)
  accum_account_code   text NOT NULL,   -- 減価償却累計額(間接法)
  expense_account_code text NOT NULL,   -- 減価償却費
  acquisition_date     date NOT NULL,   -- 取得日
  service_start_date   date NOT NULL,   -- 事業供用日(償却の起点)
  acquisition_cost     bigint NOT NULL CHECK (acquisition_cost > 0),
  method               text NOT NULL CHECK (method IN ('定額法','定率法','一括償却')),
  useful_life          int,             -- 耐用年数(一括償却では未使用)
  rate                 numeric,         -- 償却率(定額法はNULLで1/n近似可)
  guarantee_rate       numeric,         -- 保証率(定率法)
  revised_rate         numeric,         -- 改定償却率(定率法)
  business_use_ratio   numeric NOT NULL DEFAULT 1.0
                       CHECK (business_use_ratio > 0 AND business_use_ratio <= 1), -- 事業専用割合
  disposal_date        date,            -- 除却・売却日(今後対応)
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fixed_assets IS '固定資産台帳。青色決算書3ページ「減価償却費の計算」欄に対応。登録した資産の償却仕訳を post_depreciation で自動生成する。';

CREATE TRIGGER trg_fa_touch BEFORE UPDATE ON fixed_assets FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_fa_audit AFTER INSERT OR UPDATE OR DELETE ON fixed_assets FOR EACH ROW EXECUTE FUNCTION record_audit();

-- ---------- 固定資産 ↔ 減価償却仕訳 の構造的リンク --------------------------
--  資産と、それが生成した償却仕訳を外部キーで結ぶ(摘要テキスト照合に頼らない)。
--    相互関連性(規則第5条第5項第1号ロ) → 資産↔仕訳を双方向に辿れる
--    冪等性(法令要件ではないが)        → 同一資産×同一年×同一種別を UNIQUE で禁止
CREATE TYPE depreciation_posting_kind AS ENUM ('depreciation','private_transfer');
CREATE TABLE asset_depreciation_postings (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  asset_id       bigint NOT NULL REFERENCES fixed_assets(id),   -- [相互関連性] 資産へ
  transaction_id bigint NOT NULL REFERENCES transactions(id),   -- [相互関連性] 仕訳へ
  fiscal_year    int    NOT NULL,
  kind           depreciation_posting_kind NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (asset_id, fiscal_year, kind)                          -- [冪等性] 二重計上をDBで禁止
);
COMMENT ON TABLE asset_depreciation_postings IS
  '固定資産と償却仕訳をつなぐ中間テーブル。相互関連性を外部キーで、二重計上防止を UNIQUE 制約で担保する。transaction への NO ACTION 外部キーが、計上済み償却仕訳の物理削除も間接的に抑止する。';
CREATE TRIGGER trg_adp_audit
  AFTER INSERT OR UPDATE OR DELETE ON asset_depreciation_postings
  FOR EACH ROW EXECUTE FUNCTION record_audit();

-- ---------- 償却方法ごとにスケジュール関数を使い分けて、全年スケジュールを返す ----
--  償却率は「資産個別の率(fa.rate等) > 別表テーブル(depreciation_rates)」で解決し、
--  どちらにも無ければ実行時に例外で停止する(沈黙の誤計算を防ぐ)。
CREATE OR REPLACE FUNCTION asset_schedule(p_asset_id bigint)
RETURNS TABLE(fiscal_year int, depreciation bigint, closing_book_value bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  fa fixed_assets%ROWTYPE;
  v_rate numeric; v_guar numeric; v_rev numeric;
BEGIN
  SELECT * INTO fa FROM fixed_assets WHERE id = p_asset_id;

  IF fa.method = '定額法' THEN
    SELECT dr.rate INTO v_rate FROM depreciation_rates dr
      WHERE dr.method='定額法' AND dr.useful_life=fa.useful_life;
    v_rate := COALESCE(fa.rate, v_rate);   -- 資産個別 > 別表(なお無ければNULL→1/n近似)
    RETURN QUERY SELECT s.fiscal_year, s.depreciation, s.closing_book_value
      FROM straight_line_schedule(fa.acquisition_cost, fa.service_start_date,
                                  fa.useful_life, v_rate) s;

  ELSIF fa.method = '定率法' THEN
    SELECT dr.rate, dr.guarantee_rate, dr.revised_rate
      INTO v_rate, v_guar, v_rev
      FROM depreciation_rates dr
      WHERE dr.method='定率法' AND dr.useful_life=fa.useful_life;
    v_rate := COALESCE(fa.rate, v_rate);
    v_guar := COALESCE(fa.guarantee_rate, v_guar);
    v_rev  := COALESCE(fa.revised_rate, v_rev);
    IF v_rate IS NULL OR v_guar IS NULL OR v_rev IS NULL THEN
      -- 「制度上存在しない」ではなく「別表(depreciation_rates)に未登録」であることを明示し、
      -- 国税庁の償却率等表から該当行を追記すれば解決できると分かるようにする。
      RAISE EXCEPTION '定率法の率が未設定です(資産個別にも別表 depreciation_rates にも無い): '
                      'asset_id=%, 耐用年数=%。国税庁「減価償却資産の償却率等表」から'
                      '当該年数の行(率・改定償却率・保証率)を depreciation_rates に追加してください。',
                      p_asset_id, fa.useful_life;
    END IF;
    RETURN QUERY SELECT s.fiscal_year, s.depreciation, s.closing_book_value
      FROM declining_balance_schedule(fa.acquisition_cost, fa.service_start_date,
                                      fa.useful_life, v_rate, v_guar, v_rev) s;

  ELSIF fa.method = '一括償却' THEN
    RETURN QUERY SELECT s.fiscal_year, s.depreciation, s.closing_book_value
      FROM lump_sum_schedule(fa.acquisition_cost,
                             EXTRACT(YEAR FROM fa.service_start_date)::int) s;
  END IF;
END;
$$;

-- ---------- 指定年の償却費(全額/事業分/家事分/期末簿価) ----------------------
CREATE OR REPLACE FUNCTION asset_depreciation(p_asset_id bigint, p_year int)
RETURNS TABLE(full_dep bigint, business_dep bigint, private_dep bigint, closing_bv bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_ratio numeric;
  v_full  bigint := 0;
  v_close bigint := NULL;
  r record;
BEGIN
  SELECT business_use_ratio INTO v_ratio FROM fixed_assets WHERE id = p_asset_id;
  FOR r IN SELECT * FROM asset_schedule(p_asset_id) ORDER BY fiscal_year LOOP
    IF r.fiscal_year <= p_year THEN v_close := r.closing_book_value; END IF;  -- p_year時点の簿価
    IF r.fiscal_year = p_year THEN v_full := r.depreciation; END IF;          -- 当年の償却費
  END LOOP;
  full_dep     := v_full;
  business_dep := floor(v_full * v_ratio)::bigint;        -- 必要経費算入額(事業分)
  private_dep  := v_full - business_dep;                  -- 家事分
  closing_bv   := COALESCE(v_close, (SELECT acquisition_cost FROM fixed_assets WHERE id=p_asset_id));
  RETURN NEXT;
END;
$$;

-- ---------- 固定資産台帳 = 青色決算書「減価償却費の計算」欄 -------------------
CREATE OR REPLACE FUNCTION asset_register(p_year int)
RETURNS TABLE(name text, acquired text, cost bigint, method text, useful_life int,
              rate numeric, full_dep bigint, business_ratio numeric,
              deductible bigint, closing_bv bigint)
LANGUAGE sql STABLE AS $$
  SELECT fa.name, to_char(fa.service_start_date,'YYYY-MM'), fa.acquisition_cost, fa.method,
         fa.useful_life,
         -- 表示償却率は asset_schedule の解決順(資産個別 > 別表 depreciation_rates > 1/n近似)
         -- と一致させる。台帳の表示率が実計算の率(別表値)とズレないようにする。
         COALESCE(fa.rate,
                  (SELECT dr.rate FROM depreciation_rates dr
                    WHERE dr.method = fa.method AND dr.useful_life = fa.useful_life),
                  round(1.0/NULLIF(fa.useful_life,0),3)),
         d.full_dep, fa.business_use_ratio, d.business_dep, d.closing_bv
  FROM fixed_assets fa
  CROSS JOIN LATERAL asset_depreciation(fa.id, p_year) d
  WHERE fa.disposal_date IS NULL OR fa.disposal_date > make_date(p_year,12,31)
  ORDER BY fa.id
$$;

-- ---------- 全資産の減価償却 決算整理仕訳を自動生成・計上 --------------------
--  事業分→減価償却費、家事分→事業主貸、全額→減価償却累計額。償却費0の資産は除く。
--  生成した仕訳は asset_depreciation_postings に記録して相互関連性を担保する。
--  同年に再実行しても二重計上しない(リンクの有無で判定。UNIQUE制約が最後の砦)。
CREATE OR REPLACE FUNCTION post_depreciation(p_year int, p_date date, p_owner_draw_code text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE fa fixed_assets%ROWTYPE; d record; v_tid bigint; v_count int := 0;
BEGIN
  FOR fa IN SELECT * FROM fixed_assets
            WHERE disposal_date IS NULL OR disposal_date > make_date(p_year,12,31) LOOP
    -- [冪等性] 既にこの年の計上があればスキップ(再実行で二重計上しない)
    IF EXISTS (SELECT 1 FROM asset_depreciation_postings
               WHERE asset_id = fa.id AND fiscal_year = p_year) THEN
      CONTINUE;
    END IF;

    SELECT * INTO d FROM asset_depreciation(fa.id, p_year);
    CONTINUE WHEN COALESCE(d.full_dep,0) = 0;
    -- [沈黙の未計上を防ぐ] 科目コードが accounts に無いと、下の INSERT...SELECT が
    --   0行挿入で正常終了し、借方=貸方=0 のため貸借チェックも通過してしまう。
    --   結果として「償却仕訳が空のまま計上済み扱い(リンクも付与)」になり、後から
    --   科目を直しても冪等判定で再計上されない。明示的に検証して例外で止める。
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = fa.expense_account_code) THEN
      RAISE EXCEPTION '減価償却費の勘定科目が存在しません: code=%, asset_id=%',
                      fa.expense_account_code, fa.id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = fa.accum_account_code) THEN
      RAISE EXCEPTION '減価償却累計額の勘定科目が存在しません: code=%, asset_id=%',
                      fa.accum_account_code, fa.id;
    END IF;
    IF d.private_dep > 0
       AND NOT EXISTS (SELECT 1 FROM accounts WHERE code = p_owner_draw_code) THEN
      RAISE EXCEPTION '事業主貸の勘定科目が存在しません: code=%, asset_id=%',
                      p_owner_draw_code, fa.id;
    END IF;
    -- (1) 償却費を全額認識(簿価は全額減らす)
    INSERT INTO transactions(transaction_date, description, status)
      VALUES (p_date, fa.name || ' 減価償却(決算整理)', 'posted') RETURNING id INTO v_tid;
    INSERT INTO entries(transaction_id, account_id, side, amount)
      SELECT v_tid, id, 'debit',  d.full_dep FROM accounts WHERE code = fa.expense_account_code;
    INSERT INTO entries(transaction_id, account_id, side, amount)
      SELECT v_tid, id, 'credit', d.full_dep FROM accounts WHERE code = fa.accum_account_code;
    INSERT INTO asset_depreciation_postings(asset_id, transaction_id, fiscal_year, kind)
      VALUES (fa.id, v_tid, p_year, 'depreciation');           -- [相互関連性]
    -- (2) 家事使用分を減価償却費から事業主貸へ振替(家事按分と同じ思想)
    IF d.private_dep > 0 THEN
      INSERT INTO transactions(transaction_date, description, status)
        VALUES (p_date, fa.name || ' 家事使用分の振替', 'posted') RETURNING id INTO v_tid;
      INSERT INTO entries(transaction_id, account_id, side, amount)
        SELECT v_tid, id, 'debit',  d.private_dep FROM accounts WHERE code = p_owner_draw_code;
      INSERT INTO entries(transaction_id, account_id, side, amount)
        SELECT v_tid, id, 'credit', d.private_dep FROM accounts WHERE code = fa.expense_account_code;
      INSERT INTO asset_depreciation_postings(asset_id, transaction_id, fiscal_year, kind)
        VALUES (fa.id, v_tid, p_year, 'private_transfer');     -- [相互関連性]
    END IF;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

-- ---------- 相互関連性の実演ビュー: 資産 → 仕訳 → 明細 を一望 -----------------
--  特定の transaction_id で絞れば「仕訳 → どの資産か」の逆引きにもなる。
CREATE OR REPLACE VIEW asset_journal_links AS
SELECT fa.id AS asset_id, fa.name AS asset_name, adp.fiscal_year, adp.kind,
       t.id AS transaction_id, t.transaction_date, t.description,
       e.id AS entry_id, a.code AS account_code, a.name AS account_name, e.side, e.amount
FROM asset_depreciation_postings adp
JOIN fixed_assets fa ON fa.id = adp.asset_id
JOIN transactions t  ON t.id  = adp.transaction_id
JOIN entries e       ON e.transaction_id = t.id
JOIN accounts a      ON a.id  = e.account_id
ORDER BY fa.id, adp.fiscal_year, t.id, e.id;
