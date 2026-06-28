-- =============================================================================
--  減価償却 決算整理仕訳ジェネレータ   ※ schema.sql / financial_statements.sql 前提
-- =============================================================================
--  税務の前提(個人事業主・所得税):
--    - 法定償却方法は「定額法」。定率法は届出書を出した場合のみ選択可。
--    - 平成19年4月1日以後取得 = 新定額法(残存価額なし、備忘価額1円まで償却)。
--    - 建物(H10.4.1以後)・建物附属設備/構築物(H28.4.1以後)は定額法のみ。
--    - 償却率・改定償却率・保証率は「耐用年数等に関する省令」別表による。
--      下のコードの率は引数で受け取る(別表の値を渡す)。便宜のため定額法のみ
--      率未指定なら round(1/耐用年数,3) で近似するが、必ず別表で要確認。
--    - 取得価額10万/20万/30万の判定、措置法28の2(青色30万円特例,年間300万円上限)
--      は期限・要件があり要確認。ここは「経理方法の選択肢」を提示するに留める。
--
--  この層の責務: 償却費(=税務判断の結果)を計算し、決算整理仕訳の材料を吐く。
--               計算した償却費を transactions/entries に posted すれば、
--               financial_statements.sql の P/L・B/S に自動的に反映される。
-- =============================================================================

-- ---------- 1. 取得価額による経理方法の判定(10万/20万/30万) -------------------
CREATE OR REPLACE FUNCTION classify_depreciation(p_cost bigint, p_is_blue boolean DEFAULT true)
RETURNS TABLE(treatment text, note text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT treatment, note FROM (VALUES
    ('即時経費(少額減価償却資産)',  '取得価額10万円未満(又は使用可能期間1年未満)。全額その年の経費。償却不要。'),
    ('一括償却資産(3年均等)',        '10万円以上20万円未満。取得価額÷3を3年で。月割なし・備忘価額なし。'),
    ('措置法28の2(青色30万円特例)',  '30万円未満かつ青色。全額経費。年間合計300万円まで。期限・要件は要確認。'),
    ('通常償却(定額法/定率法)',      'いずれの特例も使わない/使えない場合。耐用年数で償却。')
  ) v(treatment, note)
  WHERE CASE
    WHEN p_cost < 100000 THEN treatment = '即時経費(少額減価償却資産)'
    WHEN p_cost < 200000 THEN treatment IN ('一括償却資産(3年均等)','通常償却(定額法/定率法)')
                              OR (p_is_blue AND treatment = '措置法28の2(青色30万円特例)')
    WHEN p_cost < 300000 THEN treatment = '通常償却(定額法/定率法)'
                              OR (p_is_blue AND treatment = '措置法28の2(青色30万円特例)')
    ELSE                      treatment = '通常償却(定額法/定率法)'
  END
$$;

-- ---------- 2. 定額法スケジュール(個人の既定) -------------------------------
--  初年度は事業供用月から年末までを月割(供用開始月を1月と数える)。
--  毎年 取得価額×償却率。最終年は備忘価額1円まで(簿価-1を上限)。
CREATE OR REPLACE FUNCTION straight_line_schedule(
  p_cost         bigint,
  p_start        date,                  -- 事業供用日
  p_useful_life  int,                   -- 耐用年数(年)
  p_rate         numeric DEFAULT NULL,  -- 定額法償却率(省令別表)。NULLなら1/n近似
  p_through_year int     DEFAULT NULL   -- ここまで計算(NULLなら備忘1円まで)
)
RETURNS TABLE(fiscal_year int, business_months int, depreciation bigint,
              accumulated bigint, closing_book_value bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rate   numeric := COALESCE(p_rate, round(1.0 / p_useful_life, 3));
  v_annual bigint  := floor(p_cost * v_rate)::bigint;   -- 満額(1年)の償却費
  v_start  int     := EXTRACT(YEAR FROM p_start)::int;
  v_year   int     := v_start;
  v_open   bigint  := p_cost;
  v_acc    bigint  := 0;
  v_months int;
  v_charge bigint;
  v_guard  int := p_useful_life + 5;
  v_count  int := 0;
BEGIN
  WHILE v_open > 1 AND v_count <= v_guard LOOP
    v_months := CASE WHEN v_year = v_start
                     THEN 13 - EXTRACT(MONTH FROM p_start)::int ELSE 12 END;
    v_charge := floor(v_annual * v_months / 12.0)::bigint;
    IF v_charge > v_open - 1 THEN v_charge := v_open - 1; END IF;  -- 備忘1円
    IF v_charge < 0 THEN v_charge := 0; END IF;
    v_acc  := v_acc + v_charge;
    v_open := v_open - v_charge;
    fiscal_year := v_year; business_months := v_months;
    depreciation := v_charge; accumulated := v_acc; closing_book_value := v_open;
    RETURN NEXT;
    EXIT WHEN p_through_year IS NOT NULL AND v_year >= p_through_year;
    v_year := v_year + 1; v_count := v_count + 1;
  END LOOP;
END;
$$;

-- ---------- 3. 定率法(200%)スケジュール(届出時) ----------------------------
--  通常償却費(期首簿価×償却率)が「償却保証額(取得価額×保証率)」を下回ったら、
--  その年の期首簿価を改定取得価額として 改定償却率で均等償却に切替(有名な難所)。
CREATE OR REPLACE FUNCTION declining_balance_schedule(
  p_cost           bigint,
  p_start          date,
  p_useful_life    int,
  p_rate           numeric,   -- 定率法償却率(別表)
  p_guarantee_rate numeric,   -- 保証率(別表)
  p_revised_rate   numeric,   -- 改定償却率(別表)
  p_through_year   int DEFAULT NULL
)
RETURNS TABLE(fiscal_year int, business_months int, depreciation bigint,
              accumulated bigint, closing_book_value bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_start     int := EXTRACT(YEAR FROM p_start)::int;
  v_year      int := v_start;
  v_open      bigint := p_cost;
  v_acc       bigint := 0;
  v_guarantee bigint := floor(p_cost * p_guarantee_rate)::bigint;  -- 償却保証額
  v_revbase   bigint := NULL;   -- 改定取得価額(切替後固定)
  v_months int; v_charge bigint; v_normal bigint;
  v_guard int := p_useful_life + 5; v_count int := 0;
  v_rev_n  int := 0;            -- 均等償却(改定後)の経過年数
  -- 均等償却の年数 = 改定償却率の逆数(改定償却率 = ちょうど 1/残存年数 を切上げた値)。
  v_rev_m  int := round(1.0 / p_revised_rate)::int;
BEGIN
  WHILE v_open > 1 AND v_count <= v_guard LOOP
    v_months := CASE WHEN v_year = v_start
                     THEN 13 - EXTRACT(MONTH FROM p_start)::int ELSE 12 END;
    IF v_revbase IS NULL THEN
      -- 改定切替の判定は「調整前償却額(=期首簿価×償却率)」の満額で行う。
      -- 月数按分は最後の償却限度額にだけ掛ける(初年度に按分後の額で比較すると、
      -- 期末近く取得時に誤って改定へ切り替わるため)。
      v_normal := floor(v_open * p_rate)::bigint;
      IF v_normal >= v_guarantee THEN
        v_charge := floor(v_open * p_rate * v_months / 12.0)::bigint;  -- 通常の定率(限度額に按分)
      ELSE
        v_revbase := v_open;                     -- 保証額割れ → 均等償却に切替
        v_rev_n   := 1;                          -- 切替年が均等償却の1年目
        v_charge  := floor(v_revbase * p_revised_rate * v_months / 12.0)::bigint;
      END IF;
    ELSE
      v_rev_n  := v_rev_n + 1;
      v_charge := floor(v_revbase * p_revised_rate * v_months / 12.0)::bigint;
    END IF;
    -- 改定(均等)償却の最終年(=残存年数 v_rev_m 年目)は備忘1円まで一括計上し、
    -- floor の端数(数円)を翌年に繰り越さない。改定償却率×残存年数=ちょうど1.0 になる
    -- 年数(例: 12年=0.200×5, 17年=0.125×8)で微小テールが出るのを防ぐ。
    IF v_revbase IS NOT NULL AND v_rev_n >= v_rev_m THEN
      v_charge := v_open - 1;
    END IF;
    IF v_charge > v_open - 1 THEN v_charge := v_open - 1; END IF;
    IF v_charge < 0 THEN v_charge := 0; END IF;
    v_acc  := v_acc + v_charge;
    v_open := v_open - v_charge;
    fiscal_year := v_year; business_months := v_months;
    depreciation := v_charge; accumulated := v_acc; closing_book_value := v_open;
    RETURN NEXT;
    EXIT WHEN p_through_year IS NOT NULL AND v_year >= p_through_year;
    v_year := v_year + 1; v_count := v_count + 1;
  END LOOP;
END;
$$;

-- ---------- 4. 一括償却資産(3年均等償却)  所得税法施行令139条 ----------------
--  10万円以上20万円未満。取得価額を3年で均等償却。通常償却と異なり:
--    ・月割なし(供用が年末でも初年から÷3)  ・備忘価額1円を残さず全額経費化
--    ・途中除却・売却でも3年償却を継続(個別管理しない)
--  個人は事業年度=暦年(12月)前提。限度額 = 対象額 × 12/36 = ÷3。
--  円未満の端数は本実装では3年目で調整して取得価額全額を経費化(ソフト実務に準拠)。
--  ※備忘価額1円は「通常償却(定額法・定率法/所令120の2)」の限度額(取得価額-1円)の話で、
--    一括償却資産(所令139)には適用されない。本制度は簿価0まで全額。
--    根拠: タックスアンサーNo.2100(注2)=一括償却 / No.2106=通常償却(別制度)。
CREATE OR REPLACE FUNCTION lump_sum_schedule(p_cost bigint, p_start_year int)
RETURNS TABLE(fiscal_year int, depreciation bigint, accumulated bigint, closing_book_value bigint)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_base   bigint := floor(p_cost / 3.0)::bigint;
  v_acc    bigint := 0;
  v_charge bigint;
  i        int;
BEGIN
  FOR i IN 0..2 LOOP
    IF i < 2 THEN v_charge := v_base;
    ELSE          v_charge := p_cost - v_acc;     -- 3年目で端数を吸収し全額経費化
    END IF;
    v_acc := v_acc + v_charge;
    fiscal_year := p_start_year + i;
    depreciation := v_charge;
    accumulated := v_acc;
    closing_book_value := p_cost - v_acc;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- ---------- 5. 償却率の別表(制度はデータに持たせる) --------------------------
--  償却率・改定償却率・保証率を、コード/引数でなくテーブルで保持する。
--  耐用年数省令 別表第八(定額法)・別表第十(200%定率法,平成24年4月1日以後取得)。
--  ★収録値は国税庁「減価償却資産の償却率等表」(2100_02.pdf)と突合済み
--    (定額法2〜20年・200%定率法3〜20年。tests/test_depreciation_rates_table.py で固定)。
--    範囲外(21年以上等)を追記する際は、同表と突合すること。
--
--  網羅範囲について:
--    - 定額法は別表第八の 2〜20年を全て収録。
--    - 定率法(200%)も別表第十の 3〜20年を収録(2年は償却率1.000で保証率・改定償却率が
--      無く本表の対象外)。21年以上が必要な場合は別表から追記する。
--      未収録の年数は asset_schedule() が「別表に未登録」と分かる文言で例外停止する
--      ため、利用者は『制度上存在しない』のではなく『別表に追記が必要』だと判別できる。
--    - 検証: 期首取得・取得価額1,000,000円で各年のスケジュールを生成すると、全年が
--      備忘価額1円まで完全償却し、期首取得は耐用年数ちょうどで完了する
--      (tests/test_depreciation_rates_table.py / test_declining_balance_matrix.py)。
--
--  制度改正(取得日による率の切替)への発展余地:
--    現状は「平成24年4月1日以後取得の200%定率法」を前提に1世代のみを持つ。将来、
--    取得日で率が変わる改正(例: 250%→200%)に備えるなら、本表に applicable_from /
--    applicable_to(適用取得日の期間)列を足し、主キーを (method, useful_life,
--    applicable_from) に拡張、asset_schedule() 側で取得日が期間に含まれる行を引く、
--    という拡張で吸収できる(行の追加=制度改正、というデータ駆動の方針を維持できる)。
CREATE TABLE depreciation_rates (
  method         text         NOT NULL CHECK (method IN ('定額法','定率法')),
  useful_life    int          NOT NULL CHECK (useful_life >= 2),
  rate           numeric(6,5) NOT NULL,   -- 償却率(0.00000〜1.00000)
  revised_rate   numeric(6,5),            -- 改定償却率(定率法のみ)
  guarantee_rate numeric(6,5),            -- 保証率  (定率法のみ)
  PRIMARY KEY (method, useful_life),
  CHECK ( (method='定率法' AND revised_rate IS NOT NULL AND guarantee_rate IS NOT NULL)
       OR (method='定額法' AND revised_rate IS NULL AND guarantee_rate IS NULL) )
);
COMMENT ON TABLE depreciation_rates IS
  '耐用年数省令の別表(定額法=別表第八/200%定率法=別表第十)。償却率等をコードから外出ししたもの。定額法は2〜20年、定率法は3〜20年を収録し、国税庁の償却率等表(2100_02.pdf)と突合済み。範囲外を追記する際は同表と要突合。';

-- 定額法(別表第八): 2〜20年を網羅
INSERT INTO depreciation_rates(method,useful_life,rate) VALUES
 ('定額法',2,0.500),('定額法',3,0.334),('定額法',4,0.250),('定額法',5,0.200),
 ('定額法',6,0.167),('定額法',7,0.143),('定額法',8,0.125),('定額法',9,0.112),
 ('定額法',10,0.100),('定額法',11,0.091),('定額法',12,0.084),('定額法',13,0.077),
 ('定額法',14,0.072),('定額法',15,0.067),('定額法',16,0.063),('定額法',17,0.059),
 ('定額法',18,0.056),('定額法',19,0.053),('定額法',20,0.050);

-- 200%定率法(別表第十,平成24年4月1日以後取得): 3〜20年を網羅
--  各行の (償却率, 改定償却率, 保証率)。期首取得で全年が備忘1円まで完全償却することを
--  tests/test_depreciation_rates_table.py で機械的に検算している。
INSERT INTO depreciation_rates(method,useful_life,rate,revised_rate,guarantee_rate) VALUES
 ('定率法',3,0.667,1.000,0.11089),
 ('定率法',4,0.500,1.000,0.12499),
 ('定率法',5,0.400,0.500,0.10800),
 ('定率法',6,0.333,0.334,0.09911),
 ('定率法',7,0.286,0.334,0.08680),
 ('定率法',8,0.250,0.334,0.07909),
 ('定率法',9,0.222,0.250,0.07126),
 ('定率法',10,0.200,0.250,0.06552),
 ('定率法',11,0.182,0.200,0.05992),
 ('定率法',12,0.167,0.200,0.05566),
 ('定率法',13,0.154,0.167,0.05180),
 ('定率法',14,0.143,0.167,0.04854),
 ('定率法',15,0.133,0.143,0.04565),
 ('定率法',16,0.125,0.143,0.04294),
 ('定率法',17,0.118,0.125,0.04038),
 ('定率法',18,0.111,0.112,0.03884),
 ('定率法',19,0.105,0.112,0.03693),
 ('定率法',20,0.100,0.112,0.03486);
