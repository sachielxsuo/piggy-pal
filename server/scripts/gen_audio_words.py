#!/usr/bin/env python3
"""一次性生成 audio_words.txt（真人录音词表）。

来源（只用具体名词 / 动作 / 形容词，不要抽象词和虚词）：
  1. kid_words.txt 里已人工审校的童词
  2. 学前高频分类词表（数字 / 颜色 / 身体 / 动物 / 食物 / 动作 ...）
  3. 线上聊天里真实出现过的英文词
  4. 不足 1000 时，用 ECDICT 里带「中考」标签的具体名词补足
"""

import csv
import gzip
import os
import re
import sqlite3
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "internal" / "dict" / "data"
BASE = DATA / "dict_base.tsv.gz"
KID = DATA / "kid_words.txt"
OUT = DATA / "audio_words.txt"
# 可选输入：ECDICT 词库 csv 和线上库。没有就跳过（只影响最后的补足和聊天词），
# 所以默认路径故意留空，由环境变量指定，脚本里不写死任何本机路径。
ECDICT = Path(os.environ["ECDICT_CSV"]) if os.environ.get("ECDICT_CSV") else None
DB = os.environ.get("PIGGYPAL_DB", "")

BANKS = {
    "numbers": """
one two three four five six seven eight nine ten eleven twelve thirteen fourteen
fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy
eighty ninety hundred thousand first second third fourth fifth sixth seventh eighth
ninth tenth half
""",
    "colors": """
red blue yellow green orange purple pink brown black white grey gray gold silver
""",
    "shapes": """
circle square triangle rectangle oval diamond heart star
""",
    "body": """
head hair face eye ear nose mouth tooth teeth tongue neck shoulder arm hand finger
thumb leg knee foot toe back chest tummy belly skin heart bone elbow wrist ankle
cheek chin forehead lips eyebrow stomach
""",
    "people": """
mom mum dad mother father baby brother sister grandma grandpa grandmother
grandfather aunt uncle cousin son daughter family friend teacher doctor nurse farmer
driver police pilot boy girl man woman child kid people baby
""",
    "jobs": """
baker dentist firefighter postman builder painter singer artist scientist waiter
""",
    "animals": """
cat dog pig cow duck sheep horse rabbit bird fish chicken chick mouse rat frog snake
turtle tortoise lion tiger elephant monkey giraffe zebra bear panda koala kangaroo
penguin owl fox wolf deer squirrel hedgehog bat dolphin whale shark octopus crab
lobster snail ant bee butterfly ladybug spider worm dragonfly mosquito fly beetle
caterpillar dinosaur crocodile hippo rhino camel donkey goat lamb kitten puppy parrot
peacock flamingo swan goose turkey rooster hen seahorse jellyfish starfish seal
walrus ostrich pelican raccoon otter beaver moose bison gorilla chimpanzee badger
mole chameleon iguana gecko scorpion grasshopper cricket firefly moth tadpole goldfish
squid shrimp oyster clam
""",
    "food": """
apple banana orange grape pear peach strawberry watermelon lemon cherry mango
pineapple coconut tomato potato carrot onion cabbage broccoli pumpkin corn pea bean
rice bread cake cookie biscuit candy chocolate cheese milk yogurt egg meat beef pork
soup noodle dumpling sandwich pizza hamburger fries salad honey jam butter sugar salt
pepper juice water tea lemonade milkshake porridge cereal pancake lime melon kiwi
fig plum apricot blueberry raspberry blackberry avocado lettuce celery spinach garlic
ginger mushroom popcorn donut muffin pudding jelly sauce vinegar oil flour cocoa soda
toast bacon sausage
""",
    "kitchen": """
fridge sink oven stove kettle teapot dish chopsticks cup glass bottle spoon fork knife
plate bowl pot pan box
""",
    "bathroom": """
bath shower toothpaste toothbrush shampoo comb toilet soap towel mirror
""",
    "home": """
house home room bedroom kitchen bathroom door window bed pillow blanket sofa chair
table desk lamp light clock key lock stairs garden quilt sheet curtain carpet shelf
drawer cupboard television radio broom mop
""",
    "toys": """
toy ball balloon block doll kite puzzle swing slide seesaw sandbox sandpit marble
""",
    "clothes": """
hat cap shirt pants trousers dress skirt socks shoes boots coat jacket sweater scarf
gloves pajamas diaper uniform raincoat sandal slippers sneakers belt button zipper
pocket
""",
    "actions": """
eat drink sleep wake wash brush clean cook cut open close push pull give take put get
make play run jump hop skip walk march dance sing clap stomp laugh cry smile hug kiss
wave draw paint read write count look see watch listen hear touch smell taste climb
sit stand turn stop go come swim fly ride drive throw catch kick hold carry find hide
seek help share wait start finish build fix fall crawl shout whisper knock nod shake
bounce roll spin slide swing answer ask begin believe borrow bring buy call chase
choose color cover cross decide dig dream dress drop dry feed feel fill fit float
follow forget freeze grow guess happen hate hurry hurt keep learn leave lend lift live
lose marry mean meet melt move need pay pick plant pour practice pray rest return ring
sail say sell send shine shop show shut skate ski speak spell spend splash stay study
teach tell thank think tickle touch travel try want wear win wink wipe wonder work
worry yawn
""",
    "adjectives": """
big small tall short long fat thin hot cold warm cool wet dry clean dirty happy sad
angry scared tired sleepy hungry thirsty excited surprised proud funny silly kind
nice good bad new old fast slow loud quiet hard soft heavy light strong weak beautiful
pretty bright dark full empty early late different same shiny round sharp sticky
smooth rough fluffy furry spotty striped brave curious careful
""",
    "nature": """
sun moon star sky cloud rain snow wind storm rainbow thunder tree flower grass leaf
seed plant forest mountain river lake sea beach sand rock stone island cave fire
water ice earth planet space hill field path bridge
""",
    "flowers": """
rose lily tulip daisy sunflower violet
""",
    "weather": """
weather spring summer autumn winter sunny cloudy windy rainy snowy
""",
    "transport": """
car bus train plane boat ship bike bicycle truck digger tractor taxi van rocket
helicopter scooter skateboard
""",
    "school": """
school classroom student ruler eraser scissors glue letter alphabet number word story
song
""",
    "places": """
park zoo shop store market hospital library farm playground restaurant cinema museum
castle tower village city street road coin
""",
    "time": """
day night morning afternoon evening today tomorrow yesterday week month year birthday
christmas monday tuesday wednesday thursday friday saturday sunday january february
march april may june july august september october november december
""",
    "music": """
drum piano guitar violin trumpet bell
""",
    "sports": """
football basketball tennis baseball
""",
    "tools": """
hammer nail screw saw ladder rope
""",
    "party": """
present gift candle card
""",
    "camping": """
tent camp fishing
""",
    "fairy": """
prince princess king queen knight dragon castle fairy wizard witch giant mermaid
unicorn crown wand treasure
""",
    "vehicles2": """
excavator bulldozer crane forklift ambulance motorbike wagon sled
""",
    "food2": """
waffle bagel pretzel smoothie cupcake popcorn pancake
""",
    "nature2": """
puddle mud snowman snowflake sunshine shadow comet meteor astronaut galaxy
""",
    "school2": """
backpack lunchbox notebook marker paintbrush chalk sticker
""",
    "instruments": """
flute harp cello saxophone tambourine
""",
    "sports2": """
badminton volleyball golf hockey skating cycling
""",
    "weather2": """
fog frost lightning
""",
    "verbs2": """
squeak giggle snore sneeze cough blink wiggle stretch tiptoe gallop waddle
""",
    "adjectives2": """
tiny huge giant noisy messy tidy gentle polite friendly cheerful grumpy lazy busy
""",
    "animals3": """
pony calf foal cub piglet duckling owlet
""",
    "tools2": """
bucket spade shovel
""",
    "places2": """
bakery bookstore
""",
    "extras": """
acorn pinecone branch trunk root bush vine moss pebble boulder apron sponge dustbin
trash hanger umbrella wallet purse watch glasses sunglasses necklace bracelet globe
map whistle xylophone harmonica microphone headphones lollipop cracker bench fence
gate sign mailbox satellite breeze juggle itchy dizzy naughty cuddly nail beard
moustache hoop racket bat teddy puppet robot jigsaw garage shed barn sprinkle squeeze
peel
""",
    "baby": """
stroller crib pacifier
""",
}

# ECDICT 补足时只接受这种释义（具体名词 / 动物 / 食物），挡掉抽象词和成人词
# 聊天里出现的角色名 / 人名不收录
DROP = {"george", "peppa", "daddy", "mommy", "tester", "anan"}

BAD_ZH = (
    "计]", "医]", "化]", "法]", "军]", "经]", "商]", "律]", "哲]", "宗]",
    "计算机", "电脑", "软件", "系统", "公司", "政府", "总统", "政治", "经济", "军事",
    "战争", "枪", "毒品", "性", "妓", "赌", "酒", "烟", "税", "股", "债", "癌",
    "死", "杀", "犯罪", "法", "党", "投票", "银行", "保险",
)


def load_kid() -> list[str]:
    words = []
    for line in KID.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            words.append(line.split("|")[0].strip())
    return words


def load_base() -> set[str]:
    words = set()
    with gzip.open(BASE, "rt", encoding="utf-8") as f:
        for line in f:
            c = line.split("\t")
            if c:
                words.add(c[0])
    return words


def load_chat_words(base: set[str]) -> list[str]:
    if not DB:
        return []
    try:
        db = sqlite3.connect(DB)
        rows = db.execute("select content from chat_message").fetchall()
    except Exception as e:  # noqa: BLE001
        print(f"⚠ 读不到线上库，跳过聊天词：{e}", file=sys.stderr)
        return []
    tok = re.compile(r"[A-Za-z]+")
    counts: dict[str, int] = {}
    for (content,) in rows:
        for m in tok.finditer(content or ""):
            w = m.group(0).lower()
            counts[w] = counts.get(w, 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return [w for w, _ in ranked if len(w) >= 3 and w in base]


def ecdict_nouns() -> list[tuple[str, int]]:
    """ECDICT 里带中考标签的具体名词，按词频排序，用于最后补足。"""
    out = []
    if ECDICT is None or not ECDICT.exists():
        return out
    with open(ECDICT, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            w = (r.get("word") or "").strip().lower()
            if not re.fullmatch(r"[a-z]{3,9}", w):
                continue
            tags = (r.get("tag") or "").split()
            if "zk" not in tags and "gk" not in tags:
                continue
            zh = (r.get("translation") or "").replace("\\n", "\n").strip()
            first = zh.split("\n")[0].strip()
            if not first.startswith(("n.", "n ")):
                continue
            if any(b in zh for b in BAD_ZH):
                continue
            if len(first) > 24:
                continue
            try:
                frq = int(r.get("frq") or 99999)
            except ValueError:
                frq = 99999
            out.append((w, frq))
    out.sort(key=lambda x: (x[1], len(x[0]), x[0]))
    return out


def main() -> None:
    kid = load_kid()
    base = load_base()
    chat = load_chat_words(base)

    ordered: list[str] = []
    seen: set[str] = set()

    def add(words, allow_short: bool = False):
        for w in words:
            w = w.strip().lower()
            pattern = r"[a-z]{2,}" if allow_short else r"[a-z]{3,}"
            if not re.fullmatch(pattern, w) or w in seen or w in DROP:
                continue
            seen.add(w)
            ordered.append(w)

    # 人工童词全部保留，包括 up / no 这种两个字母的词
    add(kid, allow_short=True)
    add(chat)
    for name, block in BANKS.items():
        add(block.split())

    print(f"kid={len(kid)} chat={len(chat)} banks={len(ordered)}")

    if len(ordered) < 1000:
        # 兜底只取 ECDICT 中考标签里释义很具体的名词
        add(w for w, _ in ecdict_nouns())
        print(f"after ecdict fill: {len(ordered)}")

    ordered = ordered[:1000]
    OUT.write_text(
        "# 真人发音词表：一行一个小写单词。\n"
        "# 新增后重跑 scripts/build_dict.py 即可补录音（没有录音的词会退回 TTS）。\n"
        + "\n".join(ordered) + "\n",
        encoding="utf-8",
    )
    print(f"✅ {len(ordered)} words -> {OUT}")
    missing = [w for w in ordered if w not in base]
    print(f"ℹ {len(missing)} 个词不在底库（构建时会从 ECDICT 直接补释义）：{missing[:40]}")


if __name__ == "__main__":
    main()
