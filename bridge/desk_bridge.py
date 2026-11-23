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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
SERVICE_TYPE = "_deskbridge._tcp"
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "bridge_config.local.json")       # git-ignored: holds the pairing code
WORK_DIR = os.path.join(tempfile.gettempdir(), "desk-bridge-empty")   # Claude runs here: no project files
VERSION = 2
MAX_TURNS = 40                 # refresh the session after this many questions
IDLE_RESET_S = 30 * 60         # ...or after 30 minutes without questions
ANSWER_TIMEOUT_S = 60

SYSTEM_PROMPT = (
    "You are Desk Companion, a friendly voice assistant on the user's home desk display. "
    "Your reply is spoken aloud by a text-to-speech voice, so answer in 1 to 3 short, natural sentences. "
    "Plain text only: no markdown, lists, headings, emoji, URLs or code. "
    "Each user message may start with a Context line (date, time, weather); use it only when it helps. "
    "Timers, alarms, reminders, lists, calendar and weather are handled by the phone itself; "
    "if asked to do one of those, tell the user they can simply say it, for example 'set a 10 minute timer'. "
    "If you are not sure, say so briefly."
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
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    return cfg

CONFIG = load_config()
CLAUDE = shutil.which("claude")
STATS = {"last_ms": None, "first_ms": None, "answered": 0}


def clean_for_speech(text):
    text = re.sub(r"[*_#`>]+", "", text)
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

    def ask(self, text, on_delta):
        """Sends one question; calls on_delta(text_piece) while streaming. Returns (answer, ms, first_ms)."""
        with self.lock:
            for attempt in range(2):
                if self._needs_restart() or attempt == 1:
                    self.start()
                started = time.time()
                first_ms = None
                pieces = []
                try:
                    self.proc.stdin.write(json.dumps({"type": "user",
                                                      "message": {"role": "user", "content": text}}) + "\n")
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


SESSION = ClaudeSession()


def compose(question, context, history, fresh_session):
    lines = []
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
        return json.loads(self.rfile.read(min(length, 64_000)) or b"{}")

    def do_GET(self):
        if self.path.split("?")[0] != "/health":
            return self._send(404, {"error": "not found"})
        self._send(200, {
            "ok": True, "version": VERSION, "name": CONFIG["name"], "brain": "Claude Code",
            "model": SESSION.model_used, "effort": CONFIG.get("effort") or "default",
            "paired": self._authorized(), "claudeFound": bool(CLAUDE),
            "warm": SESSION.proc is not None and SESSION.proc.poll() is None,
            "lastMs": STATS["last_ms"], "firstMs": STATS["first_ms"],
        })

    def do_POST(self):
        route = self.path.split("?")[0]
        if route not in ("/ask", "/reset"):
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            return self._send(401, {"error": "Wrong pairing code"})
        if route == "/reset":
            threading.Thread(target=SESSION.reset, daemon=True).start()
            return self._send(200, {"ok": True})
        try:
            req = self._read_json()
        except ValueError:
            return self._send(400, {"error": "Bad request"})
        question = str(req.get("question", "")).strip()[:1000]
        if not question:
            return self._send(400, {"error": "Empty question"})
        if not CLAUDE:
            return self._send(502, {"error": "The 'claude' command was not found on this PC"})
        context = req.get("context") if isinstance(req.get("context"), dict) else {}
        history = req.get("history") if isinstance(req.get("history"), list) else []
        stream = bool(req.get("stream"))
        text = compose(question, context, history, fresh_session=SESSION._needs_restart())
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] Q: {question[:120]}")

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
                answer, ms, first = SESSION.ask(text, lambda piece: emit({"delta": piece}))
            except Exception as exc:
                print(f"[{stamp}]   error: {exc}")
                return emit({"error": str(exc)})
            emit({"done": True, "answer": answer, "ms": ms, "firstMs": first, "model": SESSION.model_used})
        else:
            try:
                answer, ms, first = SESSION.ask(text, lambda piece: None)
            except TimeoutError as exc:
                return self._send(504, {"error": str(exc)})
            except Exception as exc:
                print(f"[{stamp}]   error: {exc}")
                return self._send(502, {"error": str(exc)})
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
