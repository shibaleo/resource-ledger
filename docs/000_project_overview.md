# data-composition (DCMP) 設計概要

## システムの役割

あらゆるデータソースの観測を**資源分類と共起関係によって意味付けする**層。
値（数値・ベクトル・テキスト）は持たない。値の実体はすべて data_warehouse（Neon）が持つ。

> **スコープの境界**
> - DCMP = 共起の記述（「これらの観測は同じ出来事だ」という宣言）
> - 因果推論 = DCMP の次のレイヤー（将来拡張。現在は対象外）

---

## 層の役割分担

> **設計の根幹：Neon = 事実 / XTDB = 解釈**
>
> 事実（beanpost Posting、DWH レコード）は変更不可・bi-temporal 不要。
> 解釈（event、observation）は事後修正・訂正が起きうるため XTDB の bi-temporal が必須。
> DWH 全体を bi-temporal にすることはできないため、解釈層だけを XTDB に分離する。

```
外部 API（真実の持ち主）
  Zaim / Fitbit / Toggl / Tanita / ...
        ↓  GAS パイプライン

Neon ← 事実の格納（変更不可・bi-temporal 不要）
  schema: data_warehouse    ← raw_*, stg_*, dim_*（DWH 内部実装）
  schema: data_presentation ← fct_*（外部公開インターフェース）
  schema: accounting        ← 会計帳簿 beanpost（金銭・権利・義務）
  schema: inventory         ← 在庫帳簿 beanpost（物品・栄養）+ food_nutrition_ratio

App 層
  ← Neon（beanpost）に仕訳を記録する
  ← inventory の food_nutrition_ratio を参照して栄養 Posting を自動生成する
  ← dc_catalog に record を登録（遅延）
  ← DCMP に event / observation を作成する
  ← DWH の分類情報（fct の attrs 相当カラム）を observation.attrs に転記する

XTDB — dc_catalog（インフラカタログ）※ 別 DB
  ← data_source: DWH テーブルの論理名 → 物理 URI マッピング
  ← record: DWH・beanpost 行ごとの XTDB サロゲートキー発行（変更を吸収）

XTDB — data_composition（解釈層）← bi-temporal
  ← 値を持たない。共起・分類のみ
  ← 事実の ID を直接知らない（record_id 経由）
  ← scenario: event へのタグ（横断的分析軸 + 期間を持つプロジェクト的文脈）
  ← event: 複数観測が「同一の現実の出来事」であることの宣言
  ← observation: event が record を resource として「観測した」という意味付け行為
  ← resource: 分類オントロジー（階層ツリー）
```

---

## dc_catalog スキーマ（別 XTDB DB）

### data_source — DWH テーブル登録簿

```sql
data_source(
  _id,            -- 論理名 e.g. "neon.fct_zaim_transactions"
  connection_uri, -- 接続先 e.g. "postgres://neon-host/mydb"
  table_name,     -- テーブル名 e.g. "fct_zaim_transactions"
  sync_type,      -- 'api_sync' | 'manual' | 'derived'
  sync_schedule   -- 'daily' | 'weekly' | null
)
```

**DCMP に登録する data_source（確定）:**

| _id | table | 備考 |
|-----|-------|------|
| `neon.fct_zaim_transactions` | data_presentation.fct_zaim_transactions | 支出・収入・振替 |
| `neon.fct_health_body` | data_presentation.fct_health_body | 体組成（Tanita） |
| `neon.fct_health_sleep` | data_presentation.fct_health_sleep | 睡眠（Fitbit） |
| `neon.fct_toggl_time_entries` | data_presentation.fct_toggl_time_entries | 時間記録（Toggl） |
| `neon.stg_fitbit__activity` | data_warehouse.stg_fitbit__activity | 日次活動量（fct なし） |

> `raw_*` は connector 専用。`stg_*` は DWH 内部実装。
> DCMP は常に `data_presentation.fct_*` を参照する（例外: fct のない stg_fitbit__activity）。

### record — DWH 行のサロゲートキー発行

```sql
record(
  _id,        -- uuidv8(hash(source_id + ":" + dwh_row_id))  ← 決定論的サロゲートキー
  source_id,  -- FK to data_source
  dwh_row_id  -- DWH 側の元 ID（fct の id カラム値）
)
-- UNIQUE(source_id, dwh_row_id) = _id の一意性で保証（冪等 INSERT）
```

**DWH ID 変更時の影響範囲：** record.dwh_row_id のみ更新。data_composition は変更不要。

---

## data_composition スキーマ（XTDB）

### scenario — event へのタグ（横断的分析軸）

**event に付けるタグ**。resource 分類（何のリソースか）とは直交する。
「何のために見るか」「どの文脈で捉えるか」「どのプロジェクト期間に属するか」がタグの内容。

```sql
scenario(
  _id,
  name,        -- e.g. "健康改善3月", "節約チャレンジ", "副業開発"
  description
)
-- valid_time でプロジェクト的な期間を表現できる（XTDB bi-temporal）
-- 期間なし → 継続的な分析軸（横断タグ）
-- 期間あり → 始終があるプロジェクト的文脈
```

> - resource = 「これは食品だ」「これはカフェインだ」（データの性質・分類）
> - scenario = 「この event は健康改善として見る」「副業開発としても見る」（解釈の文脈）
> - 1 event に複数タグが付きうる → event ↔ scenario は M:N

### event_scenario — event ↔ scenario の M:N junction

```sql
event_scenario(
  _id,         -- uuidv8(hash(event_id + scenario_id))
  event_id,
  scenario_id
)
```

### event — 共起の宣言単位

```sql
event(
  _id,
  description,
  idempotency_key
)
-- activity_id は廃止（→ 設計決定ログ参照）
```

### observation — event が record を resource として観測した意味付け行為

event と dc_catalog.record の 1:1 接続インスタンス。resource 分類を付与する。

```sql
observation(
  _id,         -- uuidv8(hash(event_id + record_id))
  event_id,    -- FK to event
  resource_id, -- FK to resource（どの resource として観測したか）
  record_id,   -- FK to dc_catalog.record（DWH の元 ID は知らない）
  attrs        -- JSONB: DWH 側の補助分類・タグを格納
)
-- UNIQUE(event_id, record_id) = _id の一意性で保証
-- 同一 event 内で同じ DWH 行は 1 つの observation にのみ帰属
```

**observation.attrs の役割：**

resource 階層が「何のリソースか（主軸・存在論的）」を表すのに対し、
attrs は「そのインスタンスをどう分類するか（補助軸・次元的）」を表す。

```json
// Toggl 時間エントリの observation.attrs 例
{
  "personal_category": "coding",
  "social_category":   "work",
  "coarse_category":   "deep_work",
  "project_name":      "副業開発",
  "duration_seconds":  3600
}

// Zaim 支出の observation.attrs 例
{
  "zaim_category": "食費",
  "zaim_genre":    "食料品",
  "place":         "KALDI"
}
```

attrs の値は DWH の fct カラム（project_name, category_name 等）から App 層が転記する。
DWH の dim テーブルによる分類結果がここに流れ込む。

### 構造例

```
event(2026-03-09 筋トレ)
├── event_scenario → scenario(健康改善3月)
├── event_scenario → scenario(週次レビュー)
├── observation(resource=r-squat, record_id=rec-uuid-1, attrs={set:1, reps:10})
│     └── dc_catalog: rec-uuid-1 → (neon.fct_strength, "s1")
├── observation(resource=r-squat, record_id=rec-uuid-2, attrs={set:2, reps:10})
└── observation(resource=r-time,  record_id=rec-uuid-3, attrs={personal_category:"exercise"})
      └── dc_catalog: rec-uuid-3 → (neon.fct_toggl_time_entries, "t1")
```

同じ DWH 行を別 resource として別 event から観測する例：

```
dc_catalog.record: rec-uuid-5 → (neon.fct_zaim_transactions, "z-042")

event(2026-03-09 Monster 購入) ← scenario(節約チャレンジ)
└── observation(resource=r-beverage, record_id=rec-uuid-5)

event(2026-03-09 Monster 摂取) ← scenario(健康改善3月)
└── observation(resource=r-caffeine, record_id=rec-uuid-5)  ← 同じ record
```

### resource — 分類オントロジー（主軸）

```sql
resource(_id, parent_id, is_leaf, cd, name)
-- resource は DCMP で定義。DWH のテーブル構造とは独立。
-- 異なるソース（Toggl/Clockify 等）からの観測が同じ resource に収束する。
-- unit_id 廃止: 単位はbeanpostのcommodity定義が持つ。DCMPは分類のアンカーのみ。
-- balance_type 廃止: 残数管理は beanpost が担う。
-- unit_master テーブル 廃止。
```

---

## 軸の帰属先

| 軸 | 帰属先 | 理由 |
|----|--------|------|
| scenario | event_scenario（M:N） | event へのタグ。複数 scenario に同時帰属しうる |
| project（期間あり） | scenario + valid_time | XTDB bi-temporal で期間を表現。別エンティティ不要 |
| activity | **廃止**（→ 設計決定ログ） | scenario に吸収 |
| owner | Neon (DWH) | データの持ち主はデータ自身が知っている |
| 補助分類・タグ | observation.attrs | DWH の dim 分類結果をインスタンス単位で保持 |
| resource | observation.resource_id | 視点の定義そのもの（主軸・存在論的） |

---

## 設計原則

- **DWH = 事実** — 外部 API・手入力。変えられない。時刻もスキーマも現実に縛られる
- **event = 解釈の単位** — 事実よりも自由。事後的・主観的・修正可能
  - 同じ DWH 行を複数の event が解釈してよい
  - 1 event が複数の DWH 行にまたがってよい
  - event の valid_time は DWH 行のタイムスタンプと一致しなくてよい
  - 解釈を誤っても bi-temporal で訂正できる（system_time が履歴を保持）
- **DCMP は値を持たない** — 数値・ベクトル・テキストの責任は Neon が持つ
- **DCMP のスコープ = 共起** — 「これらの観測は同じ出来事に属する」という宣言のみ
- **因果推論は次のレイヤー** — DCMP の上に構築される将来拡張
- **dc_catalog = DWH の変更を吸収する層** — record がサロゲートキーを発行。data_composition は DWH の元 ID を知らない
- **uuidv8（決定論的）** — `_id = uuidv8(hash(inputs))` により冪等 INSERT と XTDB レベルの一意性保証
- **resource 階層 = 存在論的主軸** — 「何のリソースか」。ソース非依存。異なるサービスからの観測が収束する
- **observation.attrs = 補助次元軸** — 「そのインスタンスをどう分類するか」。DWH の dim 分類が流れ込む
- **fct = DWH の公開 API** — DCMP は常に fct_* を参照。stg_* は DWH 内部実装
- **fct の責務 = FK 解決のみ** — 概念統合・cross-source UNION・解釈（dedup 等）は行わない
- **bi-temporal** — valid_time（帰属時点）+ system_time（記録時点、自動・不変）

---

## 参照方向と変更の波及範囲

```
DWH (Neon) data_presentation
  fct_zaim_transactions.id = "z-uuid-042"  ← 変更があっても
         ↓ 登録（遅延）
dc_catalog.record
  rec-uuid-5: (neon.fct_zaim_transactions, "z-uuid-042")  ← ここだけ更新
         ↓ record_id
data_composition.observation
  record_id = rec-uuid-5  ← 変更不要
```

| 変更の種類 | 影響範囲 |
|-----------|---------|
| DWH 行の再採番 | dc_catalog.record.dwh_row_id のみ |
| DWH の物理移行 | dc_catalog.data_source.connection_uri のみ |
| 新しい DWH 追加 | dc_catalog.data_source に追加 |
| 時間追跡を Toggl → Clockify に変更 | dc_catalog.data_source 追加のみ。resource 定義変更不要 |
| data_composition | **変更不要** |

---

## 設計決定ログ

### [2026-03] activity エンティティの廃止

**経緯：**

当初、DCMP は**アメーバ管理会計システム**を前提に設計されていた。

| 概念 | 元の意味 |
|------|---------|
| owner | アメーバ（永続的な組織単位） |
| activity | プロジェクト（始終のある時間的単位） |
| resource | 勘定科目 |

**Toggl のユースケース分析で露わになった問題：**

1. Toggl の `project` は activity に対応すると考えていたが、実態は多次元だった
   - 何をしていたか（action: coding, meeting）
   - 何のためか（purpose: 副業, 学習）
   - 誰と（context: alone, client）
   - → 単一の activity FK では表現できない

2. `fct_time_records_actual` の `dim_category_time_personal/social` は
   time resource に複数の分類軸を与える試みだったが、
   DWH 内で概念的な解釈を行っていた（DWH = 事実 原則に違反）

3. 「サービス名を隠して概念統合する」役割を fct 層が担おうとしていたが、
   それは resource 階層（DCMP）の仕事であることが判明

**決定：**

- `activity` エンティティを廃止
- `event.activity_id` を削除
- プロジェクト的な時間的文脈 → `scenario + valid_time` で表現
- 多次元分類 → `observation.attrs` に一般化（全 resource に適用可能）
- アメーバ前提（owner, activity のアメーバ経営的意味づけ）を排除

**DWH への影響：**

- `dim_category_time_*` は DWH に残す（DWH 固有の分類ルール）
- fct で解決した category 値を App 層が `observation.attrs` に転記する
- fct の責務は FK 解決（非正規化）のみ。概念統合・dedup は行わない
- `fct_time_records_actual` → `rpt_time_records_continuous` に改名（可視化専用 VIEW）
- `fct_toggl_time_entries` を新設（TABLE、合成行なし、project/tags 非正規化）

### [2026-03] 会計・在庫を独立した beancount インスタンスに委任

**背景：**

当初、金銭フロー（収入・支出）を `resource` 階層（`r-money-income` / `r-money-expense`）で表現しようとしていた。
また、食料品在庫を DCMP の `balance_type: stock` resource で管理しようとしていた。

**洞察：**

> 会計とはお金・権利・義務の残数管理と払い出しである。

beancount の複式簿記モデルは「残数管理 + 払い出し」の汎用エンジン。
「複数通貨」とは JPY / USD だけでなく、`MONSTER-RR / CARB-G / KCAL` のような任意 commodity も含む。
ただし **会計と在庫では費用認識のタイミングが異なる** ため、インスタンスを分離する。

| | 会計 beancount | 在庫 beancount |
|--|---------------|---------------|
| 扱うもの | お金・権利・義務（JPY 等） | 物品・栄養素（commodity） |
| 費用認識 | 購入時（食費を計上） | 摂取時（栄養を計上） |
| balance制約 | 有り（借方＝貸方） | 不要（commodity間の換算が不定） |

**決定：**

**[gerdemb/beanpost](https://github.com/gerdemb/beanpost)** を Neon 上に2インスタンスデプロイする。
DCMP は両インスタンスの Posting UUID を `record_id` として参照し、同一 event に束ねる。

```
[会計 beanpost] ← 金銭・権利・義務の残数管理
  Assets:Cash:Wallet           ← 現金
  Assets:Bank:*                ← 銀行口座（複数通貨対応）
  Liabilities:CreditCard:*     ← クレジットカード
  Expenses:Food:*              ← 食費（購入時に計上）
  Expenses:Transport:*         ← 交通費
  Income:*                     ← 収入

[在庫 beanpost] ← 物品の残数管理
  Assets:Grocery:MonsterRR     ← 食品在庫（commodity: 品名コード）
  Assets:Grocery:Egg
  Expenses:Nutrition:Energy    ← 栄養摂取（摂取時に計上, commodity: KCAL）
  Expenses:Nutrition:Carb      ← 栄養摂取（commodity: CARB-G）

[DCMP] ← 共起の記述のみ
  → 両 beanpost の Posting UUID を record_id として参照
  → 値を持たない
```

**仕訳例：**

```beancount
; === 会計 beanpost ===
; 購入時に食費を計上（金銭の動きのみ）
2026-03-10 * "Monster購入" "コンビニ"
  Assets:Cash:Wallet   -640 JPY
  Expenses:Food:Drink  +640 JPY

; === 在庫 beanpost ===
; 入庫（購入時）: food / 入庫相手勘定
2026-03-10 * "Monster入庫"
  Assets:Food:MonsterRR      +2 MONSTER-RR
  Equity:FoodReceipt:Monster -2 MONSTER-RR   ; 入庫相手勘定

; 食事（自炊）: 栄養 / food  ← 在庫を崩して栄養に変換（App が resource_link で自動生成）
2026-03-10 * "Monster摂取"
  Expenses:Nutrition:Carb    +3.195 CARB-G
  Expenses:Nutrition:SaltEq  +0.817 SALT-G
  Assets:Food:MonsterRR      -1 MONSTER-RR   ; 在庫を減らす

; 外食: 栄養 / 食事相手勘定  ← 在庫を介さず直接計上
2026-03-10 * "ランチ" "定食屋"
  Expenses:Nutrition:Energy  +680 KCAL
  Expenses:Nutrition:Carb    +85 CARB-G
  Equity:MealReceipt:Lunch   -1 MEAL        ; 食事相手勘定（ダミー）
```

→ `Expenses:Nutrition:*` を集計すれば、自炊・外食問わず全栄養摂取量が揃う。

**DCMP の observation：**

```
event: Monster 購入（2026-03-10）
├── observation(resource=r-money,   record_id → 会計.Posting: Assets:Cash:Wallet -640 JPY)
├── observation(resource=r-money,   record_id → 会計.Posting: Expenses:Food:Drink +640 JPY)
└── observation(resource=r-grocery, record_id → 在庫.Posting: Assets:Grocery:MonsterRR +2)

event: Monster 飲む（2026-03-10）
├── observation(resource=r-grocery,   record_id → 在庫.Posting: Assets:Grocery:MonsterRR -1)
├── observation(resource=r-nutrition, record_id → 在庫.Posting: Expenses:Nutrition:Carb +3.195)
└── observation(resource=r-time,      record_id → neon.fct_toggl_time_entries)
```

→ 購入 event と摂取 event が別になることで、「いつ買ったか」と「いつ食べたか」が独立して記録される。

**food → 栄養の変換比率テーブルの置き場所：**

変換比率（1 MONSTER-RR = carb 3.195g + salt 0.817g）は在庫帳簿の内部知識であり、
DCMPに置く必要はない。在庫 beanpost の PostgreSQL スキーマに companion table として持つ。

```sql
-- 在庫 beanpost スキーマ内（DCMP ではない）
food_nutrition_ratio(commodity, nutrient, ratio)
-- e.g. ('MONSTER-RR', 'CARB-G', 3.195)
--      ('MONSTER-RR', 'SALT-G', 0.817)
```

App はこのテーブルを参照して、摂取 transaction を自動生成する：

```beancount
; App が food_nutrition_ratio を読んで生成
2026-03-10 * "Monster摂取"
  Expenses:Nutrition:Carb    +3.195 CARB-G
  Expenses:Nutrition:SaltEq  +0.817 SALT-G
  Assets:Food:MonsterRR      -1 MONSTER-RR
```

**→ `resource_link` は DCMP スキーマから削除。変換ロジックは在庫システムに閉じる。**

**DCMP の resource から削除するもの：**

- `r-money-income` / `r-money-expense`（勘定科目詳細は 会計 beanpost に委任）
- `balance_type` カラム（残数管理は beanpost が担う。DCMP には不要）
- `resource_link` テーブル（変換比率は在庫 beanpost の companion table に移動）

**resource 階層に残るもの：**

| resource | 役割 |
|---------|------|
| `r-time` / `r-time-work` / `r-time-life` | 時間（observation のアンカー） |
| `r-grocery` / beverage / 個別食品 | resource_link のアンカー + 在庫観測のアンカー |
| `r-nutrition` / energy / protein / ... | 栄養（observation のアンカー） |
| `r-money` | 金銭（observation のアンカー。勘定科目詳細は 会計 beanpost） |

**移行計画：**

- 会計 beanpost / 在庫 beanpost を Neon 上にデプロイ（スキーマ適用）
- Zaim → 会計 beanpost への ETL（過去データの変換）
- beanpost の導入完了まで Zaim を継続利用し、4月以降に切り替えを検討

---

### [2026-03] XTDB bi-temporal は必須 — 事実層と解釈層の分離

**問い：** composition 層を XTDB で別管理する意義はあるか？Neon に統合すれば済むのでは？

**検討：**

- Neon（beanpost）のすべてのスキーマを bi-temporal にすることはできない
- beanpost は PL/pgSQL 関数に依存しており XTDB 上では動作しない
- しかし event / observation（解釈）は事後修正・訂正が本質的に必要

**決定：**

> 事実（Neon）は不変。解釈（XTDB）だけが bi-temporal であればよい。

- **Neon** = 事実の格納。DWH、会計帳簿、在庫帳簿。修正されない。
- **XTDB** = 解釈の格納。event と observation は事後的に意味を変えうる。
  bi-temporal により「いつ解釈されたか」「いつ修正されたか」の履歴を保持。

全システムの bi-temporal 化は不可能であるため、
解釈層だけを XTDB に分離するのが合理的な設計である。

---

### [2026-03] DWH スキーマ分割

**決定：**

```
schema: data_warehouse    ← raw_*, stg_*, dim_*（DWH 内部実装）
schema: data_presentation ← fct_*（DCMP・App への公開 API）
```

DCMP は `data_presentation.*` のみ参照。
権限分離・契約の明確化・fct が将来変わっても参照先が変わらない安定性を確保。

---

## 運用フェーズ

### Phase 1: ～2026年3月（現在）
- grocery / nutrition の記録を開始
- 金銭管理は Zaim で継続（Neon に同期済み）
- XTDB（DCMP）をローカル Docker で稼働
- UI は後回し

### Phase 2: 2026年4月～
- Zaim 3月末残高を opening balance event として投入
- monetary resource ツリー（収入・支出科目）を作成
- grocery/nutrition + monetary の統合運用を開始

---

## 技術スタック

| 層 | 技術 | 役割 |
|----|------|------|
| DWH | Neon (PostgreSQL) | 事実の格納。外部 API パイプライン + 手入力 |
| カタログ | XTDB v2 xtdb-catalog（Docker → Fly.io） | DWH メタデータ・サロゲートキー発行 |
| DCMP | XTDB v2 xtdb-dcmp（Docker → Fly.io） | 意味付け・共起・分類 |
| API | Hono（TypeScript、Vercel Serverless） | App 層 |
| UI | Next.js（Vercel） | フロントエンド |
| 検証 | Zod | アプリ層スキーマ検証 |

## リポジトリ構成

```
data-composition/
├── docker-compose.yml           # XTDB v2 × 2（catalog: 5433, dcmp: 5432）
├── docs/
│   └── 000_project_overview.md  # このファイル（現行設計）
└── seed/
    ├── dc_catalog.sql           # dc_catalog DB 初期データ
    └── 001_master.sql           # data_composition DB 初期データ
```
