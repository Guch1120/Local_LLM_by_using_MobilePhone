# ベンチマークの試験内容 (読み方のガイド)

これまでの評価 (`docs/2026-10-08-vsr-evaluation.md`、`2026-10-08-robot-benchmarks.md`、`2026-10-09-robofac-training.md`) で使った試験が、**何を入力して、何を答えさせ、何を測っているか**をまとめる。どれも画像 (とタスク文) だけを入力にしたもので、**ロボットの関節角度などの数値データは含まない** (§3)。

## 1. 試験の一覧

| 試験 | 入力 | 質問の例 | 答え | 偶然の水準 | 測っているもの |
|---|---|---|---|---|---|
| **VSR** (写真の空間関係) | COCO の写真 1 枚 + 文 | 「The banana is on the orange.」(正しいか) | true / false | AUC 0.5 | 2 つの物体の位置関係が、文の通りか。14 種類の関係 (左右、上下、前後、接触、内包など) |
| **shapes** (合成図形) | 白地に色付き図形 2 つの絵 | 「The blue triangle is to the left of the green circle.」 | true / false | 0.5 | 写真ではない絵での、左右上下の判断 |
| **RoboSpatial-Home「配置」** | 実際の室内写真 1 枚 | 「Is the bowl behind the chair?」 | yes / no | 0.5 | 実室内の物体同士の位置関係 (左右、上下、前後) |
| **RoboSpatial-Home「収まるか」** | 実際の室内写真 1 枚 | 「Can the tissue box fit left of the vacuum?」 | yes / no | 0.5 | 空きスペースに物が入るか (大きさと空きの見積もり) |
| **ERQA** | 写真 1〜数枚 | 「What's the state of the drawer?」「If the yellow robot gripper follows the yellow trajectory, what will happen?」 | 選択肢 A〜D (4 択) | 約 25% | ロボット向けの具体的な推論 (空間、状態推定、軌道、行動、複数視点、ポインティングなど 8 種類) |
| **RoboFAC「成否」** | 実機ロボットの動画から取り出したフレーム + タスク文 | 「The robot's task is: Insert the cylinder into the middle hole of the shelf. Was the task completed successfully?」 | yes / no | AUC 0.5 | 作業が成功したか。成功 244 本、失敗 960 本の動画 (SO-100 アーム、6 タスク) |
| **RoboFAC「失敗の種類」** | 同上 (失敗した動画だけ) | 「Please describe the error type …」(選択肢: Orientation deviation / Grasping error / Position deviation) | 選択肢 A〜C (主に 3 択) | 約 33% | 失敗の原因の分類 |
| **RoboFAC「失敗した場面」** | 同上 | 「during which subtask did the error happen?」 | 選択肢 A〜E (5 択) | 20% | **実際は「何の作業か」の識別** (§2) |

指標: Yes/No と true/false の試験は、**ROC-AUC** (成功と失敗の問題を、スコアでどれだけ分けられるか。0.5 が偶然、1.0 が完全) と、閾値 0 での正答率。選択式は正答率。AUC は、「true と答えにくい癖」などの偏りに左右されない。

## 2. 「最後の 1 枚 + タスク文」の意味

RoboFAC の成否の試験で使った入力。

- **最後の 1 枚**: 実機ロボットが 1 回の作業 (エピソード、約 8 秒の動画) を実行した**動画の最後のフレーム**。作業が終わった (または失敗して止まった) 時点の様子。
- **タスク文**: そのとき**ロボットがやろうとしていた作業の説明**。例: 「Insert the cylinder into the middle hole of the shelf.」
- この 2 つを 1 つの問い合わせにして、「作業は成功したか」を聞く。

Supervisor の仕様 (Phase 5) では、**「State の説明 (その State が何を目的とするか)」と「その State が終わった時点のカメラ画像」**がこれに当たる。

補足:
- 「最後の 3 枚」は、動画の最後の 3 フレーム (3 枚の画像を時間順に並べる)。「6 フレーム」は、動画全体から等間隔に取った 6 枚。
- **「失敗した場面」の試験は、タスクの識別の試験**になっている。選択肢のうち、動画のタスクに属する作業が、960 問中 933 問でちょうど 1 つだけなので、何の作業かが分かれば 98.6% 正解できる。ベースも FT 後も 56% だったのは、失敗の位置の判断ではなく、動画から作業を識別できていないことを示す。

## 3. この試験が測っていないこと

- **関節角度、グリッパの開き、TF、オドメトリなどの数値データ**。RoboFAC の動画には、これらは含まれていない (動画だけ)。Phase 4・5 で渡す予定の「型整理した ROS トピックの数値」を VLM が使えるかは、**まだまったく検証していない**。
- **自前のロボット (Piper、Kobuki、RealSense)** の映像。評価した実機は、SO-100 アームの映像。
- **未知のタスクへの汎化** (一部のみ検証。`2026-10-09-robofac-training.md` §6.4 と、今後の保留タスクの実験)。
- **回復行動 (リカバリ) の選択**。失敗の種類の分類までで、「どの Skill を実行するか」は測っていない。
- 動画の**途中**の判断。今回の入力は、作業が終わった時点の静止画が中心。
