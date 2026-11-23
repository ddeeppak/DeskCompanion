# Desk Bridge (runs on your Windows PC)

Lets the Desk Companion app on the iPhone ask an AI on this PC over Wi-Fi.
Brain: **Claude Code CLI** (`claude -p`) with your own Claude login, for personal/development use.
If other people will use the app, switch to a Claude API key instead.

## Start
Double-click `start_bridge.bat` (or run `python desk_bridge.py`).
- The first time, Windows Firewall asks about Python: allow **Private networks**.
- The window shows the **pairing code**. Enter it on the iPhone in Settings → AI & Network.
- Keep the window open while you use the AI. If the bridge ever stops, the window starts it again after 5 seconds. Close the window to stop it for good.

## Start with Windows (24/7 desk)
- Double-click `autostart_on.bat` once: Desk Bridge then starts minimised every time you sign in.
- `autostart_off.bat` turns it off again.
- The PC must stay awake for the AI to answer. If it sleeps, the iPhone keeps working offline and reconnects by itself.

## Settings (`bridge_config.local.json`, created on first run, not committed)
| Key | Meaning |
|---|---|
| `pairing_code` | 6-digit code the iPhone must send (delete the line to get a new code) |
| `name` | Name shown on the iPhone (default: this PC's name) |
| `model` | `"haiku"` (default, fastest for voice), or `""` for Claude Code's default model, or e.g. `"sonnet"` |
| `effort` | `"low"` (default, quickest), or `""` / `"medium"` / `"high"` |
| `brain` | `"claude"` (default) or `"ollama"` for a free model on this PC (web answers then turn off) |
| `ollama_model` | e.g. `"qwen2.5:7b"` (`"qwen2.5:3b"` on a slow PC; a vision model such as `"qwen2.5vl:7b"` for camera questions) |
| `ollama_url` | `"http://127.0.0.1:11434"` |

### Using Ollama instead of Claude (optional, free, fully local)
1. Install Ollama from ollama.com, then run `ollama pull qwen2.5:7b`.
2. In `bridge_config.local.json` set `"brain": "ollama"`, then restart the bridge.
Small local models follow the app's ACTION rules less reliably than Claude, so commands may fail more often.

## How it works
- `GET /health`: status (name, model, whether the code is right)
- `POST /ask` with header `X-Desk-Code`: `{question, context, history, stream}`
  - `stream: true` → newline-delimited JSON: `{"delta": "..."}` pieces, then `{"done": true, "answer", "ms", "firstMs", "model"}`
  - otherwise → `{answer, ms, firstMs, model}`
- `POST /reset`: start a fresh conversation
- `POST /web {query}`: live web answer (a separate one-off `claude -p` with only WebSearch/WebFetch, about 20 s). Used when Claude replies `QUERY {"type": "web"}`.
- `/ask` also accepts `image` (base64 JPEG from the iPhone's front camera) for camera questions ("What's this?").
- `GET /memory`, `POST /memory {add | remove | clear | replace}`: the PC's backup of long-term memory, in `memory.local.json` (not committed). Since v0.9 the iPhone owns memory and sends it with every question; `replace` is its backup.
- v0.9: Claude can control every app setting (`set_setting`), open screens, play sounds, run and create the user's own commands (`run_routine`, `create_routine`) and more; see `SYSTEM_PROMPT`.
- Claude can also reply with `QUERY` lines (calendar for any day, tasks, alarms, weather, focus); the phone answers them and Claude continues.
- **One warm Claude Code session** (`--input-format stream-json`) stays running, so answers start in about 1 s instead of paying the 2–3 s start-up each time. It remembers the conversation and refreshes after 30 min idle or 40 questions.
- Claude Code runs in an empty temp folder with **no tools**, no MCP servers and no saved session, so it only answers.
- Bonjour (`dns-sd`) advertises `_deskbridge._tcp` so the iPhone finds the PC automatically.
