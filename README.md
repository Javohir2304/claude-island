# claude-island (Orol) — a Dynamic Island for the Mac, with Claude inside

English · [Oʻzbekcha](README.uz.md)

A native macOS app (Swift + SwiftUI, no third-party libraries) that turns the MacBook notch into an
iPhone-style Dynamic Island and puts Claude in it. It follows Apple's Live Activities guidelines
(compact, minimal and expanded presentations) and borrows the voice-assistant and widget ideas of
[hey-claude](https://github.com/kamol1dn/hey-claude) (a Windows app), rebuilt from scratch for macOS.
The app is called **Orol** ("island" in Uzbek); its own phrases are mostly Uzbek, and Claude answers in
whatever language you use.

## What it does

**The island**
- Hides behind the notch when idle. With one activity it shows a compact leading/trailing pair snug
  around the camera; with two or more, the first stays attached and the next one appears detached in a
  small bubble, like on iPhone. A thin key line in the activity's colour keeps it visible on dark menu bars.
- Activities: music (Spotify, Music; Yandex Music and browsers detected by their sound), timers and
  reminders, Claude Code sessions, answers that arrived while you were away.
- Alerts: charging, low battery, headphones connected (with AirPods battery), silent mode, unlock.
- Click the compact island to open the activity's app; rest the pointer on it to expand it.

**Claude**
- `⌃⌥Space` opens a talk-or-type field. Three tiers: a warm tool-less process for quick answers, a
  lookup agent with your tools and connectors, and tasks that start a Claude Code session in a project.
- Watches your Claude Code sessions (Terminal, VS Code, Desktop) through hooks: what each one is doing,
  lines changed, when it finishes. Permission requests and `AskUserQuestion` appear as cards you can
  answer from the island; dangerous commands are flagged and never get an "Always" button.
- Works without Claude too: its own commands (timers, music, volume, apps, dark mode, maths, units,
  clock…) answer instantly offline, and other questions wait in a queue until Claude is back.

**Voice ("Ember & Thread" design)**
- "Hey Claude" wake word (openWakeWord), speech-to-text with whisper.cpp on the GPU, spoken answers.
- The ember-and-thread animation shows the state by shape: a wave flowing in while listening, pen
  loops while thinking, a wave flowing out (following the voice) while speaking.

**Cards** — answers come with cards, up to three stacked in the panel:

| Ask | Card | Source |
|---|---|---|
| "how do I get to …", "… by bus" (Uzbek phrases too) | Route on a Yandex map with live traffic, time, distance, arrival, "open in Yandex Maps" | Apple Maps / OpenStreetMap routing |
| "where is …" | Place with map, address, distance | Apple Maps |
| "100 dollars in so'm" | Currency | open.er-api.com (rates cached) |
| "system status" | CPU / GPU gauges, RAM, disk, battery | the Mac |
| "news" | Headlines | RSS (configurable in code) |
| "today's classes", "my deadlines" | Timetable, deadlines with countdowns | Calendar, Reminders |
| "what's on the clipboard", "take a screenshot" | Clipboard, image | the Mac |
| "define serendipity", "10 km in miles" | Dictionary, units | macOS Dictionary |
| weather, calendar, timers, volume / Wi-Fi / dark mode (with Undo) | … | Open-Meteo, Calendar, the Mac |
| translations, code, links, definitions, news or mail Claude found | Card attached by Claude | Claude |

## Requirements

- macOS 14 or later, Apple silicon recommended (a notch is optional: without one a small pill is used).
- Xcode command-line tools (Swift 5.10+).
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your PATH) for the Claude parts.

## Build and run

```bash
./build.sh --install          # builds and copies to ~/Applications/Orol.app
open ~/Applications/Orol.app
```

Turn on session watching from the menu-bar icon ("Claude Code sessions"). Orol then adds its hooks to
`~/.claude/settings.json`, keeps a backup, never touches your other hooks, and removes them from the
same menu. When Orol isn't running the hook does nothing.

macOS asks for permissions as features are used: Microphone, Calendars, Reminders, Location (routes
from where you are), Automation (Music/Spotify/Mail), Accessibility (only for controlling players that
have no AppleScript, such as Yandex Music) and Screen Recording (screenshots).

## Optional: voice models

Everything runs on the Mac. Speech recognition is tuned for Uzbek but other Whisper models work too.

```bash
brew install whisper.cpp
S=~/Library/Application\ Support/Orol

# Speech recognition: any whisper.cpp model in "$S/models/" (for Uzbek, convert
# navai-uz/whisper-medium-uzbek with tools/convert_hf_whisper.py, then whisper-quantize … q8_0)

# Python environment for the wake word and the Uzbek voice
uv venv --python 3.12 "$S/wake-venv"
uv pip install --python "$S/wake-venv/bin/python" openwakeword onnxruntime numpy
# "hey claude" model: github.com/kamol1dn/hey-claude/releases/download/wake-model-v2/hey_claude.onnx -> "$S/wake/"
# Uzbek voice: huggingface.co/davron112/mms-tts-uzb-cyrl-onnx (model.onnx + vocab.json) -> "$S/tts/"
```

Model licences are separate from this code: the "hey claude" wake model is CC BY-NC-SA 4.0, MMS-TTS is
CC BY-NC 4.0 (both non-commercial), the Uzbek Whisper fine-tune is Apache 2.0. No model is included here.

## Settings

`~/Library/Application Support/Orol/config.json` (reload from the menu after editing):

| key | meaning |
|---|---|
| `hotkey` | e.g. `ctrl+alt+space`, `cmd+shift+k`, `f9` |
| `speechEngine`, `whisperLanguage`, `whisperModel` | `whisper` or `apple`; `uz`, `en`, `ru`, `auto`; model file |
| `speak` | read answers aloud: `off`, `voice` (only spoken requests), `always` |
| `quickModel`, `agentModel`, `taskModel` | model per tier (`haiku`, `sonnet`, …) |
| `agentAllowedTools` | tools the lookup agent may use without asking (add your MCP tools here) |
| `projects` | project name → folder, for "task <name>: …" |
| `wakeWord`, `wakeThreshold` | the "Hey Claude" listener |
| `weatherCity`, `weatherLat`, `weatherLon` | home place for weather and routes without a location |

## Privacy

Nothing is sent anywhere except what a feature needs: questions go to Claude through your own `claude`
CLI; map searches and routes go to Apple Maps, OpenStreetMap's public router and Yandex's static maps;
weather to Open-Meteo, rates to open.er-api.com, news to the RSS feeds. The wake word, speech
recognition and the Uzbek voice run locally.

## Limitations

- The Uzbek voice is clear but a little robotic.
- Since macOS 15.4 other apps can't read the system "Now Playing" info, so players without AppleScript
  (Yandex Music, browsers) are detected by their sound; Yandex's track name and buttons are read through
  Accessibility while its window is on the current desktop.
- The keyless Yandex static-map endpoint may change; the Apple map is used when it fails.
- "Jump to session" brings the terminal app forward, not the exact tab.

## Credits

- [hey-claude](https://github.com/kamol1dn/hey-claude) — the voice-assistant, widgets, hook relay and
  "Ember & Thread" motion ideas this app reimplements in Swift (no code or assets are copied).
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [openWakeWord](https://github.com/dscripka/openWakeWord),
  Meta MMS-TTS, Apple MapKit, OpenStreetMap, Yandex Maps.

## License

MIT — see [LICENSE](LICENSE).
