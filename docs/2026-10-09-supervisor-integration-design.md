# VLM Supervisor との連携設計 (草案) 2026-10-09

このアプリを、「VLM Supervisor × FlexBE 統合システム」の **Phase 4 (iPhone 上の VLM への問い合わせ)** と **Phase 5 (Shadow Mode での semantic success / failure の判断)** に使うための設計の草案。仕様の原文はユーザーが示したもの (Phase 1〜6)。ここでは、**実験で確かめたこと**と**まだ確かめていないこと**を分けて、インターフェースと進め方を決める。未決の事項は §8 に集めた。

## 1. 位置づけ

- Phase 4: PC の `iphone_client` が、`SupervisorInput` (画像 + コンテキスト) を iPhone に送り、構造化された JSON の応答を受け取る。ロボットには介入しない。
- Phase 5: FlexBE の State が終わった時点で、VLM に「その State の目的は、実世界で達成されたか」を判断させて、ログに残す (Shadow Mode)。`execution_success` (コードが正常終了した) と `task_success` (実世界で目的を達成した) を分ける。
- このアプリの役割は、**「State の説明 + 画像 (+ 数値) → semantic success / failure とそのスコア」を返すこと**。回復行動の選択 (Phase 6) は、ここでは扱わない。

## 2. 実験から分かっていること (設計の前提)

| 分かったこと | 根拠 | 設計への影響 |
|---|---|---|
| 入力は、**「State の説明 (その State が何を目的とするか) + State 終了時の画像 1〜3 枚」**で十分に効く | 最後の 1〜6 枚で AUC 0.83〜0.85 (差なし) | 動画や途中のフレームは送らない。**State 終了時の画像を送る** |
| 途中のフレームは、入れると悪くなる | 途中を含む 4 枚: 0.725。窓での判定: 0.538 | 周期的な判定ではなく、**State の完了時 (またはタイムアウト時) に 1 回判定する** |
| 説明文なし、または画像だけでは判断できない | タスク文なしで AUC 0.5 前後 | **State の説明は必須**の入力 |
| スコアの水準は、タスク (State) ごとにずれる。1 つのしきい値で全部を判定するには、揃える学習かキャリブレーションが要る | プール AUC 0.645、タスクごとの平均 0.794 (学習なし)。学習でプール 0.85 | **State ごとのしきい値を、Shadow Mode のログから決める** (§5) |
| アダプタで精度が上がる (シミュレーションから実機へも転移) | タスクごとの平均 0.79 から 0.88〜0.93 | 公開データで作った基礎アダプタを使い、自前のデータで追加学習する (§6) |
| 失敗の種類 (原因の分類) は、公開データの学習では改善できていない | ベース 52.5%、学習後 45.8% | 今回の API では、失敗の種類を**返さない** (理由の文章は任意) |
| iPhone の応答時間 | 画像 1 枚で約 2 秒、3 枚で約 5〜6 秒 (thinking なし) | Phase 5 (記録だけ) には十分。State ごとに 1 回なので、画像は 1〜3 枚に抑える |
| **関節角度などの数値を渡したときの効果は、未検証** | 評価データに数値が含まれない | §4 の数値ブロックは、**自前データでの比較実験をしてから採用する** |

## 3. インターフェース

### 3.1 リクエスト `POST /v1/supervisor/evaluate`

`multipart/form-data`。画像は JSON に埋め込まず、別のパートにする。認証は既存の Bearer トークン。

- `context` (application/json): 次のスキーマ。
- `image_0`, `image_1`, … (image/jpeg): カメラ画像。時間順。通常は State 終了時の 1 枚 (必要なら、State 開始時の 1 枚を `image_0` に加える)。

```json
{
  "request_id": "uuid",
  "timestamp": "2026-10-09T16:30:00+09:00",
  "state": {
    "name": "CloseGripper",
    "path": "/Pick/CloseGripper",
    "description": "Close the gripper on the target object.",
    "outcome": "done",
    "available_outcomes": ["done", "failed"]
  },
  "task_instruction": "Pick up the red cube and put it into the box.",
  "images": [{"name": "image_0", "role": "state_end", "camera": "realsense_color", "stamp": "..."}],
  "robot_state": {
    "joint_positions": {"unit": "rad", "values": {"joint1": 0.12, "joint2": -0.4}},
    "gripper": {"opening": 0.012, "unit": "m", "closed_means": "fully closed is 0.0"},
    "objects": [{"label": "red cube", "pose_in_base": [0.31, -0.02, 0.05], "unit": "m"}]
  },
  "options": {"reason": false, "include_robot_state": false}
}
```

- `state.description` は、手書きの成功条件ではなく、「その State が何を目的とするか」程度 (仕様 §38 のとおり)。
- `robot_state` は**任意**。`options.include_robot_state` が true のときだけ、プロンプトに入る (検証が済むまでは false)。
- `images` の `role` は、`state_end`、`state_start`、`previous` など。

### 3.2 レスポンス

```json
{
  "request_id": "uuid",
  "assessment": "semantic_success",
  "score": 1.84,
  "confidence": null,
  "reason": null,
  "model": "gemma-4-e2b-qat-q4_0-it",
  "adapter": "gemma-4-E2B-X8-lora-f16",
  "latency_ms": {"total": 2310, "prefill": 2050, "generate": 260},
  "usage": {"prompt_tokens": 1034, "completion_tokens": 1}
}
```

- `score`: log p(Yes) − log p(No)。実験で使ってきた値そのもの。大きいほど成功らしい。
- `assessment`: `score` の正負で、`semantic_success` / `semantic_failure`。**アプリ側のしきい値は 0 に固定**し、`uncertain` のしきい値と State ごとの調整は PC 側 (§5) が行う。
- `confidence`: アプリ側では計算しない (null)。PC 側のキャリブレーション (§5) が、スコアから確率に直す。
- `reason`: `options.reason` が true のときだけ、判断後に短い文 (最大 60 トークン) を追加で生成する。追加で約 2〜3 秒。
- エラー: 400 (入力不正、画像なし)、401、503 (モデル未ロード)、413 (コンテキスト超過)、429 (推論中)。既存のエラー形式 (`error.type`, `error.message`) を使う。

### 3.3 アプリ側の実装方針

- **JSON を生成させない。** 答えは「Yes か No の 1 トークン目の確率」で決まるので、`assessment` の JSON は、アプリが組み立てる。構造化出力の失敗 (JSON が壊れる) を、そもそも起こさない。
- プロンプトは、評価したものと**同じ文面**にする: 「These are N frames in time order … The robot's task is: {state.description} Was the task completed successfully? Answer yes or no.」(`state.outcome` や `task_instruction` は、補足として後ろに足す形を、別途評価してから決める)。
- `reason` は、1 トークンの判断の後に、続けて生成する (同じ KV キャッシュを使うので、画像の処理は 2 回にならない)。
- 使うアダプタは、モデルタブで選んだもの (`/capabilities` の `adapter` で確認できる)。
- 既存の `/v1/chat/completions` (OpenAI 互換) は、そのまま残す。

## 4. PC 側 (`vlm_supervisor/core/`)

仕様のディレクトリ構成に沿う。

- `prompt_builder.py`: `SupervisorInput` から `context.json` と画像を作る。数値は、**型を整理して単位を付ける** (関節角は rad、長さは m)。数値ブロックの出し方 (a) 渡さない、(b) 全部テキストで、(c) 意味のある要約に直して (例: 「gripper: fully closed」)、を切り替えられるようにして、比較できるようにする。
- `iphone_client.py`: `multipart` で送信、タイムアウト、リトライ、通信失敗時の扱い。`MockIPhoneClient` (固定のスコア) も用意する。
- `decision_parser.py`: レスポンスを検証し、`assessment`、`score`、`confidence` に変換する。
- `calibrator.py` (追加): State ごとの `score` → 成功確率の対応 (ロジスティック回帰など) としきい値を保持する。ラベルがない State は、全体の対応表で代用し、`uncertain` を多めにする。
- Shadow Mode のロガー: `snapshot.json`、`image_*.jpg`、`metadata.json`、レスポンス、FlexBE の outcome、後から付ける人間のラベルを 1 件として保存する (仕様 §24、§39)。

## 5. キャリブレーションと評価

- **State ごとにしきい値を決める。** 実験では、全タスクをまとめた AUC (0.645) より、タスクごとの AUC (平均 0.79) が高く、学習でスコアの水準が揃っても (プール 0.85)、タスクごとの平均 (0.90) のほうが高い。State ごとのしきい値は、Shadow Mode で集まる人間のラベルから決める。
- 必要な件数: 実験の評価では、タスクごとに成功 20 本・失敗 80〜160 本でも、AUC の誤差が ±0.1 だった。**State あたり、成功・失敗が各 30〜50 件**あれば、しきい値の目安は出せる (これは見立てで、検証はしていない)。
- 指標 (State ごと): AUC、再現率 (失敗を見逃さない割合) を一定にしたときの誤検出率、`uncertain` の割合、FlexBE の判定 / VLM の判定 / 人間の判定の三者の比較 (仕様 §40)。

## 6. 学習 (アダプタ) の進め方

1. 基礎アダプタ: **VSR → RoboFAC の順に学習したもの (X8)**。空間判断と、「State の説明 + 終了時画像」の成否判断の両方を持つ。iPhone 上で、成否 AUC は、6 タスクをまとめて 0.628 から 0.777、タスクごとの平均で 0.722 から 0.871。
2. 自前データでの追加学習: Shadow Mode で集めた (State の説明、終了時の画像、人間のラベル) を、同じ形式 (Yes / No) で追加学習する。評価は、学習に使わない試行 (別日、別の物体配置) で行う。
3. アプリは、アダプタを差し替えて使う (48 MB)。ロボットや State の系統ごとに、アダプタを分けることもできる。

## 7. 数値データ (関節角度など) について

- 今ある公開データには、画像とタスク文しかなく、**数値を使った判断の効果は、検証できない**。
- 小さなモデル (E2B) が、数値の表から判断できるかも未知。**数値は、(a) 渡さない、(b) テキストで渡す、(c) 要約して渡す、の 3 通りを自前データで比較して決める**。
- 自前データは、Phase 5 の Shadow Mode が自然に集める (rosbag + 人間のラベル)。別に収集作業を設けなくても、Phase 5 の運用そのものが、この比較のデータになる。

## 8. 決めてほしいこと / 確認したいこと

1. **画像**: RealSense の RGB を、JPEG で、どの解像度で送るか (現在は最大 280 トークンの 640×480 程度で評価)。State の開始時と終了時の 2 枚が必要か。
2. **数値**: どの値を渡したいか (関節角、グリッパの開き、TF、SAM3 の物体情報、オドメトリなど)。最初の検証では、どれを対象にするか。
3. **State の説明**: どの FlexBE State から始めるか (最初は 3〜5 個を想定)。説明文は、誰が、どの粒度で書くか。
4. **出力の語彙**: `semantic_success` / `semantic_failure` / `uncertain` で足りるか。失敗の種類 (原因) が必要なら、**公開データでは改善できていない**ので、自前の失敗例で学習する必要がある。
5. **応答時間の目安**: Phase 5 は記録だけなので問題ないが、Phase 6 (介入) では、画像 1 枚で約 2 秒、`reason` 付きで約 5 秒が許されるか。
6. **API の形**: 専用の `POST /v1/supervisor/evaluate` を作るのと、既存の OpenAI 互換 API に `chat_template_kwargs` などで寄せるのと、どちらがよいか (推奨: 専用 API。JSON の組み立てをアプリ側で固定でき、画像を multipart で送れる)。

## 9. 進め方 (案)

1. 専用 API の実装 (アプリ)、`iphone_client` と `MockIPhoneClient`、スナップショットの保存 (PC)。
2. 実機の FlexBE で Shadow Mode を回し、ログとラベルを集める (State あたり成功・失敗が各 30〜50 件)。
3. State ごとのキャリブレーションと評価。数値ブロックの 3 通りの比較。
4. 自前データでの追加学習と、学習に使わない試行での評価。
5. その結果をもとに、Phase 6 (介入) の設計に進む。
