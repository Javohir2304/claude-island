# Orol (claude-island)

[English](README.md) · Oʻzbekcha

Mac notch'i uchun Dynamic Island, ichida Claude bilan. iPhone'dagi Dynamic Island gʻoyasi va
[hey-claude](https://github.com/kamol1dn/hey-claude) (Windows uchun ovozli yordamchi) loyihasining
gʻoyalari bitta native macOS ilovasiga birlashtirilgan. Swift va SwiftUI'da yozilgan, tashqi
kutubxonalarsiz.

## Nima qiladi

**Orolcha (Dynamic Island qismi)**

- Bekor turganda notch ortida yashirinadi. Biror narsa boʻlayotganda notch'ning ikki yoniga kengayadi.
- Sichqonchani notch ustiga olib borsangiz, panel ochiladi: musiqa, sessiyalar, taymerlar.
- **Musiqa** (Spotify va Music): qoʻshiq nomi, muqova, oldingi / pauza / keyingi tugmalari.
- **Taymer**: “10 daqiqaga taymer qoʻy” deb yozing. Qolgan vaqt notch yonida turadi.
- **Batareya**: quvvatlagich ulanganda, uzilganda va zaryad 20% dan pastga tushganda qisqa xabar.

**Claude (hey-claude qismi)**

- **⌃⌥Space** orolni yozish maydoni sifatida ochadi. Yozing yoki mikrofon tugmasini bosib gapiring.
- Uch qatlam, hey-claude'dagi kabi:

  | qatlam | nima uchun | qanday ishlaydi |
  |---|---|---|
  | tezkor javob | “Yerdan Oygacha necha kilometr?” | doim tayyor turgan, asbobsiz `claude` jarayoni (1–3 soniya) |
  | qidiruv agenti | “Notion'dagi oʻqish sahifamda nima bor?” | asboblar va connector'lari bor `claude` jarayoni |
  | vazifa | “vazifa orol: README'ni yangila” | oʻsha loyiha papkasida alohida Claude Code sessiyasi |

- **Claude Code sessiyalarini kuzatish.** Terminal, VS Code yoki Claude Desktop'dagi har bir sessiya
  orolda koʻrinadi: hozir nima qilayotgani, nechta qator oʻzgargani, tugagani.
- **Ruxsat soʻrovlari.** Sessiya ruxsat soʻrasa, orolda karta chiqadi: Ruxsat / Rad etish / Doim /
  Terminalda. Xavfli buyruqlar (`rm -rf`, `git push --force`, `sudo` va boshqalar) ogohlantirish
  bilan chiqadi va ularda “Doim” tugmasi boʻlmaydi.
- **Claude'ning savollari** (AskUserQuestion) orolda variantlar sifatida chiqadi.
- Faylni orolga tashlasangiz, uning yoʻli savolga qoʻshiladi.

## Claude'siz ham ishlaydi

Orolning oʻzi Claude'ga bogʻliq emas. Claude — uning ustiga qoʻshilgan imkoniyat. Internet yoʻq boʻlsa,
Claude limiti tugagan boʻlsa yoki hisobga kirilmagan boʻlsa:

- musiqa, taymerlar, batareya va Claude Code sessiyalarini kuzatish odatdagidek ishlaydi;
- yozish maydoni **orolning oʻz buyruqlariga** javob beradi (modelsiz, bir zumda):

  | buyruq | misol |
  |---|---|
  | taymer va eslatma | “5 daqiqaga taymer”, “10 daqiqadan keyin choy deb eslat”, “taymer qancha qoldi” |
  | musiqa | “keyingi qoʻshiq”, “pauza”, “qaysi qoʻshiq” |
  | ovoz | “ovoz 30”, “ovozni oʻchir”, “ovozni oshir”, “ovoz necha” |
  | ilovalar | “Safari'ni och”, “open Notion”, “kalkulyatorni och” |
  | tizim | “tungi rejim”, “kunduzgi rejim”, “ekranni qulfla” |
  | hisob-kitob | “(12+8)*3”, “80 ning 15 foizi”, “10 km necha mil”, “100 f necha selsiy” |
  | vaqt | “soat necha”, “bugun nechanchi”, “batareya” |
  | yordam | “yordam” — roʻyxatni koʻrsatadi |

- qolgan savollar **navbatga** qoʻyiladi. Claude qaytishi bilan Orol ularga fonda javob beradi,
  “Javob tayyor” deb xabar qiladi, javob esa paneldagi navbat roʻyxatida turadi;
- panelda Claude holati koʻrinadi: “Internet yoʻq”, “Claude limiti tugadi · 17:30 da tiklanadi”.
  Limit 50% dan oshganda 5 soatlik va haftalik foizlar ham chiqadi.

Limit holati Claude Code'ning oʻz oqimidagi `rate_limit_event` xabaridan olinadi, internet holati esa
macOS'ning tarmoq kuzatuvidan.

## Ovoz: “Hey Claude”, oʻzbekcha tanish va oʻzbekcha javob

Hammasi kompyuterning oʻzida, internetsiz ishlaydi.

**“Hey Claude” deb uygʻotish.** hey-claude'ning umumiy “hey claude” modeli (openWakeWord) ishlatiladi.
Orol mikrofonni oʻzi ushlaydi va ovozni faqat kichik yordamchi dasturga beradi. U hech narsa yozib
olmaydi va hech qayerga yubormaydi, faqat “WAKE” deb javob beradi. Tinglab turganda macOS menyu
satrida toʻq sariq mikrofon nuqtasini koʻrsatadi.

- Uygʻotgandan keyin gapiring. Jim qolganingizda savol yuboriladi va javob ovoz chiqarib aytiladi.
- Adashib uygʻonsa — **“Men emas”** tugmasi.
- “10 daqiqa tinglama”, “tinglashni toʻxtat” yoki menyudagi “Tinglashni 1 soatga toʻxtatish”.
  Hotkey bu paytda ham ishlaydi.
- Orol oʻzi gapirayotgan yoki sizni yozib olayotgan paytda uygʻotuvchi soʻzni tinglamaydi.

**Oʻzbekcha nutqni tanish** — [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal GPU).
Eng yaxshi natijani oʻzbek tiliga oʻqitilgan
[navai-uz/whisper-medium-uzbek](https://huggingface.co/navai-uz/whisper-medium-uzbek) beradi
(Common Voice WER 7,7%, FLEURS 14%). Oddiy large-v3 oʻzbekchani ancha yomon yozadi. Bu model
raqamlarni soʻz bilan yozadi, shuning uchun Orol “oʻn besh daqiqa”ni 15 daqiqa deb tushunadi.

**Oʻzbekcha javob ovozi** — Meta'ning MMS-TTS modeli (VITS, onnxruntime). Lotin yozuvidagi javob kirill
yozuviga, sonlar soʻzga oʻgiriladi. Bitta gap ~0,3 soniyada tayyor boʻladi. Inglizcha va ruscha javoblarni
macOS'ning oʻz ovozlari oʻqiydi.

Oʻrnatish:

```bash
brew install whisper.cpp
S=~/Library/Application\ Support/Orol

# 1. oʻzbekcha nutqni tanish (safetensors -> whisper.cpp, keyin q8_0)
mkdir -p /tmp/uz && cd /tmp/uz
for f in config.json vocab.json model.safetensors; do
  curl -LO https://huggingface.co/navai-uz/whisper-medium-uzbek/resolve/main/$f; done
curl -LO https://raw.githubusercontent.com/openai/whisper/main/whisper/assets/mel_filters.npz
python3 tools/convert_hf_whisper.py /tmp/uz /tmp/uz/mel_filters.npz /tmp/uz/f16.bin   # numpy + safetensors
whisper-quantize /tmp/uz/f16.bin "$S/models/ggml-uz-medium-q8_0.bin" q8_0

# 2. “Hey Claude” va oʻzbekcha ovoz uchun Python muhiti
uv venv --python 3.12 "$S/wake-venv"
uv pip install --python "$S/wake-venv/bin/python" openwakeword onnxruntime numpy
# openWakeWord'ning ikki yordamchi modeli (melspectrogram.onnx, embedding_model.onnx) uning resources/models papkasiga
# hey-claude'ning modeli: github.com/kamol1dn/hey-claude/releases/download/wake-model-v2/hey_claude.onnx -> "$S/wake/"
# MMS-TTS: huggingface.co/davron112/mms-tts-uzb-cyrl-onnx (onnx/model.onnx + vocab.json) -> "$S/tts/"
```

Menyu → **Ovozni tanish** → “Whisper · oʻzbekcha”. Modellar litsenziyasi: “hey claude” modeli
CC BY-NC-SA 4.0, MMS-TTS CC BY-NC 4.0 (ikkalasi ham shaxsiy foydalanish uchun), Whisper fine-tune Apache 2.0.

## Kartalar va Undo

Javob bilan birga karta chiqadi (hey-claude'dagi widget'lar kabi). Ularning hammasi mahalliy maʼlumotdan olinadi:

| soʻrov | karta |
|---|---|
| “tizim holati”, “cpu”, “ram” | batareya, protsessor, xotira, disk, harorat |
| “ovozni 30ga”, “tungi rejim”, “wifi'ni oʻchir” | sozlama oʻzgargani va **Undo** tugmasi |
| “bugun nima rejalarim bor”, “ertaga uchrashuvlar” | macOS Calendar'dagi tadbirlar |
| “ob-havo qanday”, “Samarqandda ob-havo” | hozirgi havo, keyingi soatlar, 3 kun (Open-Meteo, kalitsiz) |
| “qaysi qoʻshiq”, “taymer qancha qoldi” | musiqa va taymerlar |
| “vazifa orol: …” | vazifa kartasi, qadamlari jonli koʻrinadi |

“Bekor qil”, “qaytar” yoki “oops” oxirgi oʻzgarishni qaytaradi. Claude asbob ishlatayotganda
(Kalendar, Notion, internet…) uning belgisi koʻrinadi.

## Ishga tushirish

```bash
./build.sh --install     # yigʻadi va ~/Applications/Orol.app ga nusxalaydi
open ~/Applications/Orol.app
```

Menyu satridagi orol belgisi orqali: sessiyalarni kuzatishni yoqish, ovozli javob, tovushlar,
tizimga kirganda ishga tushirish, sozlamalar fayli.

**Sessiyalarni kuzatish** alohida yoqiladi (menyu → “Claude Code sessiyalarini kuzatish”). Orol
shunda `~/.claude/settings.json` fayliga oʻz hooklarini qoʻshadi. Mavjud hooklaringizga tegmaydi,
avval zaxira nusxa oladi va xuddi shu menyudan toʻliq olib tashlanadi. Orol ishlamayotgan boʻlsa,
hook hech narsa qilmaydi.

## Sozlamalar

`~/Library/Application Support/Orol/config.json`:

| kalit | maʼnosi |
|---|---|
| `hotkey` | `ctrl+alt+space`, `cmd+shift+k`, `f9` kabi |
| `speechEngine` | `whisper` (oʻzbekcha, internetsiz) yoki `apple` |
| `whisperLanguage` | Whisper tili: `uz`, `ru`, `en` yoki `auto` |
| `whisperModel` | model fayli (boʻsh boʻlsa eng yaxshisi olinadi) |
| `speechLocale` | Apple uchun til: `en-US` (qurilmaning oʻzida) yoki `ru-RU` (internet kerak) |
| `micOnHotkey` | hotkey bosilganda mikrofon darhol yoqilsinmi |
| `speak` | javobni ovoz chiqarib oʻqish: `off`, `voice` (faqat ovozli soʻrovda), `always` |
| `quickModel`, `agentModel`, `taskModel` | har bir qatlam uchun model (`haiku` tezroq, `sonnet` oʻzbekchani yaxshiroq tushunadi) |
| `agentAllowedTools` | agent soʻramasdan ishlata oladigan asboblar. Qolganlari uchun orolda karta chiqadi |
| `projects` | loyiha nomi → papka, “vazifa <nom>: …” uchun |

Oʻzgartirgandan keyin menyudan “Sozlamalarni qayta yuklash”ni bosing.

## Cheklovlar

- Oʻzbekcha ovoz (MMS-TTS) tushunarli, lekin tabiiy emas, biroz robotga oʻxshaydi.
- Mikrofon va kalendar ruxsatlari ilovaning imzosiga bogʻlangan. Orol qayta yigʻilsa (`./build.sh`),
  macOS ruxsatni yana soʻrashi mumkin.
- Musiqa: Spotify va Music toʻliq (nom, muqova, tugmalar). Yandex Musiqa va brauzerlar ovoz chiqarishi
  orqali aniqlanadi; Yandex'ning qoʻshiq nomi va tugmalari Accessibility ruxsati bilan, uning oynasi
  hozirgi ish stolida ochiq turganda ishlaydi (Stage Manager chetga yigʻgan oynalar koʻrinmaydi).
- Xarita kartalari Yandex'ning kalitsiz Static API'sidan (tirbandlik bilan); u ishlamasa Apple xaritasi.
- “Sessiyaga oʻtish” terminal ilovasini oldinga chiqaradi, aniq oyna yoki tabni emas.

## Tuzilishi

```
Sources/orol-hook/   Claude Code hook sifatida ishlaydigan kichik relay (Unix socket orqali)
Sources/Orol/
  HookServer.swift     relay bilan gaplashadigan server
  Sessions.swift       hook hodisalari → sessiya qatorlari, ruxsat kartalari
  HookInstaller.swift  ~/.claude/settings.json ga hooklarni qoʻshish va olib tashlash
  Assistant.swift      uch qatlam, Claude holati (internet, limit, login), navbat
  LocalBrain.swift     Claude'siz ishlaydigan buyruqlar
  Speech.swift         Apple: mikrofon → matn, javobni oʻqib berish
  Whisper.swift        whisper.cpp serveri, mikrofon → oʻzbekcha matn, gap tugashini aniqlash
  Wake.swift           “Hey Claude”: mikrofon → openWakeWord yordamchisi
  LocalCards.swift     tizim, Wi-Fi, kalendar, ob-havo maʼlumotlari
  CardViews.swift      kartalar
Resources/orol_wake.py   uygʻotuvchi soʻz yordamchisi (openWakeWord)
Resources/orol_tts.py    oʻzbekcha ovoz (MMS-TTS, lotin → kirill, sonlar → soʻz)
tools/convert_hf_whisper.py   Hugging Face Whisper → whisper.cpp konverteri
  System.swift         musiqa, batareya, taymer, global hotkey
  IslandWindow.swift   notch ustidagi oyna, sichqoncha kuzatuvi
  Views.swift          orolning barcha koʻrinishlari
  Shots.swift          har bir holatni PNG qilib chizish:  Orol --shots <papka>
```

Hook relay dizayni hey-claude'ning M7 bosqichidan olingan: har qanday xatoda jim chiqib ketadi va
foydalanuvchi bosmaguncha hech narsaga ruxsat bermaydi.

## Kartalar (widgetlar)

Javoblar panelda kartalar bilan chiqadi; bitta panelda 3 tagacha karta ustma-ust yig'iladi.

| Aytasiz | Karta | Manba |
|---|---|---|
| "Chorsuga qanday boraman", "... piyoda", "... avtobusda" | Yo'l: Yandex xaritasi (tirbandlik), vaqt, masofa, "Yandex Xaritalar" tugmasi | Apple Maps / OpenStreetMap yo'li, Yandex xaritasi |
| "Amir Temur xiyoboni qayerda joylashgan" | Joy: xarita, manzil, masofa | Apple Maps |
| "100 dollar necha so'm", "dollar kursi" | Valyuta | open.er-api.com (oxirgi kurs saqlanadi) |
| "tizim holati" | CPU/GPU yoylari, RAM, disk, batareya | Mac'ning o'zi |
| "yangiliklar" | Kun.uz va Daryo sarlavhalari | RSS |
| "bugungi darslar", "keyingi dars" | Dars jadvali (hozirgi va keyingi dars) | Calendar |
| "muddatlarim" | Muddatlar, qolgan vaqt bilan | Reminders va Calendar |
| "pochtam" (Mail ochiq bo'lsa) | Xatlar | Mail.app |
| "buferda nima bor" | Bufer: matn, havola, kod, rasm, fayl | Mac'ning o'zi |
| "skrinshot ol" | Rasm (Rasmlar → Orol) | screencapture |
| "serendipity ma'nosi" | Lug'at | macOS lug'ati (inglizcha) |
| "10 km necha mil" | Birliklar | Mac'ning o'zi |
| "Azizga telegramda ... deb yoz" | Telegram qoralamasi (yuborishni o'zingiz qilasiz) | — |
| Tarjima, kod, havola, ma'no, Claude topgan yangilik/xatlar | Claude javobiga qo'shgan karta | Claude |

Telegram chatlarini o'qish uchun Telegram API (my.telegram.org) orqali kirish kerak; hozircha faqat qoralama.
