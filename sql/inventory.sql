-- =============================================================================
--  棚卸・売上原価(三分法の決算整理)   ※ schema.sql 等を前提
-- =============================================================================
--  税務の前提:
--    売上原価 = 期首商品棚卸高 + 当期仕入高 - 期末商品棚卸高
--    期末商品棚卸高 = 期末数量 × 単価。単価は「評価方法」で決まる(=税務判断)。
--    個人事業の所得税における法定評価方法は「最終仕入原価法」(届出なき場合)。
--    他に総平均法・先入先出法など(届出により選択、継続適用が必要)。
--    同じ在庫数量でも評価方法で期末棚卸高が変わり、その結果 売上原価が変わり、
--    最終的に所得が変わる(売上原価=所得ではない)。
--
--  経理(三分法)の決算整理:
--    (借)仕入     / (貸)繰越商品   … 期首商品棚卸高を当期の費用へ
--    (借)繰越商品 / (貸)仕入       … 期末商品棚卸高を費用から在庫資産へ戻す
--    → 決算整理後の「仕入」勘定残高 = 売上原価、「繰越商品」= 期末在庫(資産)。
-- =============================================================================

-- ---------- 商品マスタ(評価方法を保持) --------------------------------------
CREATE TABLE inventory_items (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code             text NOT NULL UNIQUE,
  name             text NOT NULL,
  valuation_method text NOT NULL DEFAULT '最終仕入原価法'
                   CHECK (valuation_method IN ('最終仕入原価法','総平均法','先入先出法')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN inventory_items.valuation_method IS '棚卸資産の評価方法。個人事業の所得税における法定評価方法は最終仕入原価法(届出なき場合)。変更には届出と継続適用が必要。';

-- ---------- 仕入ロット(数量・単価・日付) ------------------------------------
CREATE TABLE purchase_lots (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id       bigint NOT NULL REFERENCES inventory_items(id),
  purchase_date date   NOT NULL,
  quantity      numeric NOT NULL CHECK (quantity > 0),
  unit_cost     numeric NOT NULL CHECK (unit_cost >= 0),   -- 仕入単価
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_lots_item_date ON purchase_lots (item_id, purchase_date);

CREATE TRIGGER trg_items_touch BEFORE UPDATE ON inventory_items FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_lots_touch  BEFORE UPDATE ON purchase_lots  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_items_audit AFTER INSERT OR UPDATE OR DELETE ON inventory_items FOR EACH ROW EXECUTE FUNCTION record_audit();
CREATE TRIGGER trg_lots_audit  AFTER INSERT OR UPDATE OR DELETE ON purchase_lots  FOR EACH ROW EXECUTE FUNCTION record_audit();

-- ---------- 期末棚卸高の評価(評価方法で分岐) --------------------------------
CREATE OR REPLACE FUNCTION ending_inventory_value(p_item_id bigint, p_asof date, p_ending_qty numeric)
RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_method text;
  v_val    numeric;
BEGIN
  SELECT valuation_method INTO v_method FROM inventory_items WHERE id = p_item_id;

  IF v_method = '最終仕入原価法' THEN
    -- 期末数量 × 最も新しい仕入単価
    SELECT p_ending_qty * pl.unit_cost INTO v_val
    FROM purchase_lots pl
    WHERE pl.item_id = p_item_id AND pl.purchase_date <= p_asof
    ORDER BY pl.purchase_date DESC, pl.id DESC
    LIMIT 1;

  ELSIF v_method = '総平均法' THEN
    -- 期末数量 × (総仕入額 ÷ 総仕入数量)
    SELECT p_ending_qty * (SUM(pl.quantity * pl.unit_cost) / NULLIF(SUM(pl.quantity), 0))
    INTO v_val
    FROM purchase_lots pl
    WHERE pl.item_id = p_item_id AND pl.purchase_date <= p_asof;

  ELSIF v_method = '先入先出法' THEN
    -- 古いものから払い出す → 期末在庫は新しいロットから構成される
    SELECT SUM(pl.unit_cost * CASE
             WHEN cum <= p_ending_qty                  THEN pl.quantity
             WHEN cum - pl.quantity < p_ending_qty     THEN p_ending_qty - (cum - pl.quantity)
             ELSE 0 END)
    INTO v_val
    FROM (
      SELECT quantity, unit_cost, id,
             SUM(quantity) OVER (ORDER BY purchase_date DESC, id DESC) AS cum
      FROM purchase_lots
      WHERE item_id = p_item_id AND purchase_date <= p_asof
    ) pl;
  ELSE
    RAISE EXCEPTION '未対応の評価方法: %', v_method;
  END IF;

  RETURN floor(COALESCE(v_val, 0))::bigint;
END;
$$;

-- ---------- 三分法の決算整理仕訳の材料を吐く --------------------------------
--  期首・期末の棚卸高から、仕入<->繰越商品 の2本の振替仕訳を返す(金額0の行は除く)。
CREATE OR REPLACE FUNCTION cogs_closing_entries(p_opening bigint, p_closing bigint)
RETURNS TABLE(seq int, debit_account text, credit_account text, amount bigint, memo text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT seq, debit_account, credit_account, amount, memo FROM (VALUES
    (1, '仕入',     '繰越商品', p_opening, '期首商品棚卸高の振替(三分法)'),
    (2, '繰越商品', '仕入',     p_closing, '期末商品棚卸高の振替(三分法)')
  ) v(seq, debit_account, credit_account, amount, memo)
  WHERE amount > 0
$$;
