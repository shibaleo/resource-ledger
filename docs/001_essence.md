# Resource Ledger — 設計の本質

あらゆるリソースの変動事実を統一的に記録するための構造パターンを整理する。

## 根底にある目的

このシステムの存在理由は **よりよい意思決定** にある。そのために:

- リソースの変動事実を統一的に記録する
- 過去の意思決定時に何のデータが利用可能だったかを再現できる
- 目標設定自体の振り返りと検証ができる

## 技術スタック

| 層 | 技術 | 役割 |
|---|---|---|
| DB | **XTDB v2** | bi-temporal DB。Docker コンテナとして稼働 |
| プロトコル | **pgwire** | PostgreSQL 互換ワイヤープロトコル |
| クエリ | **SQL** | XTDB SQL（SQL:2011 temporal 拡張） |
| API | **Hono** (TypeScript) | REST API。Vercel Serverless にデプロイ |
| UI | **Next.js** | フロントエンド。Vercel にデプロイ |
| スキーマ検証 | **Zod** | アプリ層でのバリデーション |
| ストレージ | **ローカルディスク** | XTDB v2 のデフォルト。Apache Arrow 形式 |
| デプロイ | **Docker** → **Vercel + VPS** | ローカル: Docker / 本番: XTDB on VPS, API+UI on Vercel |

### テーブルモデル

XTDB v2 はスキーマレス。CREATE TABLE なしで INSERT すればテーブルが自動作成される。すべての行は `_id` を持つ:

```sql
INSERT INTO entry (_id, event_id, owner_id, delta, _valid_from)
VALUES (gen_random_uuid(), '...', '...', 3000, TIMESTAMP '2025-05-15 12:00:00');
-- → entry テーブルが自動作成される
```

スキーマ検証はアプリ層（Zod）で行う。

### bi-temporal

XTDB v2 はすべての行に4つの時間列を自動付与する:

- **_system_from / _system_to**: いつ DB に書き込まれたか（不変。改竄不可能。自動）
- **_valid_from / _valid_to**: いつに帰属するか（INSERT 時にアプリが指定。後から修正可能）

これにより:

- entry の監査証跡・訂正履歴は system-time が自動保証する
- dimension テーブル（resource, owner, activity 等）の変更履歴も自動追跡される
- 「あの時はあの集計軸で、あのデータを見て意思決定していた」を SQL クエリだけで完全に復元できる

---

# Part 1: 設計

## 1. 中核パターン: 変動台帳（Delta Ledger）

本モデルの最も本質的な構造は「**変動の記録から状態を導出する**」パターン。

```
event (なぜ変わったか)
  └── entry (何がいくら変わったか)
        ↓ 集計
      balance (今いくらか)           ← 導出クエリ（ストック）
      period-sum (期間にいくら動いたか) ← 導出クエリ（フロー）
```

1つの event が複数の entry を生成するのが一般的。会計的な用途では1取引あたり 3〜5 entry になることが多い。

### entry から導出されるもの

| 導出 | 集計方法 | 用途 |
|------|----------|------|
| **balance** | `FOR VALID_TIME AS OF` でスナップショット → SUM | ストック性のあるリソースの残高 |
| **期間集計** | `_valid_from` で範囲フィルタ → SUM | フロー性のあるリソースの消費量・収支 |
| **track 間比較** | track 別 SUM の差分 | 見積精度の検証、予実差異分析 |
| **時系列推移** | valid-time 軸での集計 | トレンド把握 |

残高（balance）が有意味なのは「貯蔵」があるリソース — 獲得と消費の間に時間的ギャップがあり、その間にストックが存在するもの（Fisher の stock/flow 区分）。すべてのリソースに残高管理が必要なわけではない。

### 時間モデル: bi-temporal

XTDB が管理する2つの時間軸:

```
system-time  = いつ DB に書き込まれたか（不変。自動。改竄不可能）
valid-time   = いつに帰属するか（INSERT 時にアプリが指定。後から修正可能）
```

この分離により:

- **後追い記録**: 12:00 の食事を 19:00 に記録 → _valid_from=12:00, _system_from=19:00（自動）
- **過去の計画の復元**: system-time で「3/1 時点で DB に存在していたデータ」を復元
- **遡及修正の透明性**: UPDATE しても、修正前の状態は system-time で完全に復元可能

```sql
-- 12:00 の食事を 19:00 に記録
INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev_id, :me_id, :bread_id, 'actual', -1,
        TIMESTAMP '2025-05-15 12:00:00');
-- _system_from は 19:00 が自動記録される
```

entry に日付列は持たない。帰属時点は `_valid_from` が担う。期間クエリは `_valid_from` でフィルタする:

```sql
-- 5月の entry を valid-time で範囲フィルタ
SELECT _id, delta FROM entry
WHERE _valid_from >= TIMESTAMP '2025-05-01'
  AND _valid_from <  TIMESTAMP '2025-06-01';
```

### 訂正パターン

entry の訂正は UPDATE / DELETE で行う。system-time が修正前の状態を自動保存する。

| 訂正の意図 | 操作 | 効果 |
|-----------|------|------|
| 金額訂正 | `UPDATE entry SET delta = 3500 WHERE _id = :id` | 残高が修正される。旧値は system-time に残る |
| 帰属時点の変更 | DELETE + INSERT（新しい _valid_from で） | 帰属時点が移動する。旧状態は system-time に残る |
| 当期調整 | 新しい entry を INSERT（_valid_from = 今日、差額のみ） | 過去の残高は不変。差額は当期に計上 |
| 取消 | `DELETE FROM entry WHERE _id = :id` | entry が無効化される。存在していた事実は system-time に残る |

```sql
-- 金額訂正: 3000 → 3500
UPDATE entry SET delta = 3500 WHERE _id = :entry_id;
-- → system-time に旧値 (3000) が自動保存

-- 取消
DELETE FROM entry WHERE _id = :entry_id;
```

「修正前はどうだったか」の復元:

```sql
-- 6/10 に修正したが、3/1 時点では何が見えていたか？
SELECT _id, delta FROM entry
  FOR VALID_TIME AS OF TIMESTAMP '2025-05-15'
  FOR SYSTEM_TIME AS OF TIMESTAMP '2025-03-01'
WHERE resource_id = :food_id;
```

### 構造要素

| 要素 | 理由 |
|------|------|
| event → entry の 1:N 構造 | 変動の因果関係（なぜこの entry が存在するか）を保証 |
| system-time（XTDB 自動） | 監査証跡と時点復元の前提 |
| _valid_from（INSERT 時に指定） | 業務時間の帰属。entry の列としては持たない（XTDB が管理） |
| event の idempotency_key | 重複投入防止。アプリ層で検証（UNIQUE 制約は XTDB v2 未サポート） |
| resource の unit_id → unit_master 参照 | 単位の正規化。自由文字列による揺れ（h/hour/hours）を防止 |
| resource の parent_id → 階層構造 | 分類はツリーの中間ノードで表現。classification 属性は不要 |
| delta (NUMERIC) | 金額・時間・数量を統一的に扱う |
| delta != 0 制約 | 無意味なレコードの排除（アプリ層で検証） |

---

## 2. 多次元交点: キューブ構造

各 entry は「複数の軸の交点」に位置する。

```
entry = f(owner, activity, valid-time, track, resource)
          ↑       ↑          ↑            ↑       ↑
        誰の    何のため   いつの      記録文脈   何のリソース
```

### 6つの軸

| # | 軸 | 問い | 管理 |
|---|---|---|---|
| 1 | **owner** | 誰が責任を持つか | entry.owner_id |
| 2 | **activity** | 何のためか（nullable） | entry.activity_id |
| 3 | **valid-time** | いつに帰属するか | XTDB _valid_from（INSERT 時に指定） |
| 4 | **track** | どの記録文脈か（resource 別に定義） | entry.track |
| 5 | **resource** | 何のリソースか | entry.resource_id |
| 6 | **event** | なぜ変わったか | entry.event_id |

### 軸の分類

| 分類 | 軸 | 特徴 |
|------|---|------|
| **構造軸**（参照あり） | owner, activity, resource, event, track | 他テーブルへの参照 |
| **時間軸**（XTDB 管理） | valid-time | INSERT 時にアプリが指定。SQL で `_valid_from` として参照 |

ドメイン固有の補足情報（対象メンバー、取引先等）は attrs（JSON）に自由に格納する。コアスキーマに polymorphic 参照は持たない。

### entry の構造

```sql
-- entry の INSERT 例
INSERT INTO entry (
  _id,             -- UUID PK
  event_id,        -- なぜ（→ event）
  owner_id,        -- 誰が（→ owner）
  activity_id,     -- 何のために（→ activity, nullable）
  resource_id,     -- 何の（→ resource）
  track,           -- どの文脈で（→ track_master._id）
  delta,           -- いくら（NUMERIC, != 0）
  attrs,           -- 補足（nullable, JSON）
  _valid_from      -- いつに帰属するか（XTDB が管理）
) VALUES (
  gen_random_uuid(), :ev_id, :owner_id, :activity_id,
  :resource_id, 'actual', 3000, '{"member": "tanaka-id"}',
  TIMESTAMP '2025-05-15 12:00:00'
);
-- _system_from は自動記録（不変）
```

### 符号規約

- **正**: リソースの増加（収入、資産増、取得）
- **負**: リソースの減少（支出、資産減、消費）
- 会計アプリでは resource ツリーの分類（中間ノード）に応じて表示上の正負を解釈する。DB 上の符号規約は統一

---

## 3. トラック: resource 別の記録文脈

### track とは

track は entry の「記録文脈」を表す軸。「リソースが実際に動いた」事実と「予算としてこの値を設定した」事実を、同一リソース上で区別する。

**すべての entry は事実である。** track が区別するのは事実の種類:

| track の例 | 記録される事実 |
|------------|---------------|
| actual | リソースが動いた事実（食費 3,000円を支出した） |
| monthly_budget | 月次予算を設定した事実（食費の月予算を 30,000円にした） |
| quarterly_target | 四半期目標を設定した事実（売上目標を 500万にした） |
| weekly_capacity | 週次キャパシティを定義した事実（稼働可能時間を 40h にした） |

「計画は事実ではない」のではなく、**「計画を立てたこと」は事実**。過去の見積精度を検証するには、計画データが事実として不変に残っていることが前提になる。

### なぜ resource 別か

track の種類は resource ごとに異なる。全 resource に共通の track セットを強制できない:

| resource | 有効な track | 理由 |
|----------|-------------|------|
| 食費 | actual, monthly_budget | 月次予算管理 |
| 工数 | actual, weekly_capacity | 週次キャパシティ管理 |
| 食パン | actual | 在庫のみ。予算は不要 |
| 売上 | actual, quarterly_target, revised_target | 四半期目標 + 見直し |

### track_master と resource_track

```sql
-- track_master: track の種類を定義
INSERT INTO track_master (_id, name, granularity) VALUES
  ('actual',           'actual',           'point'),
  ('monthly_budget',   'monthly_budget',   'month'),
  ('weekly_capacity',  'weekly_capacity',  'week'),
  ('quarterly_target', 'quarterly_target', 'quarter');

-- resource_track: resource ごとに許可する track を定義
INSERT INTO resource_track (_id, resource_id, track_id) VALUES
  (gen_random_uuid(), :food_expense_id, 'actual'),
  (gen_random_uuid(), :food_expense_id, 'monthly_budget');
-- → entry の track はこの組み合わせのみ許可（アプリ層で検証）
```

### resource ツリーの純粋性

track を resource 別に制御することで、**resource ツリーはドメインの存在論のみを反映する**:

```
✗ 汚染されたツリー          ✓ 純粋なツリー
monetary                     monetary
├── 食費                     ├── 食費         ← track で actual / budget を区別
├── 食費_予算                ├── 家賃
├── 食費_見込                └── 光熱費
├── 家賃
├── 家賃_予算
└── ...
```

### entry の時間モデル

track によって _valid_from の時間的な意味が異なる。track_master の granularity がこれを定義する:

| granularity | _valid_from の解釈 | 例 |
|-------------|-------------------|-----|
| point | 時刻（いつ発生したか） | 12:00 に昼食 |
| day | 日（その日に帰属） | 5/15 の食費 |
| week | 週の初日（その週に帰属） | 第20週のキャパシティ |
| month | 月の初日（その月に帰属） | 5月の予算 |
| quarter | 四半期の初日 | Q2 の売上目標 |

期間の終了は _valid_from + granularity から導出できるため、entry に期間終了を追加する必要はない。

### 設計原則

| 原則 | 説明 |
|------|------|
| actual は必須 | すべての resource に actual が存在する。resource 作成時に自動付与 |
| track は不可侵 | 異なる track の entry は相互に干渉しない。actual の SUM と budget の SUM は独立 |
| 比較はクエリで | track 間の比較方法はアプリ層・BI層が選ぶ |
| 粒度は自由 | 同一 resource でも track ごとに粒度が異なりうる（月次予算 vs 日次実績） |

---

## 4. 階層ディメンション: ツリー構造

主要ディメンション（owner, activity, resource）はすべて階層を持つ。

```
親ノード (is_leaf=false, 集計用・分類用)
├── 子ノード (is_leaf=false, サブ分類)
│   ├── 末端ノード (is_leaf=true, entry 記入可) ★
│   └── 末端ノード (is_leaf=true) ★
└── 末端ノード (is_leaf=true) ★
```

| 要素 | 理由 |
|------|------|
| parent_id による自己参照 | ドリルダウン・集計の軸 |
| is_leaf フラグ | 新規 entry の書き込み制御（二重計上防止） |
| 中間ノード = 分類 | ツリー構造自体が分類を表現する。classification 等の属性は不要 |

- `is_leaf` は **書き込み制御**であり、データ制約ではない。INSERT 時に `is_leaf = true` を検証する（アプリ層）
- リーフが非リーフに変わっても、過去の entry は有効。合算は親ノードに自然に吸収される
- 「expense 配下の全 entry」等の分類クエリは再帰 CTE で走査する:

```sql
-- ancestor クエリ（expense ノード配下の全 entry を集計）
WITH RECURSIVE descendants AS (
  -- 起点: expense ノード自身
  SELECT _id FROM resource WHERE _id = :expense_node_id
  UNION ALL
  -- 再帰: 子ノードを辿る
  SELECT r._id FROM resource r
  JOIN descendants d ON r.parent_id = d._id
)
SELECT e._id, e.delta
FROM entry e
JOIN descendants d ON e.resource_id = d._id;
```

### 階層の変更: リーフの分割

リーフノードを子に分割する場合（例: bank_acc → bk1, bk2）:

1. 元のリーフの is_leaf を false に変更（UPDATE。valid-time で変更時点を記録）
2. 新しい子リーフを INSERT
3. 振替 event で元のリーフの残高を子リーフに移動

```sql
-- 1. 元のリーフを非リーフに変更
UPDATE resource SET is_leaf = false WHERE _id = :bank_acc_id;

-- 2. 新しい子リーフを追加
INSERT INTO resource (_id, cd, name, parent_id, is_leaf, category, unit_id)
VALUES (:bk1_id, 'bk1', 'bk1', :bank_acc_id, true, 'monetary', :jpy_id),
       (:bk2_id, 'bk2', 'bk2', :bank_acc_id, true, 'monetary', :jpy_id);

-- 3. 振替 event + entries
INSERT INTO event (_id, description) VALUES (:ev_id, '銀行口座の分割');

INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev_id, :owner_id, :bank_acc_id, 'actual', -500000,
        TIMESTAMP '2025-06-01'),
       (gen_random_uuid(), :ev_id, :owner_id, :bk1_id, 'actual', 300000,
        TIMESTAMP '2025-06-01'),
       (gen_random_uuid(), :ev_id, :owner_id, :bk2_id, 'actual', 200000,
        TIMESTAMP '2025-06-01');
```

分割前の is_leaf=true の状態は system-time で復元可能。

### dimension の変更履歴

owner, activity, resource の変更（名称変更、階層の組み替え等）は UPDATE で行う。XTDB の bi-temporal により自動追跡される。

過去の任意の時点で「どの集計軸でデータを見ていたか」を再現できるため、意思決定時の文脈を完全に復元できる。

---

## 5. 統合の鍵: resource

「金額の科目」と「業務量の単位」を単一のツリーに統一する。

```
entry.resource_id → resource（階層、カテゴリ分類）
entry.track       → track_master（記録文脈）
resource.unit_id  → unit_master（単位の正規化）
```

### 統合で得られるもの

- **単一テーブルで全リソースを記録** — クエリが統一的
- **新リソース種別の追加がレコード追加のみ** — スキーマ変更不要
- **balance が統一的** — resource_id で WHERE すれば種別ごとの残高
- **track が resource 別** — 予算・目標・キャパシティ等を resource の性質に応じて定義

### 統合で注意すべきこと

- **型安全性**: balance は resource 単位で集計するため、単位混在は発生しない。階層ロールアップはクエリ/BI層の責務
- **会計的な制約（貸借検証等）**: コアスキーマには含めない。拡張クエリで対応

---

## 6. コアスキーマと拡張の境界

### コアスキーマの責務: 集計のための最小構造

コアスキーマのテーブルは「entry の記録・集計に必要な最小構造」だけを持つ。業務的な意味は拡張テーブルが付与する。

すべての行に _valid_from / _valid_to / _system_from / _system_to が XTDB により自動付与される。

| テーブル | 列 | 役割 |
|---------|---------|------|
| **event** | _id, idempotency_key, description | entry の存在理由 |
| **entry** | _id, event_id, owner_id, activity_id, resource_id, track, delta, attrs | リソース変動の事実 |
| **owner** | _id, parent_id, is_leaf, cd, name | 責任主体（階層） |
| **activity** | _id, parent_id, is_leaf, cd, name | 活動（階層） |
| **resource** | _id, parent_id, is_leaf, cd, name, category, unit_id | リソース種別（階層。分類はツリー構造で表現） |
| **unit_master** | _id, name | 単位の正規化 |
| **track_master** | _id, name, granularity | 記録文脈の種類 |
| **resource_track** | _id, resource_id, track_id | resource ごとの許可 track |

### Zod スキーマ（TypeScript）

```typescript
import { z } from 'zod';

const Entry = z.object({
  _id:          z.string().uuid(),
  event_id:     z.string().uuid(),
  owner_id:     z.string().uuid(),
  activity_id:  z.string().uuid().nullable(),
  resource_id:  z.string().uuid(),
  track:        z.string(),            // track_master._id
  delta:        z.number().refine(v => v !== 0),
  attrs:        z.record(z.unknown()).nullable(),
});

const Event = z.object({
  _id:              z.string().uuid(),
  description:      z.string(),
  idempotency_key:  z.string().optional(),
});

const Resource = z.object({
  _id:       z.string().uuid(),
  parent_id: z.string().uuid().nullable(),
  is_leaf:   z.boolean(),
  cd:        z.string(),
  name:      z.string(),
  category:  z.string(),              // monetary / labor / material 等
  unit_id:   z.string().uuid(),
});

const Owner = z.object({
  _id:       z.string().uuid(),
  parent_id: z.string().uuid().nullable(),
  is_leaf:   z.boolean(),
  cd:        z.string(),
  name:      z.string(),
});

const Activity = z.object({
  _id:       z.string().uuid(),
  parent_id: z.string().uuid().nullable(),
  is_leaf:   z.boolean(),
  cd:        z.string(),
  name:      z.string(),
});

const UnitMaster = z.object({
  _id:  z.string().uuid(),
  name: z.string(),
});

const TrackMaster = z.object({
  _id:         z.string(),             // 'actual', 'monthly_budget' 等
  name:        z.string(),
  granularity: z.enum(['point', 'day', 'week', 'month', 'quarter']),
});
```

### 拡張テーブルで対応する領域

同じ XTDB インスタンス内にコアスキーマとは別のテーブルとして定義する。

| 関心事 | 例 | 拡張パターン |
|--------|---|------|
| ディメンションの業務属性 | activity の状態・期間・分類 | 列追加、または別テーブル |
| 対象の実体 | メンバー、取引先、材料 | attrs が参照するテーブル |
| 契約管理 | 受注、発注、請求 | 別テーブル。activity_id で紐付け |
| リソース間の導出関係 | 食品→栄養素の変換 | food_nutrition_profile 等のマッピングテーブル |
| 貸借検証 | 借方合計 = 貸方合計 | クエリで検証 |

---

# Part 2: ユースケース

## UC1. 食品・栄養管理

食品の購入と消費を entry で記録し、栄養素は拡張テーブル経由で導出する。

### 軸のマッピング

| 軸 | 割り当て |
|---|---|
| owner | 自分（個人） |
| activity | lunch, dinner 等の食事イベント（nullable） |
| resource | 食パン, 鶏むね肉, 卵 等の食品（category=grocery） |
| track | actual のみ |

### resource ツリー

```
grocery (category=grocery)
├── grains
│   ├── 食パン (unit=枚) ★leaf
│   └── ご飯 (unit=g) ★leaf
├── meat
│   ├── 鶏むね肉 (unit=g) ★leaf
│   └── 豚ロース (unit=g) ★leaf
└── dairy
    ├── 卵 (unit=個) ★leaf
    └── 牛乳 (unit=mL) ★leaf
```

### entry の例

```sql
-- 食品購入（6枚入りの食パン）
INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev1, :me, :bread_id, 'actual', 6,
        TIMESTAMP '2025-05-15 10:00:00');

-- 昼食（12:00に食べたが19:00に記録）
INSERT INTO entry (_id, event_id, owner_id, resource_id, activity_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev2, :me, :bread_id, :lunch_id, 'actual', -1,
        TIMESTAMP '2025-05-15 12:00:00');
-- → _system_from は 19:00 が自動記録
```

### 栄養素の導出（拡張テーブル）

```sql
-- food_nutrition_profile テーブル
INSERT INTO food_nutrition_profile (_id, resource_id, nutrient, factor)
VALUES (gen_random_uuid(), :bread_id, 'protein', 2.7);  -- 1枚あたり 2.7g

-- 1日の栄養摂取クエリ
SELECT fnp.nutrient, SUM(ABS(e.delta) * fnp.factor) AS intake
FROM entry e
JOIN food_nutrition_profile fnp ON e.resource_id = fnp.resource_id
WHERE e.delta < 0
  AND e._valid_from >= TIMESTAMP '2025-05-15'
  AND e._valid_from <  TIMESTAMP '2025-05-16'
GROUP BY fnp.nutrient;
```

### 設計上のポイント

- entry は食品単位で記録する。栄養素はクエリ時に導出する
- 食品の balance = 在庫（ストック）。残高管理が有意味
- 栄養素に残高管理は不要。期間集計（1日の摂取量）が主要な関心

---

## UC2. 個人の収支管理

収入・支出を記録し、月次予算と比較する。

### resource ツリーと track

```
収入
├── 給与 ★leaf         track: actual
└── 副収入 ★leaf       track: actual
支出
├── 食費 ★leaf         track: actual, monthly_budget
├── 家賃 ★leaf         track: actual, monthly_budget
└── 光熱費 ★leaf       track: actual, monthly_budget
```

### 予算 vs 実績の比較

```sql
SELECT r.name, e.track, SUM(e.delta) AS total
FROM entry e
JOIN resource r ON e.resource_id = r._id
WHERE e._valid_from >= TIMESTAMP '2025-05-01'
  AND e._valid_from <  TIMESTAMP '2025-06-01'
GROUP BY r.name, e.track;
-- => ('食費', 'actual',         -28000)
--    ('食費', 'monthly_budget', -30000)
--    ...
```

### 予算の訂正

```sql
-- 5月の食費予算を 30,000 → 35,000 に修正（同一 _id で UPDATE）
UPDATE entry SET delta = -35000 WHERE _id = :budget_entry_id;
-- → system-time に旧値 (-30000) が自動保存
```

---

## UC3. 会計（B/S + P/L）

資産・負債・純資産・収益・費用の全5分類を追跡する。

### resource ツリー

```
monetary (category=monetary, unit=JPY)
├── revenue                    ← 中間ノード = 分類
│   └── 純売上高 ★leaf
├── expense
│   ├── 外注仕入 ★leaf
│   └── 一般管理費 ★leaf
├── asset
│   ├── 現金 ★leaf
│   ├── 銀行預金 ★leaf
│   └── 売掛金 ★leaf
├── liability
│   └── 未払費用 ★leaf
└── equity
    └── 純資産 ★leaf
labor (category=labor)
├── hours (unit=h) ★leaf       ← 対象メンバーは attrs で記録
└── person_months (unit=PM) ★leaf
```

### 日常取引の例

```sql
-- 売上計上
INSERT INTO event (_id, description) VALUES (:ev_id, '売上計上');

INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev_id, :dept_id, :net_sales_id, 'actual', 100000,
        TIMESTAMP '2025-05-15'),
       (gen_random_uuid(), :ev_id, :dept_id, :ar_id, 'actual', 100000,
        TIMESTAMP '2025-05-15');

-- 外注費支払
INSERT INTO event (_id, description) VALUES (:ev2_id, '外注費支払');

INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES (gen_random_uuid(), :ev2_id, :dept_id, :outsource_id, 'actual', 50000,
        TIMESTAMP '2025-05-15'),
       (gen_random_uuid(), :ev2_id, :dept_id, :bank_id, 'actual', -50000,
        TIMESTAMP '2025-05-15');
```

### 設計上のポイント

- 貸借の整合性はコアスキーマでは強制しない。拡張クエリで対応
- 1つの event が P/L + B/S + 労務を横断して entry を生成する。これが resource 統合の利点

---

## UC4. クロスドメイン: 食品購入 × 会計

1つの event が monetary と grocery を横断する:

```sql
INSERT INTO event (_id, description) VALUES (:ev_id, 'スーパーで食品購入');

INSERT INTO entry (_id, event_id, owner_id, resource_id, track, delta, _valid_from)
VALUES
  -- monetary entries
  (gen_random_uuid(), :ev_id, :me, :food_expense_id,    'actual',  3000,
   TIMESTAMP '2025-05-15 10:00:00'),
  (gen_random_uuid(), :ev_id, :me, :credit_payable_id,  'actual',  3000,
   TIMESTAMP '2025-05-15 10:00:00'),
  -- grocery entries
  (gen_random_uuid(), :ev_id, :me, :bread_id,    'actual', 6,
   TIMESTAMP '2025-05-15 10:00:00'),
  (gen_random_uuid(), :ev_id, :me, :chicken_id,  'actual', 500,
   TIMESTAMP '2025-05-15 10:00:00'),
  (gen_random_uuid(), :ev_id, :me, :egg_id,      'actual', 10,
   TIMESTAMP '2025-05-15 10:00:00');
```

栄養素は food_nutrition_profile 経由でクエリ時に導出。

---

## まとめ

```
┌──────────────────────────────────────────────────┐
│                  resource-ledger                   │
│                                                    │
│  event ──1:N──> entry ──集計──> balance            │
│                  │              period-sum          │
│            ┌─────┼─────┐      track比較           │
│            ↓     ↓     ↓                          │
│         owner activity resource                    │
│         (tree) (tree)   (tree)                     │
│                           │                        │
│                     resource_track                  │
│                           │                        │
│                     track_master                    │
│                                                    │
│  _valid_from: 帰属時点（INSERT 時にアプリが指定）  │
│  _system_from: 記録時点（XTDB 自動、不変）        │
│  track: resource別に定義（actual は必須）           │
│                                                    │
│  技術スタック:                                      │
│    XTDB v2 (Docker/VPS) + Hono + Next.js           │
│    SQL (pgwire) / Zod / Vercel                     │
└──────────────────────────────────────────────────┘
```

| 本質 | コメント |
|------|----------|
| 変動台帳 | 残高・期間集計は entry の SUM。訂正は UPDATE/DELETE |
| 多次元交点 | 誰が × 何のために × いつ × 何のリソース |
| resource別トラック | 記録文脈は resource ごとに定義。すべての entry は事実 |
| 階層集計 | ドリルダウン可能な木構造。再帰 CTE で走査 |
| 統一リソース | 金額も食品も時間も同じ構造で記録 |
| bi-temporal | valid-time（業務時間）+ system-time（監査）。XTDB v2 がネイティブに保証 |
