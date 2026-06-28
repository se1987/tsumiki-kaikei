-- =============================================================================
--  複式簿記 + 優良な電子帳簿エンジン  スキーマ (PostgreSQL 14+)
-- =============================================================================
--  設計方針: 「税法要件」を「システム要件(受け入れ条件)」に翻訳する。
--
--    税法要件            システム実装                  このファイル内の場所
--    -----------------   ---------------------------   ----------------------
--    複式簿記(貸借一致)  貸借一致の遅延制約トリガ      check_balanced()
--    訂正削除履歴        追記専用 audit_logs + トリガ  audit_logs / record_audit()
--    真実性(改ざん防止)  履歴の不変化 + posted は逆仕訳 forbid_change()
--    相互関連性          外部キー + 辿れるクエリ        entries.* FK / general_ledger
--    検索機能            日付/金額/相手方の索引         各 INDEX (範囲+組み合わせ)
--    保存期間            根拠法ごとの起算日 + ビュー     filing_deadlines / document_retention
--    試算表/元帳         元帳=ビュー / 試算表=期間指定の関数(明示レイヤー)
--
--  金額は BIGINT(円・整数) で保持する。float は丸め誤差が申告書に出るため厳禁。
-- =============================================================================

-- ---------- 列挙型 -----------------------------------------------------------
CREATE TYPE account_type   AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE balance_side   AS ENUM ('debit','credit');   -- 借方 / 貸方
CREATE TYPE txn_status     AS ENUM ('draft','posted','voided');
CREATE TYPE tax_treatment  AS ENUM ('taxable','reduced','exempt','out_of_scope');
                              -- 課税 / 軽減 / 非課税 / 不課税・対象外
CREATE TYPE doc_type       AS ENUM ('invoice','receipt','contract','estimate',
                                    'delivery_note','bank_statement','other');
CREATE TYPE legal_basis    AS ENUM ('income_tax','consumption_tax_invoice');
                              -- 保存期間の根拠法: 所得税法 / 消費税法(適格請求書)
CREATE TYPE audit_operation AS ENUM ('INSERT','UPDATE','DELETE');

-- ---------- 共通: updated_at 自動更新 ---------------------------------------
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
--  1. accounts  勘定科目マスタ
-- =============================================================================
CREATE TABLE accounts (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code          text        NOT NULL UNIQUE,           -- 科目コード(並び順/判定に使用)
  name          text        NOT NULL,                  -- 例: 旅費交通費, 売上高
  account_type  account_type NOT NULL,
  -- 正規残高(借/貸)は account_type から導出 => 入力ミスを構造的に排除
  normal_balance balance_side
      GENERATED ALWAYS AS
      (CASE WHEN account_type IN ('asset','expense')
            THEN 'debit'::balance_side ELSE 'credit'::balance_side END) STORED,
  parent_id     bigint REFERENCES accounts(id),        -- 補助科目(自己参照)
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  accounts IS '勘定科目マスタ。最初から一級市民として独立させ、補助科目/部門の追加に耐える土台。';
COMMENT ON COLUMN accounts.normal_balance IS 'account_type から自動導出。資産・費用=借方、それ以外=貸方。';

-- =============================================================================
--  2. transactions  取引(仕訳ヘッダ)
-- =============================================================================
CREATE TABLE transactions (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_date date        NOT NULL,               -- [検索要件] 取引年月日
  counterparty     text,                               -- [検索要件] 取引先(相手方)
  description      text,                               -- 摘要
  status           txn_status  NOT NULL DEFAULT 'draft',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE transactions IS '仕訳のヘッダ。status=posted で貸借一致を強制(下の遅延制約)。確定後の訂正は UPDATE せず逆仕訳(voided+新規)で行い真実性を担保する。';

-- [検索要件] 範囲指定(日付)・相手方・両者の組み合わせ
CREATE INDEX idx_txn_date          ON transactions (transaction_date);
CREATE INDEX idx_txn_counterparty  ON transactions (counterparty);
CREATE INDEX idx_txn_date_party    ON transactions (transaction_date, counterparty); -- 組み合わせ検索

-- =============================================================================
--  3. entries  仕訳明細
-- =============================================================================
CREATE TABLE entries (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id  bigint      NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, -- [相互関連性]
  account_id      bigint      NOT NULL REFERENCES accounts(id),                       -- [相互関連性]
  side            balance_side NOT NULL,               -- 借方 / 貸方
  amount          bigint      NOT NULL CHECK (amount > 0),  -- [検索要件] 金額・円・整数
  line_no         int         NOT NULL DEFAULT 1,
  -- 消費税まわり(任意): 課税区分・税率・インボイス適格か
  tax             tax_treatment,
  tax_rate        numeric(4,3),                        -- 例: 0.100, 0.080
  qualified_invoice boolean,                           -- 適格請求書発行事業者からの仕入か
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE entries IS '仕訳明細。1取引に複数行。posted 取引では Σ借方=Σ貸方 を遅延制約で保証。';

CREATE INDEX idx_entries_txn     ON entries (transaction_id);        -- [相互関連性] 元帳・明細たどり
CREATE INDEX idx_entries_account ON entries (account_id);            -- 科目別集計(試算表)
CREATE INDEX idx_entries_amount  ON entries (amount);                -- [検索要件] 金額の範囲検索

-- ---------- 複式簿記の不変条件: Σ借方 = Σ貸方 (posted のみ) ------------------
-- 明細を1件ずつ入れている途中は不一致でも良いので、COMMIT 時に判定する遅延制約。
CREATE OR REPLACE FUNCTION check_balanced() RETURNS trigger AS $$
DECLARE
  v_txn_id bigint;
  v_status txn_status;
  v_debit  bigint;
  v_credit bigint;
BEGIN
  IF TG_TABLE_NAME = 'transactions' THEN
    v_txn_id := COALESCE(NEW.id, OLD.id);
  ELSE
    v_txn_id := COALESCE(NEW.transaction_id, OLD.transaction_id);
  END IF;

  SELECT t.status,
         COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'debit'),  0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.side = 'credit'), 0)
    INTO v_status, v_debit, v_credit
  FROM transactions t
  LEFT JOIN entries e ON e.transaction_id = t.id
  WHERE t.id = v_txn_id
  GROUP BY t.status;

  IF v_status = 'posted' AND v_debit <> v_credit THEN
    RAISE EXCEPTION '取引 % が貸借不一致です (借方=% / 貸方=%)', v_txn_id, v_debit, v_credit;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_entries_balanced
  AFTER INSERT OR UPDATE OR DELETE ON entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_balanced();

CREATE CONSTRAINT TRIGGER trg_txn_balanced     -- draft -> posted への切替も検査
  AFTER INSERT OR UPDATE ON transactions
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_balanced();

-- =============================================================================
--  4. filing_deadlines  申告期限マスタ(年分ごと)
-- =============================================================================
--  保存期間の起算日は申告期限に依存し、申告期限は 3/15 が土日祝なら翌開庁日へ順延
--  される。順延は「曜日」だけでなく「祝日」にも依存するため、式ではなくデータで持つ。
--  法定日(3/15)と実際の期限の両方を保持し、曜日は生成列で見えるようにする。
CREATE TABLE filing_deadlines (
  tax_year          int  PRIMARY KEY,                  -- 年分(例: 2024 = 令和6年分)
  statutory_date    date NOT NULL,                     -- 法定の申告期限(=翌年3/15)
  actual_due_date   date NOT NULL,                     -- 休日順延後の実際の申告期限
  -- 曜日(なぜ順延したかが一目で分かる)。ISODOW から導出(ロケール非依存・immutable)。
  statutory_weekday text GENERATED ALWAYS AS (
    CASE EXTRACT(ISODOW FROM statutory_date)
      WHEN 1 THEN '月' WHEN 2 THEN '火' WHEN 3 THEN '水' WHEN 4 THEN '木'
      WHEN 5 THEN '金' WHEN 6 THEN '土' WHEN 7 THEN '日' END) STORED,
  actual_weekday    text GENERATED ALWAYS AS (
    CASE EXTRACT(ISODOW FROM actual_due_date)
      WHEN 1 THEN '月' WHEN 2 THEN '火' WHEN 3 THEN '水' WHEN 4 THEN '木'
      WHEN 5 THEN '金' WHEN 6 THEN '土' WHEN 7 THEN '日' END) STORED,
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (actual_due_date >= statutory_date)
);
COMMENT ON TABLE filing_deadlines IS '年分ごとの所得税の申告期限。3/15が土日祝なら翌開庁日へ順延した実日付を actual_due_date に持つ。保存期間(所得税法)の起算はこの翌日。祝日・年末年始(12/29-1/3)はアプリ側で考慮して投入すること。';

CREATE TRIGGER trg_filing_touch BEFORE UPDATE ON filing_deadlines
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- 種データ: 土日のみ順延した近似値で投入(祝日は別途上書きする想定)
INSERT INTO filing_deadlines (tax_year, statutory_date, actual_due_date, note)
SELECT y,
       make_date(y+1,3,15),
       CASE EXTRACT(ISODOW FROM make_date(y+1,3,15))
         WHEN 6 THEN make_date(y+1,3,15) + 2   -- 土 -> 翌月曜
         WHEN 7 THEN make_date(y+1,3,15) + 1   -- 日 -> 翌月曜
         ELSE make_date(y+1,3,15)
       END,
       '土日のみ順延した近似(祝日・年末年始は要上書き)'
FROM generate_series(2023, 2027) AS y;

-- =============================================================================
--  5. documents  証憑(電子取引データ保存 = 電帳法の「義務」枠 / 75万円パターンB)
-- =============================================================================
CREATE TABLE documents (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_type         doc_type    NOT NULL,
  legal_basis      legal_basis NOT NULL DEFAULT 'income_tax', -- 保存期間の根拠法
  transaction_date date        NOT NULL,               -- [検索要件] 取引年月日(起算の基準年)
  amount           bigint,                             -- [検索要件] 取引金額(円)
  counterparty     text,                               -- [検索要件] 取引先
  file_hash        text        NOT NULL,               -- [真実性] 原本の SHA-256(改ざん検知)
  storage_uri      text        NOT NULL,               -- 実体の保管先(S3 等)
  transaction_id   bigint REFERENCES transactions(id), -- [相互関連性] 証憑 <-> 仕訳
  -- 所得税法の保存年数(帳簿/決算書類/現金預金取引等関係書類=7年, その他書類=5年)。
  -- 消費税法インボイスは根拠法側で7年固定のため、その場合この値は参考値。
  retention_years  smallint    NOT NULL,
  uploaded_by      text        NOT NULL DEFAULT current_user,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE documents IS 'PDF等の証憑。電子取引データ保存(義務)の検索3要件をテーブルに内蔵。仕訳と紐付けると75万円控除パターンB(自動連携+改ざん防止)の土台になる。';
COMMENT ON COLUMN documents.legal_basis IS '保存期間の根拠法。income_tax=所得税法(起算: 申告期限の翌日)、consumption_tax_invoice=消費税法の適格請求書(起算: 課税期間末日の翌日から2か月経過日, 7年)。起算日・満了日は document_retention ビューで算出する(派生値はテーブルに持たない)。';
COMMENT ON COLUMN documents.retention_years IS '所得税法の保存年数。青色: 帳簿/決算書類/現金預金取引等関係書類=7年(前々年の所得300万円以下は一部5年)、請求書・見積・契約・納品・送り状=5年。条件分岐があるためアプリ側で決定。';

CREATE INDEX idx_doc_date        ON documents (transaction_date);
CREATE INDEX idx_doc_amount      ON documents (amount);
CREATE INDEX idx_doc_party       ON documents (counterparty);
CREATE INDEX idx_doc_date_party  ON documents (transaction_date, counterparty); -- 組み合わせ

-- =============================================================================
--  6. audit_logs  訂正削除履歴(追記専用) = 優良電子帳簿の中核要件
-- =============================================================================
CREATE TABLE audit_logs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name  text            NOT NULL,
  record_id   bigint          NOT NULL,
  operation   audit_operation NOT NULL,
  old_values  jsonb,                                   -- 更新前値
  new_values  jsonb,                                   -- 更新後値
  changed_by  text            NOT NULL,                -- 更新者
  changed_at  timestamptz     NOT NULL DEFAULT now()   -- 更新日時
);
COMMENT ON TABLE audit_logs IS '誰が・いつ・何を・どう変えたか(前後値)を全件記録。INSERT 以外を禁止して不変化する。運用ではアプリ接続ロールから UPDATE/DELETE 権限を REVOKE しておくこと。';

-- 監査ログを記録するトリガ関数(全業務テーブル共通)
CREATE OR REPLACE FUNCTION record_audit() RETURNS trigger AS $$
DECLARE
  v_user text := COALESCE(current_setting('app.current_user', true), current_user);
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_logs(table_name, record_id, operation, old_values, new_values, changed_by)
    VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', NULL, to_jsonb(NEW), v_user);
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO audit_logs(table_name, record_id, operation, old_values, new_values, changed_by)
    VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), v_user);
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO audit_logs(table_name, record_id, operation, old_values, new_values, changed_by)
    VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD), NULL, v_user);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
-- アプリは接続直後に  SET LOCAL app.current_user = '<ログインユーザ>';  を実行する想定。

-- 監査ログ自体の不変化(追記専用を強制)
CREATE OR REPLACE FUNCTION forbid_change() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_logs は追記専用です（% は許可されていません）', TG_OP;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_immutable
  BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- ---------- 各業務テーブルにトリガを付与 -------------------------------------
CREATE TRIGGER trg_accounts_audit     AFTER INSERT OR UPDATE OR DELETE ON accounts     FOR EACH ROW EXECUTE FUNCTION record_audit();
CREATE TRIGGER trg_transactions_audit AFTER INSERT OR UPDATE OR DELETE ON transactions FOR EACH ROW EXECUTE FUNCTION record_audit();
CREATE TRIGGER trg_entries_audit      AFTER INSERT OR UPDATE OR DELETE ON entries      FOR EACH ROW EXECUTE FUNCTION record_audit();
CREATE TRIGGER trg_documents_audit    AFTER INSERT OR UPDATE OR DELETE ON documents    FOR EACH ROW EXECUTE FUNCTION record_audit();
-- filing_deadlines は参照(マスタ)データのため監査対象外。変更管理が要るなら同様に付与可。

CREATE TRIGGER trg_accounts_touch     BEFORE UPDATE ON accounts     FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_transactions_touch BEFORE UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_entries_touch      BEFORE UPDATE ON entries      FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_documents_touch    BEFORE UPDATE ON documents    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- =============================================================================
--  7. 集計・派生ビュー  「試算表・元帳・保存期限は実体ではなく算出結果」
-- =============================================================================
-- 試算表レイヤー(明示): 仕訳 → 総勘定元帳(general_ledger) → 試算表 → 決算整理 →
--   P/L・B/S → 青色決算書、という会計の標準フローの中核。期間指定で科目別の
--   借方計・貸方計・残高(account_typeで借方正/貸方正を吸収)を返す。
--   月次決算・消費税・推移分析は、この層を起点に組み立てると拡張性が高い。
CREATE OR REPLACE FUNCTION trial_balance(p_from date, p_to date)
RETURNS TABLE(code text, name text, account_type account_type,
              debit_total bigint, credit_total bigint, balance bigint)
LANGUAGE sql STABLE AS $$
  SELECT a.code, a.name, a.account_type,
         COALESCE(SUM(m.amount) FILTER (WHERE m.side='debit'),0)::bigint,
         COALESCE(SUM(m.amount) FILTER (WHERE m.side='credit'),0)::bigint,
         (CASE WHEN a.account_type IN ('asset','expense')
               THEN COALESCE(SUM(m.amount) FILTER (WHERE m.side='debit'),0)
                  - COALESCE(SUM(m.amount) FILTER (WHERE m.side='credit'),0)
               ELSE COALESCE(SUM(m.amount) FILTER (WHERE m.side='credit'),0)
                  - COALESCE(SUM(m.amount) FILTER (WHERE m.side='debit'),0) END)::bigint
  FROM accounts a
  LEFT JOIN (
    SELECT e.account_id, e.side, e.amount
    FROM entries e JOIN transactions t ON t.id = e.transaction_id
    WHERE t.status='posted' AND t.transaction_date BETWEEN p_from AND p_to
  ) m ON m.account_id = a.id
  GROUP BY a.id, a.code, a.name, a.account_type
$$;

-- 総勘定元帳: 科目 × 取引を時系列で(相互関連性が辿れることの実演)
CREATE VIEW general_ledger AS
SELECT a.code, a.name,
       t.transaction_date, t.counterparty, t.description,
       e.side, e.amount, t.id AS transaction_id, e.id AS entry_id
FROM entries e
JOIN accounts a      ON a.id = e.account_id
JOIN transactions t  ON t.id = e.transaction_id
WHERE t.status = 'posted'
ORDER BY a.code, t.transaction_date, t.id;

-- 証憑の保存期限: 根拠法ごとに起算日を切り替えて算出
--   income_tax              … 起算 = 申告期限(順延後)の翌日、満了 = 起算 + retention_years年 - 1日
--   consumption_tax_invoice … 起算 = 翌年3/1(課税期間末日の翌日+2月)、満了 = 起算 + 7年 - 1日
--   ※ 所得税法施行規則63条4項の文言は「3/15の翌日」固定だが、ここでは申告期限の順延に
--      連動させる(長め=安全側)。連動させたくない場合は filing_deadlines を引かず法定日で算出。
CREATE VIEW document_retention AS
WITH base AS (
  SELECT d.*,
         EXTRACT(YEAR FROM d.transaction_date)::int AS ref_year
  FROM documents d
)
SELECT b.id, b.doc_type, b.legal_basis, b.counterparty, b.amount,
       b.transaction_date, b.ref_year,
       CASE b.legal_basis
         WHEN 'income_tax'
           THEN COALESCE(fd.actual_due_date, make_date(b.ref_year + 1, 3, 15)) + 1
         WHEN 'consumption_tax_invoice'
           THEN make_date(b.ref_year + 1, 3, 1)
       END AS retention_start,                         -- 起算日
       CASE b.legal_basis
         WHEN 'income_tax'
           THEN ((COALESCE(fd.actual_due_date, make_date(b.ref_year + 1, 3, 15)) + 1)
                  + make_interval(years => b.retention_years))::date - 1
         WHEN 'consumption_tax_invoice'
           THEN ((make_date(b.ref_year + 1, 3, 1))
                  + make_interval(years => 7))::date - 1
       END AS retention_until                          -- 保存義務の最終日(この日まで保存)
FROM base b
LEFT JOIN filing_deadlines fd ON fd.tax_year = b.ref_year;

-- ---------- 検索要件(規5⑤一ハ)の補助ビュー -------------------------------------
--  entries.amount は明細単位の金額。電帳法の「取引金額」検索を伝票単位でも素直に
--  書けるよう、伝票(transaction)単位の合計金額を集約する。
--  なぜ「借方合計」か: posted の仕訳は Σ借方=Σ貸方(貸借一致)なので、借方合計が
--    その伝票の取引金額に一致する。借方+貸方を合算すると金額が二重になるため、
--    片側(借方)だけを集計するのが正しい。
--  status を絞っていないため draft も対象に含む(検索・確認用途で未確定も拾えるように)。
--    status 列を返しているので、確定分だけ見たい呼び出しは WHERE status='posted' で絞れる。
--  これで「日付範囲 AND 取引先 AND 金額範囲」の複合検索が1クエリで書ける。
--  (取引年月日・取引先には transactions 側に、金額には entries 側に索引済み)
CREATE OR REPLACE VIEW transaction_search AS
SELECT t.id,
       t.transaction_date,
       t.counterparty,
       t.description,
       t.status,
       COALESCE(SUM(e.amount) FILTER (WHERE e.side='debit'), 0) AS total_amount
FROM transactions t
LEFT JOIN entries e ON e.transaction_id = t.id
GROUP BY t.id, t.transaction_date, t.counterparty, t.description, t.status;
