-- =============================================================================
--  家事按分(家事関連費の事業割合計算と決算整理仕訳)  ※ schema.sql 等を前提
-- =============================================================================
--  税務の前提(所得税法45条 / 施行令96条):
--    家賃・水道光熱費・通信費・車両費などの家事関連費は、業務遂行上必要な部分を
--    「合理的な基準」で按分し、その事業割合分のみ必要経費にできる。
--    - 青色申告者は、取引記録等で業務必要部分を明らかに区分できれば経費にできる。
--    - 白色は「主たる部分が業務」等の要件あり(区分が明確なら可)。要確認。
--    - 合理的基準の例: 家賃=床面積比 / 電気=使用面積・時間 / 通信=使用時間 /
--                      車両=走行距離比。 → 按分根拠を残すことが調査対応上重要。
--
--  経理方法: 期中は支払額を全額その経費科目に計上し、決算整理で家事分(個人負担分)
--            を「事業主貸」へ振り替える。
--              (借)事業主貸  家事分 / (貸)該当経費  家事分
--            効果: 経費は事業分だけ残り(所得↑)、事業主貸が資産に立つ。B/Sは一致。
-- =============================================================================

-- ---------- 按分根拠(合理的基準)を記録するマスタ ------------------------------
--  分子(事業使用分)/分母(全体)から事業割合を生成。説明文で調査対応の根拠も残す。
CREATE TABLE proration_basis (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  expense_code     text    NOT NULL,              -- 対象経費の勘定科目コード
  basis_kind       text    NOT NULL,              -- 基準種別: 面積/時間/距離 等
  business_measure numeric NOT NULL,              -- 分子(事業使用分)
  total_measure    numeric NOT NULL CHECK (total_measure > 0), -- 分母(全体)
  business_ratio   numeric GENERATED ALWAYS AS    -- 事業割合(小数4桁に丸め)
                     (round(business_measure / total_measure, 4)) STORED,
  description      text,                           -- 合理的根拠の説明(調査対応)
  effective_year   int,                            -- 適用年
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE proration_basis IS '家事按分の合理的根拠。分子/分母と説明を残し事業割合を生成。仕訳と紐付けることで税務調査時の説明可能性を高め、優良電子帳簿が求める相互関連性・証跡管理にも資する設計(相互関連性そのものではない点に注意)。';

CREATE TRIGGER trg_proration_touch BEFORE UPDATE ON proration_basis
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_proration_audit AFTER INSERT OR UPDATE OR DELETE ON proration_basis
  FOR EACH ROW EXECUTE FUNCTION record_audit();

-- ---------- 按分計算: 事業分・家事分に分ける --------------------------------
--  事業分は floor(切捨て)=経費を過大計上しない安全側。家事分は残額。
CREATE OR REPLACE FUNCTION household_split(p_total bigint, p_business_ratio numeric)
RETURNS TABLE(business_amount bigint, household_amount bigint)
LANGUAGE sql IMMUTABLE AS $$
  SELECT floor(p_total * p_business_ratio)::bigint,
         p_total - floor(p_total * p_business_ratio)::bigint
$$;

-- ---------- 決算整理仕訳の材料を吐く(根拠マスタを使う版) --------------------
--  指定経費の年間計上額に対し、proration_basis の事業割合で家事分を算出し、
--  「事業主貸 / 経費」の振替仕訳に必要な金額と摘要を返す。
CREATE OR REPLACE FUNCTION household_adjustment(p_basis_id bigint, p_annual_total bigint)
RETURNS TABLE(expense_code text, business_amount bigint, household_amount bigint,
              business_ratio numeric, memo text)
LANGUAGE sql STABLE AS $$
  SELECT b.expense_code,
         floor(p_annual_total * b.business_ratio)::bigint,
         p_annual_total - floor(p_annual_total * b.business_ratio)::bigint,
         b.business_ratio,
         '家事按分(' || b.basis_kind || ' ' || b.business_measure || '/' || b.total_measure
           || '=' || b.business_ratio || ') ' || COALESCE(b.description,'')
  FROM proration_basis b
  WHERE b.id = p_basis_id
$$;
