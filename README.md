# Desk Companion

Personal desk companion for iPhone 7 Plus (iOS 15, landscape, always on).
Design: `../design/claude-design-v1/` · Plan: `../desk-companion-backlog.md`

## Build & install
1. Push to `main`. GitHub Actions builds `DeskCompanion.ipa` (Actions tab → latest run → Artifacts).
2. Install with Sideloadly (free Apple ID). Re-install every 7 days; app data is kept.

## Structure
| Folder | Contents |
|---|---|
| `Sources/App` | App entry, global state (screen, style, rail auto-hide), battery |
| `Sources/Theme` | 3 styles (Calm / Futuristic / Warm) as design tokens, backgrounds |
| `Sources/Components` | Rail, status cluster, header, cards, lists |
| `Sources/Services` | Location, weather, barometer, night mode, calendar/reminders, habits, focus timer, sound |
| `Sources/Screens` | Home, Night, Today, Focus, Settings (+ Assistant placeholder) |

## Progress
- [x] Step 1: Foundation (navigation, 3 styles + switcher, landscape, always-on, rail auto-hide)
- [x] Step 2: Home data + Night clock (weather, sunrise/sunset, barometer trend, automatic night clock, paw icon)
- [x] Step 3: Today (Calendar, Reminders, habits, Up Next + tasks on Home, reminder alert banner)
- [x] Step 4: Focus timer (ring, presets, custom, sounds, chime, session done)
- [x] Alarms (in-app, with backup notification) + custom focus sounds
- [x] Step 5: Voice assistant (offline): speech, spoken replies, timers, alarms, reminders, lists, agenda, weather, focus, undo
- [x] Step 6: Local AI on PC: Desk Bridge (Claude Code, Haiku, low effort, warm streaming session), auto-discovery, pairing code
- [x] Step 7: Sensors: Away mode (front camera, on-device), wave to talk/brighten (proximity), noise meter
- [x] 0.8: Smart assistant: AI lookups (calendar any day, tasks, alarms, weather, focus) + edit actions, long-term memory on the PC, morning/evening briefings and event heads-ups, conversation mode
- [x] 0.8.1–0.8.2: better listening (server speech recognition, hints), conversation endings, natural commands (remove / tick off / any day's calendar), town name on Home
- [x] 0.9: full voice control of every setting and screen, AI-first understanding with phone fallback, your own commands (by voice or Settings → Commands, with time / sit-down triggers), learned phrases, memory on the iPhone (PC backup), yes/no confirmation (voice, buttons or wave), Undo for every change
- [x] Step 8 / 1.0: polish and stability: self-recovering audio (alarms survive Siri, calls and iOS audio resets), microphone interruption handling, Stability report for the 48-hour test (Settings → About), Privacy screen (permissions, what leaves the phone, stored data, on-device speech option), Increase Contrast support, bridge auto-restart and start-with-Windows scripts, "Test the AI" kept out of the conversation
- [x] 1.0 extras: live web answers (news, scores, prices; about 20 s), camera questions ("What's this?", "Read this", "Translate this" with the front camera), conversation text size, optional free local brain (Ollama)
