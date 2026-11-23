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
- [ ] Step 5: Voice assistant (offline)
- [ ] Step 6: Local AI on PC
- [ ] Step 7: Sensors
- [ ] Step 8: Polish
