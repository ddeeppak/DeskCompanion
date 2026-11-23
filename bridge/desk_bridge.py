"""
Desk Bridge: lets the Desk Companion iPhone app ask an AI running on this PC.

Brain: the Claude Code CLI, kept warm as ONE persistent headless session
(`claude -p --input-format stream-json --output-format stream-json`), so answers start in ~1 s
instead of paying Claude Code's ~2-3 s start-up on every question. Uses your own Claude login.

- Fastest settings by default: model "haiku", effort "low" (change in bridge_config.local.json).
- Streaming: the phone receives the answer piece by piece and starts speaking at the first sentence.
- The session remembers the conversation; it is refreshed after 30 min idle, 40 questions, or /reset.
- The iPhone finds this PC automatically on Wi-Fi (Bonjour) and must send the pairing code.

Run:    python desk_bridge.py            (or double-click start_bridge.bat)
Stop:   Ctrl+C
Only the Python standard library is used.
"""
import json
import os
import queue
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
SERVICE_TYPE = "_deskbridge._tcp"
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "bridge_config.local.json")       # git-ignored: holds the pairing code
WORK_DIR = os.path.join(tempfile.gettempdir(), "desk-bridge-empty")   # Claude runs here: no project files
VERSION = 5
MAX_TURNS = 40                 # refresh the session after this many questions
IDLE_RESET_S = 30 * 60         # ...or after 30 minutes without questions
ANSWER_TIMEOUT_S = 60
WEB_TIMEOUT_S = 90
MAX_REQUEST_BYTES = 4_000_000   # room for a photo
MEMORY_PATH = os.path.join(HERE, "memory.local.json")              # git-ignored: facts the user asked to remember
MAX_MEMORIES = 60

SYSTEM_PROMPT = (
    "You are Desk Companion, a friendly voice assistant on the user's home desk display (an iPhone). "
    "Your reply is spoken aloud by a text-to-speech voice, so answer in 1 to 3 short, natural sentences. "
    "Plain text only: no markdown, lists, headings, emoji, URLs or code.\n"
    "Each user message may start with a Context line: the current date and time ('now', YYYY-MM-DDTHH:MM), weather, "
    "today's events and open tasks, 'memory' (facts the user asked you to remember), 'screen' (what the display "
    "shows now), 'settings' (current app settings), 'my commands' (the user's own commands), 'sounds' and 'habits'. "
    "A message may include a photo from the desk iPhone's front camera (mirrored, sometimes blurry): answer about "
    "what the user is showing, and read any text in it the right way round. "
    "Use them naturally; never invent events, tasks or facts, and don't list tasks or events unless asked. "
    "Interpret 'this', 'it' and bare numbers using the screen (on the Focus screen, 'make it 50' means focus_minutes 50).\n"
    "The user's words come from speech recognition and often contain misheard words (for example 'college' for "
    "'calendar', 'holiday I deployed' for 'holidays in December'). Work out the most likely meaning from the "
    "conversation and Context before asking them to repeat. When they mention a day or date, look it up with a "
    "QUERY instead of asking what they want. If they just say thanks or goodbye, reply with a very short closing.\n\n"
    "LOOKUPS. If you need information that is not in the Context, your WHOLE reply must be only QUERY lines "
    "(one per lookup), with no words before them: never explain or announce a lookup, and never say how you "
    "understood a misheard phrase. The phone replies with a RESULTS message, then you answer or act. Available lookups:\n"
    'QUERY {"type": "events", "date": "2026-11-26"}   (calendar for any day)\n'
    'QUERY {"type": "tasks"}   (open tasks and tasks done today)\n'
    'QUERY {"type": "alarms"}\n'
    'QUERY {"type": "weather", "day": "tomorrow"}   ("today" or "tomorrow")\n'
    'QUERY {"type": "focus"}   (focus time and sessions today)\n'
    'QUERY {"type": "web", "q": "India vs Australia score today"}   (live web search; takes about 20 seconds, so '
    'use it only for news, sports, prices, opening hours, recent events and other facts that change or that you '
    'do not know. Never for things you are sure about.)\n\n'
    "MY COMMANDS COME FIRST. Before anything else, compare the request with 'my commands' in the Context. If it "
    "means the same thing as one of them, even in completely different words ('I'm heading to bed' = a command "
    "called Good night, 'film time' = Movie time), reply only with its run_routine ACTION: no lookups, no questions.\n\n"
    "ACTIONS. When the user wants something done, your WHOLE reply must be only ACTION lines: no explanation before "
    "or after (the phone confirms out loud itself). One line per item, each the word ACTION followed by JSON:\n"
    'ACTION {"type": "timer", "seconds": 600}\n'
    'ACTION {"type": "alarm", "time": "16:30"}   (24-hour; the next time that clock time comes round)\n'
    'ACTION {"type": "reminder", "title": "Call the bank", "due": "2026-11-23T13:30"}   (due may be null)\n'
    'ACTION {"type": "task", "title": "Buy milk"}\n'
    'ACTION {"type": "complete_task", "title": "Pay electricity bill"}\n'
    'ACTION {"type": "delete_task", "title": "Buy eggs"}\n'
    'ACTION {"type": "move_reminder", "title": "Dentist", "due": "2026-11-28T09:00"}\n'
    'ACTION {"type": "delete_alarm", "time": "16:30"}   (or "time": "all")\n'
    'ACTION {"type": "cancel_timer"}\n'
    'ACTION {"type": "focus", "minutes": 25}   and   ACTION {"type": "stop_focus"}\n'
    'ACTION {"type": "set_style", "style": "warm"}   (calm, futuristic or warm)\n'
    'ACTION {"type": "set_setting", "key": "haptics", "value": "off"}   (any setting below; on/off ones also take "toggle")\n'
    'ACTION {"type": "open", "screen": "focus"}   (home, assistant, today, focus or settings; optional "section": ai, '
    'voice, commands, sensors, display, alarms, today)\n'
    'ACTION {"type": "play_sound", "sound": "rain"}   (a name from sounds)   and   ACTION {"type": "stop_sound"}\n'
    'ACTION {"type": "extend_focus", "minutes": 5}   ACTION {"type": "skip"}   ACTION {"type": "start_break"}\n'
    'ACTION {"type": "alarm_on_off", "time": "06:30", "on": false}   ACTION {"type": "snooze"}   ACTION {"type": "stop_alarm"}\n'
    'ACTION {"type": "briefing", "kind": "morning"}   (or "evening": reads a summary of the day)\n'
    'ACTION {"type": "complete_habit", "name": "Water"}\n'
    'ACTION {"type": "remember", "fact": "Mom\'s phone number ends in 42"}\n'
    'ACTION {"type": "forget", "fact": "Mom\'s phone number"}   and   ACTION {"type": "forget_all"}\n'
    'ACTION {"type": "run_routine", "name": "Good night"}   (one of my commands)\n'
    'ACTION {"type": "create_routine", "name": "Movie time", "phrases": ["movie time", "film night"], "actions": '
    '[{"type": "play_sound", "sound": "rain"}, {"type": "set_style", "style": "warm"}], "time": null, "days": [], '
    '"on_arrive": false}   ("time" HH:MM runs it daily, "days" 1=Sunday..7=Saturday, "on_arrive" runs it when the '
    'user sits down; the same name updates an existing command)\n'
    'ACTION {"type": "delete_routine", "name": "Movie time"}\n'
    'ACTION {"type": "look", "question": "What is this?"}   (opens the front camera so you can see what the user '
    'is showing you: use it when they ask you to look at, read, identify or translate something)\n'
    "Settings: style (calm|futuristic|warm), night_mode, night_start, night_end (HH:MM), night_brightness (1-40), "
    "voice_replies, voice_speed (slow|normal|fast), assistant_text (standard|large|extra large), keep_listening, command_routing (ai|phone), haptics, "
    "morning_briefing, evening_wrapup, event_headsup, headsup_minutes, presence_camera, away_minutes, wave, "
    "wave_action (talk|brighten), noise_meter, alarms, snooze_minutes, alarm_volume (5-100), focus_preset "
    "(short|long|custom), focus_minutes, break_minutes, focus_sound, focus_volume (0-100), share_day, learn_phrases.\n"
    "If a request means the same as one of my commands (for example 'I'm off to bed' and a command called Good "
    "night), run it with run_routine. When the user says 'when I say X, do Y', or asks for a new command, routine or "
    "shortcut, use create_routine. Several requests in one sentence = several ACTION lines.\n"
    "Use remember when the user shares something about themselves worth keeping, or asks you to remember it; "
    "write the fact as a short third-person sentence. For titles in complete/delete/move, use the task's name as "
    "it appears in the results. Work out times from 'now' and the events ('after lunch' is about 13:30, 'in an "
    "hour' is now plus 60 minutes, 'before my 9 o'clock meeting' is shortly before it). If an essential detail is "
    "missing (such as the time for an alarm), ask one short question instead. For everything else, answer "
    "normally. If you are not sure, say so briefly."
)

# ---------------------------------------------------------------- config

def load_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            cfg = {}
    if not re.fullmatch(r"\d{6}", str(cfg.get("pairing_code", ""))):
        cfg["pairing_code"] = f"{random.SystemRandom().randint(0, 999999):06d}"
    cfg.setdefault("name", socket.gethostname() or "My PC")
    # Fastest for voice: Haiku at low effort. Set model/effort to "" for Claude Code's defaults.
    if cfg.get("config_version", 1) < 2:            # first run of v2: switch old defaults to the fast ones
        cfg["model"] = cfg.get("model") or "haiku"
        cfg["effort"] = cfg.get("effort") or "low"
        cfg["config_version"] = 2
    cfg.setdefault("model", "haiku")
    cfg.setdefault("effort", "low")
    # "claude" (Claude Code CLI) or "ollama" (a free model running on this PC, e.g. qwen2.5:7b)
    cfg.setdefault("brain", "claude")
    cfg.setdefault("ollama_model", "qwen2.5:7b")
    cfg.setdefault("ollama_url", "http://127.0.0.1:11434")
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    return cfg

CONFIG = load_config()
CLAUDE = shutil.which("claude")
STATS = {"last_ms": None, "first_ms": None, "answered": 0}

# ---------------------------------------------------------------- long-term memory (stored on this PC)

MEMORY_LOCK = threading.Lock()


def load_memory():
    try:
        with open(MEMORY_PATH, encoding="utf-8") as f:
            items = json.load(f)
        return [str(x) for x in items if str(x).strip()][:MAX_MEMORIES]
    except (OSError, ValueError):
        return []


def save_memory(items):
    with open(MEMORY_PATH, "w", encoding="utf-8") as f:
        json.dump(items[:MAX_MEMORIES], f, indent=2, ensure_ascii=False)


def forget_matching(items, phrase):
    """Removes facts that contain the phrase (or that the phrase contains)."""
    p = phrase.lower().strip()
    if not p:
        return items
    return [x for x in items if p not in x.lower() and x.lower() not in p]


def apply_memory_actions(answer):
    """Saves 'remember' / 'forget' ACTION lines from Claude's answer. The phone just confirms them."""
    changed = False
    with MEMORY_LOCK:
        items = load_memory()
        for line in answer.splitlines():
            if "ACTION" not in line or "{" not in line:
                continue
            try:
                data = json.loads(line[line.index("{"): line.rindex("}") + 1])
            except ValueError:
                continue
            kind = data.get("type")
            fact = str(data.get("fact", "")).strip()
            if kind == "remember" and fact:
                if fact.lower() not in (x.lower() for x in items):
                    items = [fact] + forget_matching(items, fact)   # newest first, replaces close duplicates
                    changed = True
            elif kind == "forget" and fact:
                before = len(items)
                items = forget_matching(items, fact)
                changed = changed or len(items) != before
        if changed:
            save_memory(items)


def clean_for_speech(text):
    text = re.sub(r"[*#`>]+", "", text)            # markdown symbols (underscores kept: ACTION names use them)
    text = re.sub(r"^\s*[-•]\s+", "", text, flags=re.M)
    return re.sub(r"[ \t]+", " ", text)

# ---------------------------------------------------------------- persistent Claude Code session

class ClaudeSession:
    """One warm `claude -p` process in streaming mode. Questions are answered one at a time."""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.events = None
        self.turns = 0
        self.last_used = time.time()
        self.model_used = CONFIG.get("model") or "default"

    def _command(self):
        cmd = [CLAUDE, "-p",
               "--input-format", "stream-json", "--output-format", "stream-json",
               "--verbose", "--include-partial-messages",
               "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
               "--no-session-persistence", "--system-prompt", SYSTEM_PROMPT]
        if CONFIG.get("model"):
            cmd += ["--model", CONFIG["model"]]
        if CONFIG.get("effort"):
            cmd += ["--effort", CONFIG["effort"]]
        return cmd

    def _reader(self, proc, events):
        for line in proc.stdout:
            try:
                events.put(json.loads(line))
            except ValueError:
                continue
        events.put(None)          # process ended

    def start(self):
        """Start (or restart) the warm process. Safe to call while holding the lock."""
        self.stop()
        os.makedirs(WORK_DIR, exist_ok=True)
        self.proc = subprocess.Popen(self._command(), cwd=WORK_DIR, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, encoding="utf-8", errors="replace", bufsize=1)
        self.events = queue.Queue()
        threading.Thread(target=self._reader, args=(self.proc, self.events), daemon=True).start()
        self.turns = 0
        self.last_used = time.time()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
        self.proc = None

    def reset(self):
        with self.lock:
            self.start()

    def _needs_restart(self):
        return (self.proc is None or self.proc.poll() is not None or self.turns >= MAX_TURNS
                or time.time() - self.last_used > IDLE_RESET_S)

    def is_warm(self):
        return self.proc is not None and self.proc.poll() is None

    def ask(self, text, on_delta, image=None):
        """Sends one question (optionally with a photo); calls on_delta(text_piece) while streaming.
        Returns (answer, ms, first_ms)."""
        content = text
        if image:
            content = [{"type": "image", "source": {"type": "base64", "media_type": image.get("type", "image/jpeg"),
                                                     "data": image["data"]}},
                       {"type": "text", "text": text}]
        with self.lock:
            for attempt in range(2):
                if self._needs_restart() or attempt == 1:
                    self.start()
                started = time.time()
                first_ms = None
                pieces = []
                try:
                    self.proc.stdin.write(json.dumps({"type": "user",
                                                      "message": {"role": "user", "content": content}}) + "\n")
                    self.proc.stdin.flush()
                except (OSError, ValueError):
                    continue                              # process died: restart and retry once
                result = None
                while True:
                    try:
                        ev = self.events.get(timeout=ANSWER_TIMEOUT_S)
                    except queue.Empty:
                        self.stop()
                        raise TimeoutError("The AI took too long to answer")
                    if ev is None:
                        break                             # process ended mid-answer
                    if ev.get("type") == "stream_event":
                        e = ev.get("event", {})
                        if e.get("type") == "message_start":
                            self.model_used = e.get("message", {}).get("model", self.model_used)
                        d = e.get("delta", {})
                        if e.get("type") == "content_block_delta" and d.get("type") == "text_delta":
                            if first_ms is None:
                                first_ms = int((time.time() - started) * 1000)
                            pieces.append(d.get("text", ""))
                            on_delta(clean_for_speech(d.get("text", "")))
                    elif ev.get("type") == "result":
                        result = ev
                        break
                if result is None:
                    if pieces:
                        raise RuntimeError("The AI stopped in the middle of the answer")
                    continue                              # nothing sent yet: restart and retry once
                if result.get("is_error"):
                    raise RuntimeError(str(result.get("result") or "Claude Code returned an error")[:300])
                self.turns += 1
                self.last_used = time.time()
                answer = clean_for_speech("".join(pieces) or str(result.get("result", ""))).strip()
                return answer, int((time.time() - started) * 1000), first_ms
            raise RuntimeError("Could not start Claude Code")


class OllamaSession:
    """Same interface as ClaudeSession, but the brain is a free local model served by Ollama on this PC."""

    def __init__(self):
        self.lock = threading.Lock()
        self.history = []
        self.turns = 0
        self.last_used = time.time()
        self.model_used = CONFIG.get("ollama_model") or "qwen2.5:7b"
        self.proc = None

    def _needs_restart(self):
        return self.turns >= MAX_TURNS or time.time() - self.last_used > IDLE_RESET_S

    def is_warm(self):
        return True

    def start(self):
        self.history = []
        self.turns = 0

    def stop(self):
        pass

    def reset(self):
        with self.lock:
            self.start()

    def ask(self, text, on_delta, image=None):
        with self.lock:
            if self._needs_restart():
                self.start()
            message = {"role": "user", "content": text}
            if image:
                message["images"] = [image["data"]]          # needs a vision model, e.g. llava or qwen2.5vl
            messages = [{"role": "system", "content": SYSTEM_PROMPT}] + self.history[-16:] + [message]
            body = json.dumps({"model": self.model_used, "messages": messages, "stream": True,
                               "options": {"temperature": 0.4}}).encode("utf-8")
            url = (CONFIG.get("ollama_url") or "http://127.0.0.1:11434").rstrip("/") + "/api/chat"
            request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
            started = time.time()
            first_ms = None
            pieces = []
            try:
                with urllib.request.urlopen(request, timeout=ANSWER_TIMEOUT_S) as response:
                    for raw in response:
                        line = raw.strip()
                        if not line:
                            continue
                        try:
                            ev = json.loads(line)
                        except ValueError:
                            continue
                        if ev.get("error"):
                            raise RuntimeError(str(ev["error"])[:300])
                        piece = (ev.get("message") or {}).get("content", "")
                        if piece:
                            if first_ms is None:
                                first_ms = int((time.time() - started) * 1000)
                            pieces.append(piece)
                            on_delta(clean_for_speech(piece))
                        if ev.get("done"):
                            break
            except urllib.error.HTTPError as exc:
                raise RuntimeError(f"Ollama said {exc.code}: is the model '{self.model_used}' pulled?") from exc
            except urllib.error.URLError as exc:
                raise RuntimeError(f"Ollama isn't running at {url}") from exc
            answer = clean_for_speech("".join(pieces)).strip()
            self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": answer}]
            self.turns += 1
            self.last_used = time.time()
            return answer, int((time.time() - started) * 1000), first_ms


USING_OLLAMA = CONFIG.get("brain", "claude") == "ollama"
SESSION = OllamaSession() if USING_OLLAMA else ClaudeSession()

WEB_PROMPT = (
    "You answer questions for a voice assistant using live web results. Search the web, then answer in 1 to 3 short "
    "spoken sentences: plain text, no markdown, lists or URLs. Mention the source in a few words. If the results "
    "disagree or are unclear, say so briefly."
)


def web_search(query):
    """Live web answer: a separate one-off Claude Code run with only the web tools. Returns (answer, ms)."""
    if USING_OLLAMA or not CLAUDE:
        raise RuntimeError("Web answers need the Claude brain on the PC")
    cmd = [CLAUDE, "-p", query, "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch",
           "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
           "--system-prompt", WEB_PROMPT]
    if CONFIG.get("model"):
        cmd += ["--model", CONFIG["model"]]
    started = time.time()
    os.makedirs(WORK_DIR, exist_ok=True)
    result = subprocess.run(cmd, cwd=WORK_DIR, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=WEB_TIMEOUT_S)
    answer = clean_for_speech(result.stdout or "").strip()
    if result.returncode != 0 or not answer:
        raise RuntimeError((result.stderr or "The web search failed").strip()[:200])
    return answer, int((time.time() - started) * 1000)


def compose(question, context, history, fresh_session):
    lines = []
    context = dict(context or {})
    if context.pop("test", None):
        # Settings > Test the AI: keep it out of the real conversation.
        return ("This is an automatic connection test from the app's settings, not a message from the user. "
                "Reply with exactly: Hello, I'm ready. Then ignore this exchange in later answers.")
    if "memory" not in context:                     # the iPhone sends its own memory; the PC copy is the backup
        memory = load_memory()
        if memory:
            context["memory"] = " | ".join(memory)
    if context:
        parts = [f"{k}: {v}" for k, v in context.items() if v]
        if parts:
            lines.append("Context: " + "; ".join(parts))
    if fresh_session and history:
        # The phone's recent conversation, so a refreshed session can still follow up.
        lines.append("Earlier today:")
        for turn in history[-6:]:
            who = "User" if turn.get("fromUser") else "You"
            lines.append(f"{who}: {str(turn.get('text', ''))[:300]}")
    lines.append(question)
    return "\n".join(lines)

# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "DeskBridge/2"
    protocol_version = "HTTP/1.0"      # streamed replies end when the connection closes

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return self.headers.get("X-Desk-Code", "") == CONFIG["pairing_code"]

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(min(length, MAX_REQUEST_BYTES)) or b"{}")

    def do_GET(self):
        route = self.path.split("?")[0]
        if route == "/memory":
            if not self._authorized():
                return self._send(401, {"error": "Wrong pairing code"})
            return self._send(200, {"facts": load_memory()})
        if route != "/health":
            return self._send(404, {"error": "not found"})
        self._send(200, {
            "ok": True, "version": VERSION, "name": CONFIG["name"], "brain": "Ollama" if USING_OLLAMA else "Claude Code",
            "model": SESSION.model_used, "effort": CONFIG.get("effort") or "default",
            "paired": self._authorized(), "claudeFound": bool(CLAUDE),
            "warm": SESSION.is_warm(), "web": not USING_OLLAMA and bool(CLAUDE),
            "lastMs": STATS["last_ms"], "firstMs": STATS["first_ms"],
            "memories": len(load_memory()),
        })

    def do_POST(self):
        route = self.path.split("?")[0]
        if route not in ("/ask", "/reset", "/memory", "/web"):
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            return self._send(401, {"error": "Wrong pairing code"})
        if route == "/memory":
            try:
                req = self._read_json()
            except ValueError:
                return self._send(400, {"error": "Bad request"})
            with MEMORY_LOCK:
                items = load_memory()
                if req.get("clear") or req.get("replace") == []:
                    items = []
                elif req.get("remove"):
                    items = [x for x in items if x != req["remove"]]
                elif isinstance(req.get("replace"), list):
                    items = [str(x).strip() for x in req["replace"] if str(x).strip()]     # backup from the iPhone
                elif req.get("add"):
                    items = [str(req["add"]).strip()] + items
                save_memory(items)
            return self._send(200, {"facts": items})
        if route == "/reset":
            threading.Thread(target=SESSION.reset, daemon=True).start()
            return self._send(200, {"ok": True})
        if route == "/web":
            try:
                req = self._read_json()
            except ValueError:
                return self._send(400, {"error": "Bad request"})
            query = str(req.get("query", "")).strip()[:300]
            if not query:
                return self._send(400, {"error": "Empty query"})
            stamp = time.strftime("%H:%M:%S")
            print(f"[{stamp}] WEB: {query[:120]}")
            try:
                answer, ms = web_search(query)
            except subprocess.TimeoutExpired:
                return self._send(504, {"error": "The web search took too long"})
            except Exception as exc:
                print(f"[{stamp}]   web error: {exc}")
                return self._send(502, {"error": str(exc)})
            print(f"[{stamp}]   WEB ({ms} ms): {answer[:120]}")
            return self._send(200, {"answer": answer, "ms": ms})
        try:
            req = self._read_json()
        except ValueError:
            return self._send(400, {"error": "Bad request"})
        question = str(req.get("question", "")).strip()[:1000]
        if not question:
            return self._send(400, {"error": "Empty question"})
        if not CLAUDE and not USING_OLLAMA:
            return self._send(502, {"error": "The 'claude' command was not found on this PC"})
        image = None
        if isinstance(req.get("image"), str) and req["image"]:
            image = {"data": req["image"], "type": str(req.get("imageType") or "image/jpeg")}
        context = req.get("context") if isinstance(req.get("context"), dict) else {}
        history = req.get("history") if isinstance(req.get("history"), list) else []
        stream = bool(req.get("stream"))
        text = compose(question, context, history, fresh_session=SESSION._needs_restart())
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] Q: {question[:120]}{'  (with a photo)' if image else ''}")

        if stream:
            # Newline-delimited JSON: {"delta": "..."} pieces, then {"done": true, ...} or {"error": "..."}
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()

            def emit(obj):
                try:
                    self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
                    self.wfile.flush()
                except OSError:
                    pass
            try:
                answer, ms, first = SESSION.ask(text, lambda piece: emit({"delta": piece}), image=image)
            except Exception as exc:
                print(f"[{stamp}]   error: {exc}")
                return emit({"error": str(exc)})
            apply_memory_actions(answer)
            emit({"done": True, "answer": answer, "ms": ms, "firstMs": first, "model": SESSION.model_used})
        else:
            try:
                answer, ms, first = SESSION.ask(text, lambda piece: None, image=image)
            except TimeoutError as exc:
                return self._send(504, {"error": str(exc)})
            except Exception as exc:
                print(f"[{stamp}]   error: {exc}")
                return self._send(502, {"error": str(exc)})
            apply_memory_actions(answer)
            self._send(200, {"answer": answer, "ms": ms, "firstMs": first, "model": SESSION.model_used})
        STATS.update(last_ms=ms, first_ms=first, answered=STATS["answered"] + 1)
        print(f"[{stamp}]   A ({first} ms first / {ms} ms total): {answer[:120]}")

# ---------------------------------------------------------------- Bonjour + start-up

def advertise():
    dns_sd = shutil.which("dns-sd")
    if not dns_sd:
        print("Bonjour 'dns-sd' not found: enter this PC's address in the app manually.")
        return None
    return subprocess.Popen([dns_sd, "-R", CONFIG["name"], SERVICE_TYPE, "local", str(PORT), "v=2"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def local_ips():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.168.0.1", 9))      # no packets sent; picks the Wi-Fi interface
        ip = s.getsockname()[0]
        s.close()
        return [ip]
    except OSError:
        return []


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    bonjour = advertise()
    if CLAUDE:
        threading.Thread(target=SESSION.reset, daemon=True).start()   # warm up now, not on the first question
    print("=" * 62)
    print(" Desk Bridge is running")
    print(f"  Name:          {CONFIG['name']}")
    print(f"  Address:       {', '.join(f'{ip}:{PORT}' for ip in local_ips()) or 'unknown'}")
    print(f"  Pairing code:  {CONFIG['pairing_code']}   (enter in the app: Settings > AI & Network)")
    if USING_OLLAMA:
        print(f"  Brain:         Ollama, model {SESSION.model_used} at {CONFIG.get('ollama_url')}  (web answers off)")
    else:
        print(f"  Brain:         Claude Code, model {CONFIG.get('model') or 'default'}, effort {CONFIG.get('effort') or 'default'}"
              + ("" if CLAUDE else "   !! 'claude' command not found"))
    print("  Stop with Ctrl+C. If Windows asks, allow Python on PRIVATE networks.")
    print("=" * 62)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        SESSION.stop()
        if bonjour:
            bonjour.terminate()
        print("Desk Bridge stopped.")


if __name__ == "__main__":
    sys.exit(main())
