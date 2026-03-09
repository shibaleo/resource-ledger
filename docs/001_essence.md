# Resource Ledger — 設計の本質

お金・時間・材料などあらゆるリソースの計画と実績を統一的に記録するための、構造パターンを整理する。

---

# Part 1: 設計

## 1. 中核パターン: 変動台帳（Delta Ledger）

本モデルの最も本質的な構造は「**変動の記録から残高を導出する**」パターン。

```
event (なぜ変わったか)
  └── entry (何がいくら変わったか)  ← append-only
        ↓ SUM
      balance (今いくらか)           ← 導出ビュー
```

1つの event が複数の entry を生成するのが一般的。会計的な用途では1取引あたり 3〜5 entry になることが多い。

### このパターンが解決する問題

- **監査証跡**: 残高の直接更新ではなく変動を記録するため、全履歴が残る
- **時点復元**: `WHERE recorded_at <= :as_of` で任意時点の残高を再現
- **並行性**: UPDATE 競合がない（INSERT only）
- **訂正の透明性**: 反対仕訳 + 正値を追加。元の記録は不変

### 二重時間軸（bi-temporal）

2つの独立した時間を event と entry で分担する:

```
event.recorded_at  = いつ記録されたか（システム時間。自動付与）
entry.effective_at  = いつに帰属するか（業務時間。ユーザーが指定）
```

同一 event 内の entry は同時に記録されるため、recorded_at は event の属性。effective_at は entry ごとに異なりうるため entry の属性。

この分離により、以下が可能になる:

- **後追い記録**: 12:00 の食事を 19:00 に記録（effective_at=12:00, recorded_at=19:00）
- **計画スナップショット**: `WHERE track='plan' AND event.recorded_at <= :as_of` で「ある時点での計画」を復元
- **誤り修正と計画変更の統一的な扱い**: どちらも append-only で表現。区別が必要なら event の属性で表す

### 訂正パターン

entry は append-only で不変。訂正は corrects_event_id を持つ新しい event で「打消し + 再記録」する。

訂正の effective_at をどこに置くかは、訂正の意図によって異なる:

| 訂正の意図 | 打消しの effective_at | 効果 |
|-----------|---------------------|------|
| 当期調整（金額訂正等） | 当期（今） | 過去の期間残高は不変。差異は当期に計上 |
| 遡及訂正（帰属時点の変更等） | 元の時点 | 過去の期間残高が変わる |

DB 構造は同じ。どちらのパターンを適用するかはアプリ層の判断。

### 構造要素

| 要素 | 理由 |
|------|------|
| event → entry の 1:N 構造 | 変動の因果関係（なぜこの entry が存在するか）を保証 |
| append-only の不変性 | 監査証跡と時点復元の前提 |
| event.recorded_at | 時点残高の導出に必須。event の属性（entry には持たない） |
| entry.effective_at | 業務時間の帰属。entry の属性（entry ごとに異なりうる） |
| corrects_event_id | 訂正の追跡（元の event への参照）。循環禁止を DB trigger で保証（イベントグラフは DAG） |
| event.idempotency_key | 重複投入防止。UNIQUE 制約で API 再送・バッチ再実行時の二重計上を防ぐ |
| entry.target_type | target の型整合性を DB trigger で保証。resource.target_table と一致すること |
| resource.unit_id FK→unit_master | 単位の正規化。自由文字列による揺れ（h/hour/hours）を FK 制約で防止 |
| delta_value NUMERIC | 金額・時間・数量を統一的に扱う。精度はアプリ層で管理（例: 金額は小数2位、時間は小数4位） |
| delta_value != 0 制約 | 無意味なレコードの排除 |

---

## 2. 多次元交点: キューブ構造

各 entry は「複数の軸の交点」に位置する。

```
entry = f(owner, activity, effective_at, track, resource, [target])
          ↑       ↑          ↑           ↑       ↑           ↑
        誰の    何のため    いつの     計画/実績  何のリソース  何に対して
```

### 7つの軸

| # | 軸 | 問い |
|---|---|---|
| 1 | **owner** | 誰が責任を持つか |
| 2 | **activity** | 何のためか（nullable） |
| 3 | **effective_at** | いつに帰属するか（秒精度 TIMESTAMP） |
| 4 | **track** | 計画か実績か |
| 5 | **resource** | 何のリソースか（金額・工数・材料を統一） |
| 6 | **target** | 何に対してか（polymorphic） |
| 7 | **event** | なぜ変わったか |

### 軸の分類

| 分類 | 軸 | 特徴 |
|------|---|------|
| **構造軸**（FK あり） | owner, activity, resource, event | ディメンションテーブルへの参照。DB が整合性を保証 |
| **値軸**（スカラー） | effective_at, track | 値そのもの。DB は型のみ保証 |
| **自由軸**（polymorphic） | target | 参照先が resource 依存。polymorphic FK は不可。型整合性は DB trigger で保証、存在検証はアプリ層 |

- entry は `target_id`（UUID）と `target_type`（VARCHAR）を持つ
- `target_type` は `resource.target_table` と一致することを DB trigger で検証する（型整合性の保証）
- `target_id` の存在検証（参照先テーブルにレコードがあるか）は polymorphic FK が不可能なためアプリ層で担う
- target は nullable。不要なユースケースでは NULL のまま使える
- append-only 台帳では参照破損が永続的なデータ破壊になるため、型整合性だけでもコアで保証する

### 符号規約

- **正**: リソースの増加（収入、資産増、取得）
- **負**: リソースの減少（支出、資産減、消費）
- 会計アプリでは resource の classification に応じて表示上の正負を解釈する。DB 上の符号規約は統一

---

## 3. 二重トラック: plan / actual

track は2値（plan / actual）で、相互に干渉しない。

### 設計方針

| 要素 | 方針 |
|------|------|
| track の2値制約 | 計画と実績の分離はリソース管理の普遍的要件 |
| track 不可侵 | plan と actual は別の真実。上書き不可 |
| plan の粒度は自由 | 消費だけ・購入込み等、何を計画するかはアプリ層が決める |
| 負の残高を許容 | double entry 不要。残高の符号に制約を設けない |
| 比較はクエリで | plan vs actual の比較方法（残高比較 / 消費のみ比較等）はアプリ層が選ぶ |

- 計画値の粒度が複数ありうる（活動単位の一括値 vs 主体単位の月予算）
  - → effective_at + activity_id の組み合わせで自然に表現可能

---

## 4. 階層ディメンション: ツリー構造

主要ディメンション（owner, activity, resource）はすべて階層を持つ。

```
親ノード (is_leaf=false, 集計用)
├── 子ノード (is_leaf=false)
│   ├── 末端ノード (is_leaf=true, entry 記入可) ★
│   └── 末端ノード (is_leaf=true) ★
└── 末端ノード (is_leaf=true) ★
```

| 要素 | 理由 |
|------|------|
| parent_id による自己参照 | ドリルダウン・集計の軸 |
| is_leaf フラグ | 新規 entry の書き込み制御（二重計上防止） |

- `is_leaf` は **書き込み制御**であり、データ制約ではない。INSERT 時に `is_leaf = true` を検証する（トリガーまたはアプリ層）
- リーフが非リーフに変わっても、過去の entry は有効。記録時点では leaf だったという事実は不変。合算は親ノードに自然に吸収される
- DB の FK や CHECK で常時検証するものではない

### 階層の変更: リーフの分割

リーフノードを子に分割する場合（例: `bank_acc` → `bk1`, `bk2`）:

1. 元のリーフの `is_leaf` を FALSE に変更
2. 新しい子リーフを作成
3. 振替 event で元のリーフの残高を子リーフに移動（打消し + 再記録）

```
event: "銀行口座の分割"
  entry: bank_acc  -500,000（打消し）
  entry: bk1       +300,000
  entry: bk2       +200,000
```

append-only パターンにより、分割前の履歴は `bank_acc` に残り、分割後の新規取引は `bk1`/`bk2` に記録される。合算は親ノード `bank_acc` で自然に導出される。

### 議論ポイント

- owner に SCD Type 2（valid_from/valid_to + group_id）は必要か？
  - 組織改編のような変化を追跡するユースケースでは必須
  - 汎用モデルではオプショナル？
- activity に SCD Type 2 は不要か？

---

## 5. 統合の鍵: resource

「金額の科目」と「業務量の単位」を単一のツリーに統一する。

```
entry → resource_id  → resource (階層、カテゴリ分類)
        target_id    → polymorphic (entry.target_type で判別)
        target_type  → resource.target_table と一致（DB trigger で保証）
resource → unit_id   → unit_master (単位の FK 正規化)
```

### 統合で得られるもの

- **単一テーブルで全リソースを記録** — クエリが統一的
- **新リソース種別の追加がレコード追加のみ** — DDL 不要
- **balance ビューが1つ** — resource で WHERE すれば種別ごとの残高

### 統合で注意すべきこと

- **型安全性**: balance ビューは resource_id 単位で集計するため、単位混在は発生しない。階層ロールアップはクエリ/BI層の責務であり、コアスキーマの標準機能としては提供しない。ロールアップ時の unit / category 整合性は設計規律（同一サブツリー内で unit を統一する）で対処する
- **インデックス戦略**: resource の category ごとにクエリパターンが異なる場合、部分インデックスで対応
- **会計的な制約（貸借検証等）**: コアスキーマには含めない。拡張テーブルの balance_check ビューで対応

---

## 6. コアスキーマと拡張テーブルの境界

### コアスキーマの責務: 集計のための最小構造

コアスキーマのディメンションテーブル（owner, activity, resource）は「残高の集計・ドリルダウンに必要な最小構造」だけを持つ。業務的な意味は拡張テーブルが付与する。

| 軸 | コアスキーマが持つもの | 拡張テーブルで定義するもの |
|---|---|---|
| **owner** | id, parent_id, is_leaf, cd, name | 組織種別、SCD Type 2、メンバー関係等 |
| **activity** | id, parent_id, is_leaf, cd, name | 状態、期間、分類、契約情報等 |
| **resource** | id, parent_id, is_leaf, cd, name, category, unit_id(FK→unit_master), classification, target_table | ドメイン固有の科目体系のレコード |
| **unit_master** | id(VARCHAR PK), name | 単位の正規化。h/hour/hours の揺れを防止 |
| **target** | entry 上の target_id(UUID) + target_type(VARCHAR) | テーブル定義そのもの（メンバー、取引先、材料等） |

- owner, activity, resource はツリー構造を持つ。balance の階層ロールアップに必要なため
- unit_master は単位の一貫性を FK で保証する。自由文字列だと h/hour/hours の混在で SUM が無意味になるため
- target はツリー構造を持たない。entry 上の target_id + target_type で存在し、参照先テーブルは拡張側で定義する。target_type と resource.target_table の一致は DB trigger で保証
- 上位組織（会社等）は owner ツリーのルートノードとして表現する。別テーブルは不要

### 拡張テーブルで対応する領域

同じ DB 内にコアスキーマとは別のテーブルとして定義する。コアのディメンションテーブルへの FK や 1:1 の付属テーブルで紐付ける。

| 関心事 | 例 | 拡張パターン |
|--------|---|------|
| ディメンションの業務属性 | activity の状態・期間・分類、owner の組織種別 | ディメンションテーブルへの列追加、または 1:1 の付属テーブル |
| target の実体 | メンバー、取引先、材料 | target_id が参照するテーブルを定義。resource.target_table で判別 |
| 契約管理 | 受注、発注、請求・支払スケジュール | リソース変動とは別の関心事。activity への FK で紐付け |
| 役割・関係管理 | 組織×メンバー、活動×メンバー | 中間テーブルで表現 |
| 確定・承認フロー | 計画の承認、月次締め等 | entry は事実であり状態を持たない。「確定」は業務フローの関心事 |
| 計画シナリオ | 当初予算、修正予算、見込 | scenario テーブル（id, cd, name）を追加し、event.scenario_id で紐付け。track の2値は維持。actual は NULL、plan は必須 |
| 操作監査ログ | ディメンション変更、resource 追加等 | event は「entry の存在理由」に限定し混在させない。DB トリガーまたは audit_log テーブルで対応 |
| 貸借検証 | 借方合計 = 貸方合計 | balance_check ビューとして定義 |
| 階層集計の高速化 | 深いツリーの再帰 CTE 回避 | closure table（ancestor_id, descendant_id, depth）または materialized path で対応 |
| 期間集計の高速化 | 月次・四半期・年度の集計 | generated column（effective_date, effective_month）または date dimension テーブルで対応 |

---

# Part 2: ユースケース

## UC1. 食事・栄養管理

食品の購入と消費を記録し、計画と実績を比較する。

### 軸のマッピング

| 軸 | 割り当て |
|---|---|
| owner | 自分（個人） |
| activity | lunch, dinner 等の食事イベント |
| resource | 炭水化物(g), 脂質(g), タンパク質(g) |
| target | NULL（不要） |

### entry の例

```
event: "昼食の計画"  track=plan
  entry: owner=自分, activity=lunch, resource=炭水化物, delta=-80
  entry: owner=自分, activity=lunch, resource=タンパク質, delta=-30

event: "食品購入"  track=actual
  entry: owner=自分, activity=NULL, resource=炭水化物, delta=+500
  entry: owner=自分, activity=NULL, resource=タンパク質, delta=+200

event: "昼食"  track=actual, effective_at=12:00, recorded_at=19:00
  entry: owner=自分, activity=lunch, resource=炭水化物, delta=-85
  entry: owner=自分, activity=lunch, resource=タンパク質, delta=-25
```

### 設計上のポイント

- plan は消費（負の変動）だけでよい。購入を含めるかはアプリの判断
- plan に購入を含めない場合、plan の残高は負になる。これは許容される
- plan vs actual の比較方法（残高比較 / 消費のみ比較）はクエリで選択

---

## UC2. 個人の収支管理

収入・支出を記録し、月次予算と比較する。

### 軸のマッピング

| 軸 | 割り当て |
|---|---|
| owner | 自分（個人） |
| activity | NULL（活動単位の管理は不要） |
| resource | 給与収入, 食費, 家賃, 光熱費, ... (category=monetary, unit=JPY) |
| target | NULL |

### 予算 vs 実績の比較

```sql
SELECT r.name,
       SUM(CASE WHEN e.track = 'plan'   THEN e.delta_value END) AS budget,
       SUM(CASE WHEN e.track = 'actual' THEN e.delta_value END) AS actual,
       SUM(CASE WHEN e.track = 'plan'   THEN e.delta_value END)
     - SUM(CASE WHEN e.track = 'actual' THEN e.delta_value END) AS variance
FROM entry e
JOIN resource r ON r.id = e.resource_id
WHERE e.effective_at >= '2025-05-01'
  AND e.effective_at <  '2025-06-01'
GROUP BY r.name;
```

### resource ツリーの例

```
収入
├── 給与 ★leaf
└── 副収入 ★leaf
支出
├── 食費 ★leaf
├── 家賃 ★leaf
└── 光熱費 ★leaf
```

階層ロールアップにより「支出合計」「収入合計」が自動で導出される。

---

## UC3. 会計（B/S + P/L）

資産・負債・純資産・収益・費用の全5分類を追跡する。

### resource ツリー

```
monetary (category=monetary, unit=JPY)
├── revenue (classification=revenue)
│   └── 純売上高 ★leaf
├── expense (classification=expense)
│   ├── 外注仕入 ★leaf
│   └── 一般管理費 ★leaf
├── asset (classification=asset)
│   ├── 現金 ★leaf
│   ├── 銀行預金 ★leaf
│   └── 売掛金 ★leaf
├── liability (classification=liability)
│   └── 未払費用 ★leaf
└── equity (classification=equity)
    └── 純資産 ★leaf
labor (category=labor)
├── hours (unit=h, target_table=member) ★leaf
└── person_months (unit=PM, target_table=member) ★leaf
```

会計の5分類は resource の属性（classification）として表現する。P&L 科目も B/S 科目も同一ツリーに共存する。

### 初期残高の投入（棚卸し）

ある時点の資産・負債を把握し、通常の event + entry で記録する:

```
event: "初期残高の棚卸し"
  entry: 現金      +200,000
  entry: 銀行預金  +800,000
  entry: 売掛金    +150,000
  entry: 未払費用  +100,000  （負債は正値で記録）
  entry: 純資産    +1,050,000（貸借差額）
```

### 日常取引の例

```
event: "売上計上"
  entry: 純売上高  +100,000  (P/L: 収益)
  entry: 売掛金    +100,000  (B/S: 資産)

event: "外注費支払"
  entry: 外注仕入  +50,000   (P/L: 費用)
  entry: 銀行預金  -50,000   (B/S: 資産)

event: "人件費計上"
  entry: 一般管理費 +30,000  (P/L: 費用)
  entry: 未払費用   +30,000  (B/S: 負債)
  entry: 工数 160h, target=メンバーX  (労務)
  entry: 人月 2.5,  target=メンバーX  (労務)
```

### 設計上のポイント

- 貸借の整合性（借方合計 = 貸方合計）はコアスキーマでは強制しない。拡張テーブルの balance_check ビューで対応
- 1つの event が P/L + B/S + 労務を横断して entry を生成する。これが resource 統合の利点
- B/S の整合性（純資産の変動 = P/L の純利益）は entry の SUM から自然に導出される

---

## UC4. クロスドメイン: 食事 × 会計 × 時間

食品の購入から消費まで、金額・栄養・時間を1つの台帳で横断的に記録する。resource 統合の本領を示すユースケース。

### resource ツリー（抜粋）

```
monetary (category=monetary, unit=JPY)
├── expense └── 食費 ★leaf
├── liability └── クレジット未払 ★leaf
nutrition (category=nutrition, unit=g)
├── 炭水化物 ★leaf
├── タンパク質 ★leaf
└── 脂質 ★leaf
time (category=time, unit=min)
└── 食事時間 ★leaf
```

### 食品購入（クレジット決済）

1つの event が monetary と nutrition を横断する:

```
event: "スーパーで食品購入" track=actual
  entry: resource=食費,          delta=+3,000  (費用増 / monetary)
  entry: resource=クレジット未払, delta=+3,000  (負債増 / monetary)
  entry: resource=炭水化物,      delta=+500    (在庫増 / nutrition)
  entry: resource=タンパク質,    delta=+200    (在庫増 / nutrition)
  entry: resource=脂質,          delta=+150    (在庫増 / nutrition)
```

### 食事の計画

```
event: "昼食計画" track=plan, activity=lunch
  entry: resource=炭水化物,  delta=-80
  entry: resource=タンパク質, delta=-30
  entry: resource=食事時間,   delta=+30   (予定30分)
```

### 食事の実績

```
event: "昼食" track=actual, activity=lunch, effective_at=12:00, recorded_at=19:00
  entry: resource=炭水化物,  delta=-85    (消費 / nutrition)
  entry: resource=タンパク質, delta=-25    (消費 / nutrition)
  entry: resource=脂質,      delta=-15    (消費 / nutrition)
  entry: resource=食事時間,   delta=+45    (所要時間 / time)
```

### 時間差異の把握

```sql
SELECT r.name,
       SUM(CASE WHEN e.track = 'plan'   THEN e.delta_value END) AS plan,
       SUM(CASE WHEN e.track = 'actual' THEN e.delta_value END) AS actual,
       SUM(CASE WHEN e.track = 'actual' THEN e.delta_value END)
     - SUM(CASE WHEN e.track = 'plan'   THEN e.delta_value END) AS variance
FROM entry e
JOIN resource r ON r.id = e.resource_id
WHERE r.category = 'time'
GROUP BY r.name;
-- → 食事時間: plan=30, actual=45, variance=+15
```

### 設計上のポイント

- 1つの event が金額・栄養・時間を横断して entry を生成できる。これが resource 統合の最大の利点
- 購入時の会計仕訳と栄養素の在庫増加が同一 event に共存する
- plan vs actual の比較は resource の category でフィルタすれば、栄養・時間それぞれ独立に行える

---

## まとめ

```
┌─────────────────────────────────────────┐
│              resource-ledger             │
│                                         │
│  event ──1:N──> entry ──SUM──> balance  │
│                  │                       │
│            ┌─────┼─────┐                │
│            ↓     ↓     ↓                │
│         owner activity resource          │
│         (tree) (tree)   (tree)           │
│                                         │
│  track: plan / actual                   │
│  effective_at: 帰属時点（TIMESTAMP）     │
└─────────────────────────────────────────┘
```

| 本質     | コメント                     |
| ------ | ------------------------ |
| 変動台帳   | 残高は entry の SUM。事実は不変    |
| 多次元交点  | 誰が × 何のために × いつ × 何のリソース |
| 二重トラック | 計画と実績は別世界                |
| 階層集計   | ドリルダウン可能な木構造             |
| 統一リソース | 金額も時間も材料も同じ構造で記録         |
