"""Japanese versions of the templated RoboSpatial-Home questions (probe_robot_phone.py --lang ja).
Only the question is translated; the answer stays `yes` / `no` so that the first-token scoring is unchanged.
A question that does not match a template is left in English and counted by the probe."""
import re

NOUN = {
    "Korean flag": "韓国の旗", "TV": "テレビ", "bag": "バッグ", "banana": "バナナ", "bathtub": "浴槽", "bed": "ベッド",
    "bottle": "ボトル", "bowl": "ボウル", "box": "箱", "brown paper bag": "茶色い紙袋", "brown paper box": "茶色い紙箱",
    "cabinet": "キャビネット", "cabinets": "キャビネット", "cactus": "サボテン", "catcus": "サボテン", "can": "缶",
    "cat tower": "キャットタワー", "chair": "椅子", "chairs": "椅子", "chopping boards": "まな板", "counter": "カウンター",
    "cup": "カップ", "curtain": "カーテン", "desk": "机", "dish drying rack": "水切りラック", "dish soap": "食器用洗剤",
    "dishwasher detergent container": "食洗機用洗剤の容器", "drawer": "引き出し", "fire extinguisher": "消火器",
    "floor mat": "フロアマット", "flowers": "花", "frame": "額縁", "fridge": "冷蔵庫", "game controller": "ゲームのコントローラー",
    "grey basket": "灰色のかご", "guitar": "ギター", "headphone": "ヘッドホン", "keyboard": "キーボード", "lamp": "ランプ",
    "laptop": "ノートパソコン", "litter box": "猫のトイレ", "media console": "メディアコンソール", "microwave": "電子レンジ",
    "monitor": "モニター", "mouse": "マウス", "orange": "オレンジ", "outlet": "コンセント", "painting": "絵", "pan": "フライパン",
    "paper towel": "キッチンペーパー", "picture": "写真", "pillow": "枕", "plant": "観葉植物", "plastic bag": "ビニール袋",
    "plate": "皿", "pot": "鍋", "rug": "ラグ", "scissor": "はさみ", "shampoo": "シャンプー", "shelf": "棚", "shelve": "棚",
    "shelves": "棚", "sink": "シンク", "smiley cushion": "スマイルのクッション", "sofa": "ソファ", "speaker": "スピーカー",
    "speakers": "スピーカー", "stool": "スツール", "stove": "コンロ", "table": "テーブル", "teddy bear": "テディベア",
    "tissue": "ティッシュ", "tissue box": "ティッシュの箱", "toilet": "トイレ", "trash bin": "ごみ箱", "vacuum": "掃除機",
    "watch": "腕時計", "window blind": "ブラインド", "window blinds": "ブラインド", "wok": "中華鍋", "water": "水",
    "water pitcher": "水差し", "hanger rack": "ハンガーラック", "basket": "かご",
}
REL = {"in front of": "の前", "behind": "の後ろ", "above": "の上", "below": "の下", "left of": "の左", "right of": "の右",
       "to the left of": "の左", "to the right of": "の右", "next to": "の隣", "on top of": "の上", "under": "の下", "on": "の上"}
_REL = "|".join(sorted(REL, key=len, reverse=True))
ANSWER = "「yes」か「no」だけで答えてください。"


def _n(word):
    return NOUN.get(word, word)


def to_japanese(question):
    """Returns (japanese question with the answer instruction, translated?)."""
    m = re.fullmatch(rf"Is the (.+?) ({_REL}) the (.+?)\?", question)
    if m:
        return f"{_n(m[1])}は{_n(m[3])}{REL[m[2]]}にありますか?{ANSWER}", True
    m = re.fullmatch(rf"Can the (.+?) fit (?:in )?(?:the )?({_REL}) (?:of )?the (.+?)\?", question)
    if m:
        return f"{_n(m[1])}は{_n(m[3])}{REL[m[2]]}の空きスペースに収まりますか?{ANSWER}", True
    return question + " Answer yes or no.", False
