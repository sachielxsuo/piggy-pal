# 真人发音数据

`../audio_words.txt` 里 983 个词的 `*.mp3` 均来自 **Wiktionary / Wikimedia Commons** 的真人读音录音，
由本项目转码为 64 kbps 单声道 mp3；`*.sl.mp3` 是同一段录音用
`ffmpeg atempo=0.72` 变速得到（保持音高），用于「慢读」。

- 逐条来源、作者、许可：见 `credits.json`
- 许可：以 `credits.json` 里每条记录的 `license` 为准，绝大多数为
  **CC BY-SA 3.0 / CC BY-SA 4.0 / CC BY 3.0**，少量 Public Domain / CC0
- 合规要求：使用或再分发这些录音（含变速版本）时，必须保留作者署名与许可，
  衍生音频需以相同许可共享。App 内在每个词条底部和「关于 → 词典与发音来源」
  展示署名；新增词条时请同步更新 `credits.json`。

文本数据来源：

| 数据 | 来源 | 许可 |
| --- | --- | --- |
| 中文释义 / 词形 | [ECDICT](https://github.com/skywind3000/ECDICT) | MIT |
| 音标 | [CMU Pronouncing Dictionary](https://github.com/cmusphinx/cmudict) | BSD-2-Clause |
| 音标兜底 | [ipa-dict](https://github.com/open-dict-data/ipa-dict) | MIT |
| 儿童释义 / 例句 | 本项目人工改写（`../kid_words.txt`） | 本项目所有 |

重新生成：`python3 scripts/build_dict.py --ecdict <ecdict.csv> --ipa <ipa_us.txt> --cmudict <cmudict.dict>`。
