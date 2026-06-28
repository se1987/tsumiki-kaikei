# 個人事業向け会計エンジン（PostgreSQL）

個人事業の青色申告を支える計算を、PostgreSQL の上に複式簿記と税務ロジックとして実装した、学習・検証用のプロジェクトです。所得税（青色決算書の主要行）と消費税（本則／簡易／2割・3割特例）までを、仕訳から一気通貫で計算します。

「会計ソフトを作る」こと自体より、**会計と税務を"長く壊れない"RDB設計にどう落とし込むか**に主眼があります。設計の背骨は2つです。

- **正しさは（アプリでなく）データベースの制約で守る**
- **制度変更はコードでなくデータで吸収する**

> ⚠️ 本リポジトリは学習・検証用です。税務上の助言を提供するものではありません。制度（税率・特例・期限など）は改正されます。実務では必ず最新の一次情報（国税庁等）をご確認ください。

---

## アーキテクチャ

```mermaid
flowchart LR
  A[仕訳] --> B[総勘定元帳]
  B --> C[試算表 trial_balance]
  C --> D[決算整理<br/>減価償却/家事按分/棚卸]
  D --> E[P/L・B/S]
  E --> F[青色決算書]
  C --> G[税区分集計]
  G --> H[消費税<br/>本則/簡易/2割・3割特例]
```

中核は **試算表レイヤー**（`trial_balance`）です。P/L・B/S・青色決算書・消費税は、いずれもこの層を入力に組み立てます。様式や税率が変わっても、中間層が安定していればエンジン全体の寿命が延びる、という考え方です。

---

## データフロー

テーブル・ビュー・関数のレベルで、データがどう流れるかを示します。決算整理は新たな仕訳として `entries` に書き戻され、すべての集計は試算表（`trial_balance`）を経由します。

```mermaid
flowchart TD
  subgraph IN["入力：仕訳とマスタ"]
    ACC[accounts<br/>勘定科目]
    TXN[transactions<br/>取引]
    ENT[entries<br/>仕訳明細]
  end

  subgraph ADJ["決算整理（仕訳を生成し書き戻し）"]
    FA["fixed_assets<br/>post_depreciation 減価償却"]
    HH["proration_basis<br/>household_adjustment 家事按分"]
    INV["inventory / purchase_lots<br/>cogs_closing_entries 売上原価"]
  end

  subgraph CORE["中核"]
    TB["trial_balance 試算表"]
    GL[general_ledger<br/>総勘定元帳]
    AB["account_balance 残高"]
  end

  subgraph FS["財務諸表"]
    PL["profit_loss P/L"]
    BS["balance_sheet B/S"]
  end

  subgraph AO["青色決算書"]
    MAP[account_statement_map<br/>statement_lines]
    AIS["aozora_income_statement 損益"]
    ABS["aozora_balance_sheet 貸借"]
  end

  subgraph TAX["消費税"]
    TC[tax_categories<br/>税区分マスタ]
    TBS["tax_base_summary<br/>課税標準集計"]
    TRR[tax_relief_rules<br/>率・期間]
    WS["consumption_tax_worksheet<br/>申告書中間表"]
    CMP["consumption_tax_compare<br/>本則/簡易/2割・3割"]
  end

  FA --> ENT
  HH --> ENT
  INV --> ENT

  ACC --> TB
  TXN --> TB
  ENT --> TB
  ENT --> GL
  TB --> AB

  TB --> PL
  AB --> BS

  PL --> AIS
  BS --> ABS
  MAP --> AIS
  MAP --> ABS

  ENT --> TBS
  TC --> TBS
  TBS --> WS
  TRR --> WS
  WS --> CMP
```

ポイントは2つです。**(1) 決算整理（減価償却・家事按分・棚卸）は計算結果を仕訳として `entries` に戻す**ため、試算表より下流の集計は一貫した数字を見ます。**(2) 消費税は科目残高ではなく `entries` × `tax_categories`（税区分）から課税標準を組む**ため、所得計算とは独立した経路で集計されます。

---

## モジュールとロード順

SQL は相互に依存するため、次の順で読み込んでください（`demo/run_demo.py` も同順です）。

| # | ファイル | 役割 |
|---|---|---|
| 1 | `sql/schema.sql` | 中核スキーマ。複式簿記（accounts/transactions/entries）、貸借一致制約、監査ログ、証憑保存、試算表・元帳ビュー、取引検索ビュー（`transaction_search`） |
| 2 | `sql/financial_statements.sql` | 試算表（期間指定）、P/L・B/S、貸借均衡の自己検算 |
| 3 | `sql/depreciation.sql` | 減価償却（定額・定率・一括）のスケジュール計算と、償却率の別表テーブル（`depreciation_rates`） |
| 4 | `sql/household_proration.sql` | 家事按分（事業割合の計算と決算整理） |
| 5 | `sql/inventory.sql` | 棚卸・売上原価（三分法） |
| 6 | `sql/aozora_statement.sql` | 青色決算書への写像（損益・貸借の主要行） |
| 7 | `sql/fixed_asset.sql` | 固定資産台帳（減価償却の自動仕訳化）、固定資産↔償却仕訳のFKリンク（相互関連性・二重計上防止） |
| 8 | `sql/tax_categories.sql` | 税区分マスタ（消費税・インボイスの土台） |
| 9 | `sql/consumption_tax.sql` | 消費税エンジン（本則／簡易／2割・3割特例、経過措置） |

---

## 動かし方

PostgreSQL を別途立てなくても、`pgserver` でその場に起動して検証できます。

```bash
pip install pgserver
python demo/run_demo.py
```

`demo/run_demo.py` は、架空のフリーランスエンジニアの1年分（売上・経費・固定資産・家事按分）を流し、**仕訳 → 試算表 → P/L・B/S → 青色決算書 → 固定資産台帳 → 消費税（中間表・3方式）** までをコンソールに出力します。P/L の利益が B/S の純資産に入って貸借が均衡するところまで、数字で追えます。

### テスト

`tests/` 配下に、正常系・異常系・エッジケースを含むテストを置いています。GitHub Actions（`.github/workflows/ci.yml`）で push / pull request ごとに自動実行されます。各テストは `pgserver` でその場に PostgreSQL を起動し、`sql/` をロードして検証します（別途 DB 不要）。

| ファイル | 主な検証内容 |
|---|---|
| `tests/test_depreciation_regression.py` | 償却スケジュールの回帰（特に期末取得時の改定切替不具合の再発防止） |
| `tests/test_classify_depreciation.py` | 取得価額（10万/20万/30万）と青色可否による経理方法判定の境界値 |
| `tests/test_schedule_edgecases.py` | 定額（償却率NULL/最短2年/期中・期末取得/打切り）・一括・定率の追加ケース |
| `tests/test_declining_balance_matrix.py` | 定率法を耐用年数3〜20年×取得時期×複数価額で網羅検証（完全償却・単調・端数繰越なし・期首はn年で完了） |
| `tests/test_depreciation_rates_table.py` | 別表の網羅性（定額2〜20年・定率3〜20年）と、各行が完全償却するかの検算 |
| `tests/test_fixed_asset.py` | 別表からの率解決・事業専用割合の按分・自動仕訳の冪等性・率未設定/制約違反の異常系 |
| `tests/test_post_depreciation_accounts.py` | 勘定科目コード欠落時に償却仕訳を沈黙で未計上にせず例外停止する異常系 |
| `tests/test_schema_constraints.py` | 貸借一致の遅延制約・`amount>0`・監査ログの追記専用・生成列・検索ビュー |

```bash
pip install pgserver
python tests/test_depreciation_regression.py   # 個別実行
for t in tests/test_*.py; do python "$t"; done  # 全実行
```

---

## 設計メモ

- **金額は整数（円）で保持**します。浮動小数点は 10 進小数を正確に表せず、税率の割戻しで 1 円のズレが生じ得るためです。税込→税抜の割戻しも整数演算で行います。
- **貸借一致は `DEFERRABLE INITIALLY DEFERRED` の制約トリガ**で、コミット時にまとめて検査します（確定済みの仕訳のみ対象）。
- **税区分は「税率」ではなく「申告書への集計ルール」**として設計しています（区分自身が売上/仕入・課税売上/課税仕入への集計可否を持つ）。売上か仕入かを科目タイプで判定しません。
- **税制の率・期間は `tax_relief_rules` テーブルにデータとして持ち**、計算ロジックには埋め込みません。改正は行の更新で吸収します。
- **減価償却の償却率・改定償却率・保証率も `depreciation_rates`（別表第八・第十）にデータで持ちます**。同じく「制度はコードでなくデータ」の適用で、資産個別の率指定が無ければ別表から引き、どちらにも無ければ実行時に例外で止めます（沈黙の誤計算を防ぐ）。
- **固定資産と償却仕訳は `asset_depreciation_postings` で外部キー連結**します。相互関連性を摘要テキストでなく構造で担保し、`UNIQUE(資産, 年度, 種別)` で同年の二重計上をDB側で禁止します。

---

## 既知の制限（正直な注記）

このエンジンは「計算の主要部分」までを対象にしており、次は未対応です。

- 消費税の本則課税は **課税売上割合95%以上・全額控除を前提**。個別対応方式／一括比例配分方式は未実装。
- 簡易課税は **単一のみなし仕入率を前提**（複数事業区分の加重平均は未対応）。
- 申告書様式レベルの処理（**国税7.8%/地方の分離、課税標準の千円未満・税額の百円未満切捨て**）は未実装で、合算税率で算定。
- **e-Tax への送信・取込形式の出力は対象外**。
- 監査ログ等は**電子帳簿保存法の考え方を参考にした設計**であり、「電帳法対応済み」ではありません。
- 固定資産の**除却・売却**、その他の決算整理（未払・前払・貸倒引当金など）は今後。
- 償却率の別表は、**定額法は2〜20年**、**定率法(200%)は3〜20年**を収録し、**国税庁「減価償却資産の償却率等表」（2100_02.pdf）と突合済み**（`tests/test_depreciation_rates_table.py` で全値を固定）。21年以上など未収録年数は `asset_schedule` が「別表に未登録」と分かる文言で例外停止するので、同表から該当行を `depreciation_rates` に追記してください。
- 償却率の別表は **平成24年4月1日以後取得の200%定率法（1世代）を前提**。取得日で率が変わる改正に備える場合は、`depreciation_rates` に適用取得日の期間列（`applicable_from`/`applicable_to`）を足し、主キーを拡張して取得日で引く設計に発展できます（詳細は `sql/depreciation.sql` のコメント参照）。

制度の率・期限は、実装時点で一次情報を確認していますが、改正されます。利用時は最新をご確認ください。

---

## ライセンス

MIT License。詳細はリポジトリ直下の `LICENSE` を参照してください（著作権者: se1987）。
