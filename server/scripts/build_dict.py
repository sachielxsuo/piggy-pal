#!/usr/bin/env python3
"""构建 PiggyPal 词典数据（一次性离线脚本，产物提交到仓库）。

输入：
  - ECDICT  ecdict.csv     https://github.com/skywind3000/ECDICT   (MIT)
  - ipa-dict ipa_us.txt    https://github.com/open-dict-data/ipa-dict (MIT)
  - 人工词表 data/kid_words.txt
  - 真人发音  Wiktionary / Wikimedia Commons（CC BY-SA 3.0 等，逐条记在 credits.json）

输出：
  - data/dict_base.tsv.gz   常用词底库（约 1.5 万词：音标 + 清洗后的中文释义 + 词形）
  - data/dict_kid.tsv.gz    人工审校的儿童词条（释义 / 例句 / 真人发音标记）
  - data/audio/<word>.mp3       真人发音（正常语速）
  - data/audio/<word>.sl.mp3    同一段录音 0.72x 变速（保持音高），用于慢读
  - data/audio/credits.json     发音来源 / 作者 / 许可，客户端「关于」页展示

用法：
  python3 scripts/build_dict.py --ecdict /tmp/ecdict.csv --ipa /tmp/ipa_us.txt
  python3 scripts/build_dict.py --skip-audio      # 只重建文本词库
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "internal", "dict", "data")
AUDIO = os.path.join(DATA, "audio")
UA = "PiggyPal/1.0 (dictionary build)"
DOWNLOAD_WORKERS = 1

# 成人 / 技术 / 不适合儿童的义项关键词，清洗时直接丢掉整行
BLACKLIST = (
    "计算机", "电脑", "恶妇", "妓", "嫖", "性交", "阴茎", "阴道", "毒品", "吸毒",
    "麻醉", "枪", "炸弹", "赌", "酒鬼", "咒骂", "脏话", "俚", "解剖", "医]",
)
BRACKET_RE = re.compile(r"^\[[^\]]{1,4}\]")

# ECDICT 里个别释义对儿童不准确 / 太成人，构建时人工覆盖
ZH_OVERRIDES = {
    "koala": "考拉，树袋熊",
    "blueberry": "蓝莓",
    "dumpling": "饺子，汤圆",
    "sandbox": "沙坑，玩沙的盒子",
    "sandpit": "沙坑",
    "giraffe": "长颈鹿",
    "seesaw": "跷跷板",
    "marbles": "玻璃弹珠",
    "jellyfish": "水母",
    "rooster": "公鸡",
    "seahorse": "海马",
    "bacon": "培根，咸肉",
    "toast": "烤面包片",
    "fries": "炸薯条",
    "marble": "弹珠，玻璃球",
    "sandal": "凉鞋",
    "yogurt": "酸奶",
    "story": "故事",
}

# ECDICT 里查不到、但录音词表需要的词，直接补儿童释义
EXTRA_ZH = {
    "donut": "甜甜圈",
    "pacifier": "安抚奶嘴",
}

# 个别词在 Wiktionary 页面里没有音频模板，但 Commons 上确实有录音，手工指定。
MANUAL_AUDIO = {
    "goodnight": "File:LL-Q1860 (eng)-Grendelkhan-goodnight.wav",
    # Commons 上没有按词形命名的文件，手工指定
    "yogurt": "File:LL-Q1860 (eng)-Arlo Barnes-yogurt.wav",
    "sandal": "File:LL-Q1860 (eng)-Vealhurl-sandal.wav",
    "present": "File:en-us-present-adjective.ogg",
    "butterfly": "File:En-ca-butterfly.ogg",
    "chameleon": "File:LL-Q1860 (eng)-Vealhurl-chameleon.wav",
    "iguana": "File:LL-Q1860 (eng)-Vealhurl-iguana.wav",
    "raspberry": "File:LL-Q1860 (eng)-Vealhurl-raspberry.wav",
    "smoothie": "File:LL-Q1860 (eng)-Wodencafe-smoothie.wav",
    "pacifier": "File:LL-Q1860 (eng)-Vealhurl-pacifier.wav",
    "story": "File:En-uk-story.ogg",
}

# 这些词的标准命名文件不够好（太长 / 带冠词），强制走 MANUAL_AUDIO
MANUAL_FORCE = {"story"}


def curl_json(url: str, retries: int = 4) -> dict:
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            wait = 2 + i * 3
            print(f"    retry {i+1}/{retries}: {e}")
            time.sleep(wait)
    raise RuntimeError(f"请求失败：{url}")


def curl_bytes(url: str, retries: int = 4) -> bytes:
    """下载文件。Wikimedia 的 upload 域对并发很敏感，429 时退避重试。"""
    for i in range(retries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or i == retries - 1:
                raise
            wait = 20 * (i + 1)
            print(f"    429 限流，等 {wait}s 重试", flush=True)
            time.sleep(wait)
    return b""


def clean_zh(raw: str) -> list[str]:
    """把 ECDICT 的中文释义清洗成 1–3 条儿童可看的义项。

    做法是先把一行按逗号切段，丢掉含成人 / 技术词的段（而不是整行丢弃，
    否则 `n. 猫, 恶妇` 会把「猫」一起丢掉），再控制长度。
    """
    out = []
    # ECDICT 的 CSV 里换行是字面量 `\n`（两个字符），要显式还原
    raw = (raw or "").replace("\\n", "\n")
    for line in raw.split("\n"):
        line = line.strip()
        if not line or BRACKET_RE.match(line):
            continue
        segs = [s.strip() for s in re.split(r"[,，;；]", line)]
        segs = [s for s in segs if s and not any(b in s for b in BLACKLIST)]
        if not segs:
            continue
        segs = segs[:4]
        merged = "，".join(segs)
        while len(merged) > 30 and len(segs) > 1:
            segs.pop()
            merged = "，".join(segs)
        out.append(merged)
        if len(out) >= 3:
            break
    return out


def load_ipa(path: str) -> dict[str, str]:
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if "\t" not in line:
                continue
            w, p = line.rstrip("\n").split("\t", 1)
            table.setdefault(w.lower(), p.strip())
    return table


ARPABET = {
    "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
    "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "EH": "ɛ", "ER": "ɝ",
    "EY": "eɪ", "F": "f", "G": "ɡ", "HH": "h", "IH": "ɪ", "IY": "i",
    "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ",
    "OW": "oʊ", "OY": "ɔɪ", "P": "p", "R": "ɹ", "S": "s", "SH": "ʃ",
    "T": "t", "TH": "θ", "UH": "ʊ", "UW": "u", "V": "v", "W": "w",
    "Y": "j", "Z": "z", "ZH": "ʒ",
}
VOWELS = {"AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH",
          "IY", "OW", "OY", "UH", "UW"}


# 英语允许的音节首辅音丛，用 CMUdict 的 ARPAbet 音素表示
# （k 是 K、c 是 K，所以 clap 是 K L，不是 C L）
ONSETS = {
    "BL", "BR", "CH", "KL", "KR", "KW", "DR", "DW", "FL", "FR", "GL", "GR",
    "PL", "PR", "SH", "SK", "SL", "SM", "SN", "SP", "ST", "SW", "TH", "TR",
    "TW", "WH", "KN", "WR", "HHW",
    "SPL", "SPR", "STR", "SKR", "SHR", "SKW", "THR",
}


def onset_start(i: int, is_vowel: list[bool], phones: list[str]) -> int:
    """返回第 i 个元音所属音节的首辅音位置（最大音节首原则的简化版）。"""
    run = []
    j = i - 1
    while j >= 0 and not is_vowel[j]:
        run.insert(0, phones[j][:-1] if phones[j][-1].isdigit() else phones[j])
        j -= 1
    if not run:
        return i
    for take in range(min(3, len(run)), 0, -1):
        if take == 1 or "".join(run[-take:]) in ONSETS:
            return i - take
    return i - 1


def load_cmudict(path: str) -> dict[str, str]:
    """CMUdict（BSD-2）ARPAbet → 标准 IPA。比 ipa-dict 的 /ə/ 记法更适合教学。"""
    table = {}
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            word, phones = parts
            phone_list = phones.split()
            word = word.strip().lower()
            if word.endswith(")") and "(" in word:
                continue  # 备用读音，只留第一套
            if not re.fullmatch(r"[a-z]{2,20}", word):
                continue
            syms, is_vowel, stresses = [], [], []
            for ph in phone_list:
                stress = ph[-1] if ph[-1].isdigit() else ""
                base = ph[:-1] if stress else ph
                if base in ("AH", "ER") and stress == "0":
                    sym = "ə" if base == "AH" else "ɚ"
                else:
                    sym = ARPABET.get(base)
                    if sym is None:
                        sym = ""
                syms.append(sym)
                is_vowel.append(base in VOWELS)
                stresses.append(stress)

            # 重音符号放在音节首（onset）之前：sandbox → /ˈsændˌbɑks/
            marks = []
            for i, (v, st) in enumerate(zip(is_vowel, stresses)):
                if not v or st not in ("1", "2"):
                    continue
                marks.append((onset_start(i, is_vowel, phone_list), "ˈ" if st == "1" else "ˌ"))
            for pos, mark in sorted(marks, reverse=True):
                syms.insert(pos, mark)
            table.setdefault(word, "/" + "".join(syms) + "/")
    return table


def build_base(ecdict: str, ipa: dict[str, str], cmu: dict[str, str],
               extra_words: set[str]) -> int:
    rows = []
    with open(ecdict, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            w = (r.get("word") or "").strip().lower()
            if not re.fullmatch(r"[a-z]{2,20}", w):
                continue
            try:
                frq = int(r.get("frq") or 0)
                bnc = int(r.get("bnc") or 0)
                collins = int(r.get("collins") or 0)
            except ValueError:
                continue
            # 录音词表里的词必须有释义，哪怕词频很低（如 giraffe / koala）
            if w not in extra_words and not (collins or 0 < frq <= 8000 or 0 < bnc <= 8000):
                continue
            zh = clean_zh(r.get("translation") or "")
            if w in EXTRA_ZH:
                zh = [EXTRA_ZH[w]]
            if not zh:
                continue
            if w in ZH_OVERRIDES:
                zh = [ZH_OVERRIDES[w]]
            forms = []
            for part in (r.get("exchange") or "").split("/"):
                if ":" in part:
                    typ, vals = part.split(":", 1)
                    if typ in ("s", "p", "d", "i", "3", "r", "t"):
                        forms += [v for v in vals.split(",") if re.fullmatch(r"[a-z]{2,20}", v)]
            rows.append((
                w,
                cmu.get(w) or ipa.get(w, ""),
                "；".join(zh),
                ",".join(sorted(set(forms))),
                collins,
                frq,
                bnc,
            ))
    # ECDICT 里查不到、但录音词表需要的词（如 donut），用人工释义补上
    seen = {r[0] for r in rows}
    for w, zh in EXTRA_ZH.items():
        if w in extra_words and w not in seen:
            rows.append((w, cmu.get(w) or ipa.get(w, ""), zh, "", 0, 99999, 99999))

    rows.sort(key=lambda x: (-x[4], x[5] or 99999, x[6] or 99999, x[0]))
    out = os.path.join(DATA, "dict_base.tsv.gz")
    with gzip.open(out, "wt", encoding="utf-8", compresslevel=9) as f:
        for row in rows:
            f.write("\t".join(str(c) for c in row) + "\n")
    print(f"  dict_base: {len(rows)} 词, {os.path.getsize(out)/1024/1024:.2f} MB")
    return len(rows)


def load_kid_words() -> list[tuple[str, str, str, str]]:
    rows = []
    with open(os.path.join(DATA, "kid_words.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) != 4:
                raise SystemExit(f"kid_words.txt 行格式不对：{line}")
            rows.append(tuple(p.strip() for p in parts))
    return rows


def load_audio_words() -> list[str]:
    """真人录音词表：与人工童词表解耦，可以只有单词、不需要释义。"""
    path = os.path.join(DATA, "audio_words.txt")
    if not os.path.exists(path):
        return [w for w, *_ in load_kid_words()]
    words = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                words.append(line.lower())
    return words


def pick_audio(word: str, images: list[str]) -> list[str]:
    """从 Wiktionary 页面引用的音频里挑一个发音文件。"""
    def score(title: str) -> int:
        name = title.lower()
        if not name.endswith((".ogg", ".oga", ".wav", ".mp3")):
            return -1
        # 只认英语录音：en-* 或 Lingua Libre 的 eng
        bare = name[5:] if name.startswith("file:") else name
        if not (bare.startswith("en-") or "ll-q1860 (eng)" in name):
            return -1
        stem = re.sub(r"\.(ogg|oga|wav|mp3)$", "", name)
        tokens = re.split(r"[-_ ]", stem)
        if word not in tokens:
            return -1
        s = 0
        if tokens and tokens[-1] == word:
            s += 100
        if "en-us" in name:
            s += 40
        elif "ll-q1860 (eng)" in name:
            s += 30
        elif "en-uk" in name or "en-gb" in name:
            s += 25
        elif re.search(r"en-(au|ca|nz|ie|za|in)-", name):
            s += 5
        for bad in ("article", "song", "juice", "clicker", "back", "irene", "suck eggs"):
            if bad in name:
                s -= 80
        return s

    scored = [(score(t), t) for t in images]
    scored = [x for x in scored if x[0] >= 0]
    scored.sort(reverse=True)
    return [t for _, t in scored]


def fetch_credit(title: str) -> dict:
    if not title.lower().startswith("file:"):
        title = "File:" + title
    q = urllib.parse.urlencode({
        "action": "query", "format": "json", "titles": title,
        "prop": "imageinfo", "iiprop": "url|size|extmetadata",
    })
    d = curl_json("https://commons.wikimedia.org/w/api.php?" + q)
    pages = d.get("query", {}).get("pages", {})
    for pid, p in pages.items():
        if int(pid) < 0:
            continue
        info = p["imageinfo"][0]
        meta = info.get("extmetadata", {})
        return {
            "title": p["title"],
            "url": info["url"],
            "page": "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(p["title"].replace(" ", "_")),
            "license": (meta.get("LicenseShortName", {}) or {}).get("value", ""),
            "artist": re.sub(r"<[^>]+>", "", (meta.get("Artist", {}) or {}).get("value", "")).strip(),
            "size": info.get("size", 0),
        }
    raise RuntimeError(f"文件不存在：{title}")


def transcode(src: str, dst_normal: str, dst_slow: str) -> float:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", src,
                    "-ac", "1", "-ar", "44100", "-b:a", "64k", dst_normal], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", src,
                    "-filter:a", "atempo=0.72",
                    "-ac", "1", "-ar", "44100", "-b:a", "64k", dst_slow], check=True)
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", dst_normal],
                         capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


COMMONS_API = "https://commons.wikimedia.org/w/api.php"
CANONICAL_PREFIXES = ("En-us", "En-uk", "En-au", "En-ca")


def credit_from_info(title: str, info: dict) -> dict:
    meta = info.get("extmetadata", {})
    return {
        "title": title,
        "url": info["url"],
        "page": "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_")),
        "license": (meta.get("LicenseShortName", {}) or {}).get("value", ""),
        "artist": re.sub(r"<[^>]+>", "", (meta.get("Artist", {}) or {}).get("value", "")).strip(),
        "size": info.get("size", 0),
    }


def title_variants(word: str) -> list[str]:
    """Commons 上的常见命名：大小写、ogg/oga 两种后缀。"""
    out = []
    for p in CANONICAL_PREFIXES[:2]:
        for form in (word, word.capitalize()):
            for ext in ("ogg", "oga"):
                out.append(f"File:{p}-{form}.{ext}")
    return out


def resolve_canonical(words: list[str]) -> dict[str, dict]:
    """批量查 Commons 上的标准命名录音。

    一次请求查 10 个词（4 种命名变体），1000 词约 100 次调用，不会被限流。
    """
    found: dict[str, dict] = {}
    batch = 5  # 每个词 8 种命名变体，一批 40 个标题，低于 API 的 50 上限
    for i in range(0, len(words), batch):
        chunk = words[i:i + batch]
        titles = []
        for w in chunk:
            titles += title_variants(w)
        q = urllib.parse.urlencode({
            "action": "query", "format": "json", "titles": "|".join(titles),
            "prop": "imageinfo", "iiprop": "url|size|extmetadata",
        })
        try:
            d = curl_json(COMMONS_API + "?" + q)
        except Exception as e:  # noqa: BLE001
            print(f"  ⚠ 批量查询失败（{i}）：{e}")
            continue
        pages = {p["title"]: p["imageinfo"][0]
                 for pid, p in d.get("query", {}).get("pages", {}).items()
                 if int(pid) > 0 and p.get("imageinfo")}
        for w in chunk:
            for title in title_variants(w):
                if title in pages:
                    found[w] = credit_from_info(title, pages[title])
                    break
        time.sleep(0.4)
    return found


def fetch_one_audio(word: str) -> tuple[str, dict | None, str]:
    """Wiktionary 页面兜底：找标准命名之外的录音（如 LL-Q1860 真人朗读）。"""
    try:
        q = urllib.parse.urlencode({"action": "parse", "page": word,
                                    "prop": "images", "format": "json", "formatversion": "2"})
        d = curl_json("https://en.wiktionary.org/w/api.php?" + q)
        images = d.get("parse", {}).get("images", [])
        candidates = ([MANUAL_AUDIO[word]] if word in MANUAL_AUDIO else []) + pick_audio(word, images)
        if not candidates:
            # 月份 / 星期这类词条页面是首字母大写
            q = urllib.parse.urlencode({"action": "parse", "page": word.capitalize(),
                                        "prop": "images", "format": "json", "formatversion": "2"})
            d = curl_json("https://en.wiktionary.org/w/api.php?" + q)
            images = d.get("parse", {}).get("images", [])
            candidates = pick_audio(word, images)
        if not candidates:
            return word, None, "无发音文件"
        for title in candidates[:4]:
            try:
                return word, fetch_credit(title), "wiktionary"
            except Exception:  # noqa: BLE001
                continue
        return word, None, "候选文件都取不到"
    except Exception as e:  # noqa: BLE001
        return word, None, str(e)


def encode_audio(word: str, credit: dict) -> tuple[str, str]:
    """下载 + 转码正常 / 慢读两份，返回 (word, 说明或错误)。"""
    normal = os.path.join(AUDIO, f"{word}.mp3")
    slow = os.path.join(AUDIO, f"{word}.sl.mp3")
    raw_path = os.path.join(AUDIO, f".{word}.src")
    try:
        with open(raw_path, "wb") as f:
            f.write(curl_bytes(credit["url"]))
        dur = transcode(raw_path, normal, slow)
        os.remove(raw_path)
        credit["duration"] = round(dur, 2)
        note = f"{credit['title']} ({credit['license']}, {dur:.2f}s)"
        if dur < 0.2 or dur > 3.5:
            note += "  ⚠ 时长异常"
        return word, note
    except Exception as e:  # noqa: BLE001
        for p in (normal, slow, raw_path):
            if os.path.exists(p):
                os.remove(p)
        return word, f"下载/转码失败：{e}"


def build_audio(audio_words: list[str]) -> int:
    os.makedirs(AUDIO, exist_ok=True)
    credits_path = os.path.join(AUDIO, "credits.json")
    credits = {}
    if os.path.exists(credits_path):
        with open(credits_path, encoding="utf-8") as f:
            credits = json.load(f)

    def has_pair(w: str) -> bool:
        return (os.path.exists(os.path.join(AUDIO, f"{w}.mp3"))
                and os.path.exists(os.path.join(AUDIO, f"{w}.sl.mp3")))

    pending = [w for w in audio_words if w not in credits or not has_pair(w)]
    print(f"  已有 {len(audio_words) - len(pending)} 个，待抓 {len(pending)} 个")

    # 1) 标准命名批量查（少量请求）
    resolved = resolve_canonical([w for w in pending if w not in MANUAL_FORCE])
    print(f"  标准命名命中 {len(resolved)} 个")

    # 2) 剩下的走 Wiktionary 页面解析（数量很少）
    rest = [w for w in pending if w not in resolved]
    for w in rest:
        word, credit, note = fetch_one_audio(w)
        if credit:
            resolved[word] = credit
        else:
            print(f"  ✗ {word}：{note}")
        time.sleep(0.6)

    # 3) 并发下载 + 转码（打的是 upload.wikimedia.org，不会触发 API 限流）
    done = len(audio_words) - len(pending)
    failed = []
    with ThreadPoolExecutor(max_workers=DOWNLOAD_WORKERS) as pool:
        futures = {pool.submit(encode_audio, w, c): w for w, c in resolved.items()}
        for fut in as_completed(futures):
            word, note = fut.result()
            done += 1
            time.sleep(0.6)
            if note.startswith("下载/转码失败"):
                failed.append(word)
                print(f"[{done}/{len(audio_words)}] {word}  ✗ {note}", flush=True)
                continue
            credits[word] = resolved[word]
            print(f"[{done}/{len(audio_words)}] {word}  ✓ {note}", flush=True)
            if done % 20 == 0:
                with open(credits_path, "w", encoding="utf-8") as f:
                    json.dump(credits, f, ensure_ascii=False, indent=1, sort_keys=True)

    with open(credits_path, "w", encoding="utf-8") as f:
        json.dump(credits, f, ensure_ascii=False, indent=1, sort_keys=True)
    missing = [w for w in audio_words if w not in credits]
    total = sum(os.path.getsize(os.path.join(AUDIO, n))
                for n in os.listdir(AUDIO) if n.endswith(".mp3"))
    print(f"  audio: {len(credits)}/{len(audio_words)} 词, {total/1024/1024:.2f} MB")
    if missing:
        print(f"  无录音（会退回 TTS）：{missing}")
    return len(credits)


def build_kid(kid_rows, ipa: dict[str, str], cmu: dict[str, str], audio_words: set[str]) -> None:
    out = os.path.join(DATA, "dict_kid.tsv.gz")
    with gzip.open(out, "wt", encoding="utf-8", compresslevel=9) as f:
        for word, zh, en, zh_example in kid_rows:
            f.write("\t".join([word, cmu.get(word) or ipa.get(word, ""), zh, en, zh_example,
                               "1" if word in audio_words else "0"]) + "\n")
    print(f"  dict_kid: {len(kid_rows)} 词, {os.path.getsize(out)/1024:.1f} KB")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ecdict", default="/tmp/ecdict.csv")
    ap.add_argument("--ipa", default="/tmp/ipa_us.txt")
    ap.add_argument("--cmudict", default="/tmp/cmudict.dict")
    ap.add_argument("--skip-audio", action="store_true")
    ap.add_argument("--skip-base", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.ecdict):
        sys.exit(f"缺少 ECDICT：{args.ecdict}")
    if not os.path.exists(args.ipa):
        sys.exit(f"缺少 ipa-dict：{args.ipa}")

    os.makedirs(DATA, exist_ok=True)
    ipa = load_ipa(args.ipa)
    cmu = load_cmudict(args.cmudict) if os.path.exists(args.cmudict) else {}
    if not cmu:
        print("⚠ 没有 CMUdict，音标会回落到 ipa-dict（/ʌ/ 可能记成 /ə/）")
    audio_words = load_audio_words()
    print(f"==> 录音词表 {len(audio_words)} 词")

    print("==> 构建 ECDICT 底库")
    if not args.skip_base:
        build_base(args.ecdict, ipa, cmu, set(audio_words))

    print("==> 构建儿童词条")
    kid_rows = load_kid_words()
    if not args.skip_audio:
        print("==> 下载并转码真人发音")
        build_audio(audio_words)
    has_audio = set()
    credits_path = os.path.join(AUDIO, "credits.json")
    if os.path.exists(credits_path):
        with open(credits_path, encoding="utf-8") as f:
            has_audio = set(json.load(f))
    build_kid(kid_rows, ipa, cmu, has_audio)

    missing = [w for w, *_ in kid_rows if w not in cmu and w not in ipa]
    if missing:
        print(f"⚠ 没有 IPA 的词：{missing}")


if __name__ == "__main__":
    main()
