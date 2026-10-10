# 述語集の設計書(見える事実の語彙)

2026-10-11。失敗の種類を直接当てさせる方式は、未知のタスクで偶然程度にとどまった(2クラスでも5分割すべて偶然、`docs/2026-10-09-robofac-training.md`)。
代わりに、モデルには**画像から見える事実の Yes/No**だけを答えさせ、失敗の種類や回復は事実とセンサーから導く(方針E)。この文書は、その事実(述語)の語彙の設計をまとめる。
実体は `experiments/predicates/predicates.json`(管理は `predicates.py`)。注釈ツールの `facts.json`(11項目)は、この述語集ができたら、そこから生成する形に置き換える。

## 1. 原則
1. **述語は少数の物理的な関係に限る**。物体名は引数にして、タスクごとに増やさない(`holding(cube)`、`on_top(cube, cubeB)`)。
2. **質問は自然文の Yes/No**。出力形式を固定したまま、質問を1行足せば述語が増える。
3. **画像だけで判断できることを聞く**。目標位置など画像に出ない前提は、タスク文か目標の指定に含める。
4. **センサーで決まることはモデルに聞かない**(`self` 層)。モデルの答えとの照合に使う。
5. **IDは不変・削除しない**。使わなくなったら `deprecated` にして理由を残す(学習データやログがIDを参照する)。

## 2. 層
| 層 | 判断に必要なもの | 述語 |
|---|---|---|
| state | 1枚のフレーム | holding, touching, on_top, inside, at_goal, near_goal, lifted, upright, tilted |
| event | 複数フレームの時間変化 | reached, grasped, moved, dropped, overshot, fell_short, hit_other |
| self | センサー値(モデルに聞かない) | gripper_closed, gripper_empty_closed |

しきい値と定義は `predicates.json` の `definition` と `params` が正本。しきい値は暫定(シミュレーションで自動ラベルを試す段階で、人の目で見て納得できる値に調整し、変えたら version を上げる)。

## 3. 事実から失敗の種類を導く(例)
| 偽/真になった述語 | 導かれる種類(暫定) |
|---|---|
| reached=yes かつ (grasped=no または dropped=yes) | 把持の失敗 |
| moved=yes かつ at_goal=no かつ (overshot または fell_short または near_goal) | 位置のずれ |
| at_goal=yes だが tilted=yes | 向きのずれ |
| hit_other=yes | 干渉(別の物体に当たった) |
| reached=no | 到達の失敗 |
導出規則は、述語から種類を決める単純な規則に留める。規則で説明できない事例は、新しい述語を足す手がかりにする。
`self` の `gripper_empty_closed` が真なのに、モデルが `holding=yes` と答えたら、矛盾として人に確認を求める。

## 4. 追加・削除の手順
```
python3 experiments/predicates/predicates.py list [--layer event] [--status active]
python3 experiments/predicates/predicates.py check
python3 experiments/predicates/predicates.py add pushed_off_table --layer event --question "Did the {a} fall off the table?" --sim auto --definition "..."
python3 experiments/predicates/predicates.py status holding active
python3 experiments/predicates/predicates.py status near_goal deprecated --note "at_goal の調整で不要になった"
```
追加した述語は `proposed`。自動ラベルまたは人の注釈で検証し、モデルが答えられる(未知タスクで偶然を超える)ことを確かめてから `active` にする。

## 5. 残る論点
- 「近い」「持ち上がった」のしきい値は、実機(Piper)の寸法で意味が変わる。実機の動画で人が見て決め直す。
- `at_goal` `tilted` は目標が必要。目標を画像に出す(目印)か、テキストで指定するか。
- 実画像の注釈は、述語ごとに「はい/いいえ/分からない」の3択を基本にする。「分からない」が多い述語は定義が曖昧なので見直す。
- 述語の数は、タスクが増えても増えにくいが、物体の状態を表す述語(開いた量、こぼれたかなど)は作業の種類が増えると必要になる。

## 6. シミュレーションの自動ラベルの試作(2026-10-11)
`experiments/predicates/sim_labels.py`。RoboFACのシミュレーションデータのうち PickCube / PushCube / PullCube / StackCube(動画のある229エピソード)で、
物体の位置とPandaの関節状態から述語を全ステップ分計算する(順運動学でグリッパー先端を求める)。出力は `~/data/robot/sim_labels.json`(動画は、ステップ数+1枚で1対1に対応。229本すべてで一致を確認)。

確認できたこと:
- **成否との一致**: `at_goal`(最終フレーム)はデータセットの成功フラグと完全に一致(成功8本すべて真、失敗221本すべて偽)。ただし、ゴールの許容幅はタスクごとに違う(Push/Pull は0.10 m、Pick は3次元で0.025 m)。成功/失敗の境目(成功は0.097 m以下、失敗は0.102 m以上)から決めた。**述語のしきい値は、タスクの「ゴールの大きさ」に依存する**ので、目標条件の一部として扱う必要がある。
- **注入された失敗との整合**: フォルダ名が、注入した誤りの種類を表す。`close_gripper_close_late`(閉じるのが遅い)は、到達100%・把持0%・動かず0%。`stack_position_offset` は、把持100%・動いた100%・ゴールに届かず。`gripper_error` は到達100%・把持4%・落下28%。`reach_position_offset` は到達が低い(5〜12%、Stackは56%)。いずれも、期待どおりの向き。
- **画像との照合**: StackCubeの1エピソードで、`holding` と `lifted` が真になるフレームで、実際に赤い立方体が持ち上がっている。最後は少しずれて置かれ、`at_goal` が偽。

限界:
- 成功エピソードは8本だけ(ほとんどが失敗データ)。「成功している絵」の述語は、別に集める必要がある。
- Stackの `reach` が56%など、グリッパー先端の距離のしきい値(`d_reach`)では取りこぼしがある。人の目で見て調整する。
- `inside` `upright` `tilted` `hit_other` `on_top` は、立方体系のタスクでは計算していない(物体が足りない)。
