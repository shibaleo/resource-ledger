# data-composition (DCMP) 設計概要

## システムの役割

あらゆるデータソースの観測を**資源分類と共起関係によって意味付けする**層。
値（数値・ベクトル・テキスト）は持たない。値の実体はすべて data_warehouse（Neon）が持つ。

> **スコープの境界**
> - DCMP = 共起の記述（「これらの観測は同じ出来事だ」という宣言）
> - 因果推論 = DCMP の次のレイヤー（将来拡張。現在は対象外）

---

## 層の役割分担

```
外部 API（真実の持ち主）
  Zaim / Fitbit / Toggl / Tanita / ...
        ↓  GAS パイプライン

Neon — data_warehouse（本物の倉庫）
  schema: data_warehouse   ← raw_*, stg_*, dim_*（DWH 内部実装）
  schema: data_presentation ← fct_*（外部公開インターフェース）
  ← 外部 API の事実 + 手入力の源泉 + App が書き戻す派生値

App 層
  ← Neon を読み、resource_link ルールを適用して派生値を計算 → Neon に書き戻す
  ← dc_catalog に record を登録（遅延）
  ← DCMP に event / observation を作成する
  ← DWH の分類情報（fct の attrs 相当カラム）を observation.attrs に転記する

XTDB — dc_catalog（インフラカタログ）※ 別 DB
  ← data_source: DWH テーブルの論理名 → 物理 URI マッピング
  ← record: DWH 行ごとの XTDB サロゲートキー発行（DWH の変更を吸収）

XTDB — data_composition（意味付け層）
  ← 値を持たない。共起・分類のみ
  ← DWH の ID を直接知らない（record_id 経由）
  ← scenario: event へのタグ（横断的分析軸 + 期間を持つプロジェクト的文脈）
  ← event: 複数観測が「同一の現実の出来事」であることの宣言
  ← observation: event が record を resource として「観測した」という意味付け行為
  ← resource: 分類オントロジー（階層ツリー）
  ← resource_link: 変換ルールの定義（実行はアプリ層）
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
resource(_id, parent_id, is_leaf, cd, name, unit_id, balance_type)
-- balance_type: 'stock' | 'flow'
-- resource は DCMP で定義。DWH のテーブル構造とは独立。
-- 異なるソース（Toggl/Clockify 等）からの観測が同じ resource に収束する。
```

### resource_link — 変換ルール定義

```sql
resource_link(_id, source_id, target_id, ratio)
-- 実行はアプリ層。結果は Neon に書き戻す。
```

### unit_master

```sql
unit_master(_id, name)
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

### [2026-03] 責務の専門システムへの委任（会計・在庫）

**背景：**

当初、金銭フロー（収入・支出）を `resource` 階層（`r-money-income` / `r-money-expense`）で表現しようとしていた。
また、食料品在庫（何をいくつ持っているか）も resource の `balance_type: stock` で管理しようとしていた。

**問題：**

1. **勘定科目体系は複式簿記の問題** — 資産・負債・純資産・収益・費用の5分類は resource 階層で模倣すべきでない
2. **食料品残高も同様** — 在庫の増減・残数管理は DCMP の責務ではない

**決定：**

各責務を独立した専門システムに委任し、DCMP は「共起の記述」に徹する。

```
[会計システム] beanpost（gerdemb/beanpost）
  → 複式簿記。勘定科目体系（資産/負債/純資産/収益/費用）を管理
  → Posting ごとに UUID → DCMP の record_id として参照

[在庫管理システム] ※ 別途構築（beanpost とは独立）
  → 物品の残数管理（食料品・消耗品など）
  → 行ごとに UUID → DCMP の record_id として参照

[DCMP] data_composition
  → 上記システムの Posting/在庫行を同一 event に紐づけるだけ
  → 値を持たない。共起のみ
```

**採用予定：[gerdemb/beanpost](https://github.com/gerdemb/beanpost)**

- PostgreSQL バックエンドの beancount 実装（Neon 上で動作）
- Account / Transaction / Posting / Price をそのまま Neon に格納
- 残高計算は PostgreSQL 関数として提供

**DCMP の observation との接続イメージ：**

```
event: Monster 購入（2026-03-10）
├── observation(resource=r-grocery,  record_id → 在庫システム.入庫行: MonsterRR +2)
└── observation(resource=r-money,    record_id → beanpost.Posting: Assets:Cash -640 JPY)

event: Monster 飲む（2026-03-10）
├── observation(resource=r-grocery,  record_id → 在庫システム.出庫行: MonsterRR -1)
├── observation(resource=r-energy,   record_id → 在庫システム.栄養派生行: Energy 0 kcal)
└── observation(resource=r-time,     record_id → neon.fct_toggl_time_entries)
```

**`r-grocery` の役割の変化：**

「在庫残高を持つリソース」→「**resource_link のアンカー（変換比率定義のキー）**」

```sql
-- App が在庫出庫を読んで栄養を計算するための変換表
resource_link(source_id='r-monster-rr', target_id='r-energy', ratio=0)
resource_link(source_id='r-monster-rr', target_id='r-carb',   ratio=3.195)
```

**resource 階層に残るもの：**

| resource | 役割 |
|---------|------|
| `r-time` / `r-time-work` / `r-time-life` | 時間リソース（flow） |
| `r-grocery` / beverage / 個別食品 | resource_link のアンカー（残高は在庫システム） |
| `r-nutrition` / energy / protein / ... | 栄養摂取リソース（flow） |
| `r-money` | 金銭観測のアンカー（最小限。勘定科目詳細は beanpost） |

**削除するもの：**

- `r-money-income` / `r-money-expense`（勘定科目詳細は beanpost に委任）

**移行計画：**

- beanpost の Neon へのデプロイ（スキーマ適用）
- Zaim → beanpost への ETL（過去データの変換）
- 在庫管理システムの設計・実装（別途）
- beanpost の導入完了まで Zaim を継続利用し、4月以降に切り替えを検討

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
