# 失敗の注釈ツール

失敗した動画 (RoboFAC の実機 480 エピソード、またはご自身のロボットの動画) に、**何が起きたか**と**どう回復するか**を注釈するローカルツール。Python 3 の標準ライブラリだけで動きます (ブラウザは Chrome か Firefox)。

## 起動 (この PC)

```bash
cd Local_LLM_by_using_MobilePhone
python3 experiments/annotate/server.py          # → ブラウザで http://127.0.0.1:8765/ を開く
```

止めるときは、起動したターミナルで Ctrl+C。注釈は `experiments/annotate/annotations.jsonl` に 1 行ずつ追記されるので、止めても消えません。

## 別の開発 PC で使う

1. リポジトリを取得する (ブランチは `iphone`)。
   ```bash
   git clone git@github.com:Guch1120/Local_LLM_by_using_MobilePhone.git && cd Local_LLM_by_using_MobilePhone && git checkout iphone
   ```
2. RoboFAC の動画と注釈データ (約 2.2 GB) を取得する。動画は、リポジトリには含まれません。
   ```bash
   pip install huggingface_hub hf_xet          # hf_xet は任意 (速くなります)
   python3 experiments/annotate/fetch_data.py  # → ~/data/robot/ に保存 (--data で場所を変えられます)
   ```
   Hugging Face が「429 Too Many Requests」を返すことがありますが、スクリプトが自動で待って再試行します。
3. 起動する (上と同じ)。`--data` を変えたときは、`python3 experiments/annotate/server.py --data /path/to/robot` のように指定します。
4. 別の端末のブラウザから使うとき (たとえば、サーバを動かす PC と、画面を見る PC が別):
   - SSH で転送する方法 (安全): 見る側で `ssh -L 8765:localhost:8765 サーバのPC` を実行して、`http://localhost:8765/` を開く。
   - `--host 0.0.0.0` で起動して、`http://サーバのIP:8765/` を開く方法もありますが、**ログインがない**ので、信頼できるネットワークだけで使ってください。
5. **複数の PC の注釈を 1 つにまとめる**: `annotations.jsonl` を集めて連結する (`cat a.jsonl b.jsonl > all.jsonl`)。同じエピソードは**あとの行が有効**です。注釈者の名前が各行に入ります (画面の上の「注釈者」)。`--store FILE` で、注釈ファイルの場所 (たとえば同期フォルダ) を指定できます。
   ```bash
   python3 experiments/annotate/server.py --store ~/Dropbox/annotations_pc2.jsonl
   ```

## ご自身のロボットの動画を注釈する (カメラの構成は自由)

1. 動画を、`<エピソード名>__<カメラ名>.mp4` の名前で 1 つのフォルダに置く (例: `pick01__wrist.mp4` と `pick01__side.mp4`)。カメラの数と名前は自由です。最初のカメラが、再生の基準になります。
2. 一覧を作る。
   ```bash
   python3 experiments/annotate/make_manifest.py ~/my_videos ~/my_manifest.json --task PickCube --task-text "Pick up the red cube."
   ```
   `~/my_manifest.json` を開いて、エピソードごとの `task_text` (そのとき、ロボットが何をするはずだったか) を直してください。
3. 起動する。
   ```bash
   python3 experiments/annotate/server.py --manifest ~/my_manifest.json --video-root ~/my_videos --store ~/annotations_mine.jsonl --no-robofac
   ```
   `--no-robofac` を付けないと、RoboFAC の動画も一緒に表示されます。

## 使い方

- 動画は、すべてのカメラが並び、同時に再生・コマ送りできます (Space、←、→)。「失敗の瞬間」の時刻を記録できます。
- 1 エピソードごとに記入するもの: 失敗が確認できるか / 何が起きたか / 原因の種類 / 回復の手順 (Skill を順に追加) / 同じ失敗を避けるために変えること / 一覧にない必要な Skill / 確信度。保存は Ctrl+Enter。
- **RoboFAC のデータセットのラベルと説明は、最初は隠れています** (ヒントのボタンで見られます。見てから保存したかも記録されます)。先に自分で判断してください。
- 同じエピソードを、もう一度保存すれば、やり直せます (最後の行が有効)。
- 動画の順番は、タスクを順に回る並びです。**最初の 100〜120 本** (各タスク 約 20 本) で、注釈にかかる時間と、ラベルの付けやすさを確認してください。
- Skill の一覧は `skills.json`、原因の種類は `taxonomy.json` です。自由に編集できます (ブラウザの再読み込みで反映)。
- 注釈から学習用のデータを作るには、`python3 experiments/annotate/export_training.py` (RoboFAC の動画が必要)。

## 注釈のコツ

- 「何が起きたか」は、見えたことを 1〜2 文で (推測は「〜のように見える」)。原因が動画から分からないときは、原因の種類で「分からない」を選んでください。これも大切なデータです。
- 回復の手順は、**前回と同じことを繰り返すと、また失敗しそうか**を考えて、変えるパラメータを書いてください (メタ認知のデータになります)。
- 一覧に必要な Skill がないときは、「一覧にない必要な Skill」に書いてください。どの Skill を作るべきかの手がかりになります。
