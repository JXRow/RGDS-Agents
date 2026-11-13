#!/usr/bin/env python3
"""rgds-aid: chat sidecar. Game <-> localhost TCP (NDJSON) <-> OpenAI-compatible SSE.

Python stdlib only. Config: $RGDS_AI_CONFIG, else the first of
  /userdata/rgds-ai/config.json
  /root/.config/rgds-ai/config.json

  {"provider":"minimax","api_key":"...","base_url":"https://api.minimax.cn/v1",
   "model":"MiniMax-M3","system":"...","max_tokens":300,"history_turns":6}

The API key is read from that file and sent only as an Authorization header.
It is never written to the log or to a protocol message.

Game -> aid:  {"op":"chat","id":"r1","text":"..."}  {"op":"cancel","id":"r1"}
              {"op":"reset"}  {"op":"status"}
aid -> game:  {"ev":"start","id"} {"ev":"delta","id","text"} {"ev":"done","id"}
              {"ev":"error","id","kind","msg","retryable"}
              kind: no_key|offline|timeout|auth|rate_limit|server|interrupted|cancelled|helper
"""
import json, os, socket, ssl, sys, threading, urllib.error, urllib.parse, urllib.request

CONNECT_TIMEOUT = 6.0
IDLE_TIMEOUT = 20.0
LISTEN = ("127.0.0.1", int(os.environ.get("RGDS_AI_PORT", "7788")))

MINIMAX_BASE = "https://api.minimax.cn/v1"
MINIMAX_MODEL = "MiniMax-M3"


def resolve_cfg_path():
    env = os.environ.get("RGDS_AI_CONFIG")
    if env:
        return env
    for path in ("/userdata/rgds-ai/config.json", "/root/.config/rgds-ai/config.json"):
        if os.path.isfile(path):
            return path
    return "/userdata/rgds-ai/config.json"


CFG_PATH = resolve_cfg_path()


def load_cfg():
    with open(CFG_PATH) as f:
        c = json.load(f)
    if not isinstance(c, dict):
        raise ValueError("config")
    c.setdefault("system",
                 "You are a friendly companion inside a handheld game. "
                 "Answer in the player's language, in plain text without markdown. "
                 "Match the length they ask for: a short question gets a few sentences, "
                 "and a request for a story or a long explanation can run to several paragraphs.")
    c.setdefault("max_tokens", 800)
    c.setdefault("history_turns", 6)
    if c.get("provider") == "minimax":
        c.setdefault("base_url", MINIMAX_BASE)
        c.setdefault("model", MINIMAX_MODEL)
    if os.environ.get("RGDS_AI_KEY"):
        c["api_key"] = os.environ["RGDS_AI_KEY"]
    return c


def redact(cfg, text):
    text = str(text or "")
    key = ""
    if isinstance(cfg, dict):
        key = cfg.get("api_key") or ""
    if key and key in text:
        text = text.replace(key, "[redacted]")
    if len(text) > 180:
        text = text[:180]
    return text


def tls_ctx():
    ca = os.environ.get("RGDS_AI_CA") or next(
        (p for p in ("/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem",
                     os.path.join(os.path.dirname(CFG_PATH), "cacert.pem")) if os.path.exists(p)),
        None)
    return ssl.create_default_context(cafile=ca)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # A redirect must not carry the Authorization header anywhere else.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def net_up(host, port, timeout=2.0):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


class ThinkStrip:
    """Drop a <think>...</think> block if a model puts one in content."""

    OPEN, CLOSE = "<think>", "</think>"

    def __init__(self):
        self.buf = ""
        self.skipping = False

    def feed(self, text):
        self.buf += text or ""
        out = []
        while self.buf:
            if self.skipping:
                end = self.buf.find(self.CLOSE)
                if end < 0:
                    if len(self.buf) > len(self.CLOSE):
                        self.buf = self.buf[-(len(self.CLOSE) - 1):]
                    return "".join(out)
                self.buf = self.buf[end + len(self.CLOSE):]
                self.skipping = False
                continue
            start = self.buf.find(self.OPEN)
            if start < 0:
                hold = 0
                for n in range(1, len(self.OPEN)):
                    if self.OPEN.startswith(self.buf[-n:]):
                        hold = n
                emit = self.buf[:-hold] if hold else self.buf
                self.buf = self.buf[-hold:] if hold else ""
                out.append(emit)
                return "".join(out)
            out.append(self.buf[:start])
            self.buf = self.buf[start + len(self.OPEN):]
            self.skipping = True
        return "".join(out)

    def finish(self):
        if self.skipping:
            self.buf = ""
            return ""
        text, self.buf = self.buf, ""
        return text


def delta_text(delta):
    if not isinstance(delta, dict):
        return ""
    content = delta.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
        return "".join(parts)
    return ""


class Conn:
    def __init__(self, sock):
        self.sock, self.lock = sock, threading.Lock()
        self.history = []
        self.cancel = {}

    def send(self, **ev):
        with self.lock:
            try:
                self.sock.sendall((json.dumps(ev, ensure_ascii=False) + "\n").encode())
            except OSError:
                pass

    def chat(self, rid, text):
        cfg = None
        try:
            cfg = load_cfg()
        except Exception:
            return self.send(ev="error", id=rid, kind="no_key", msg="config unreadable", retryable=False)
        if not cfg.get("api_key") or not cfg.get("base_url") or not cfg.get("model"):
            return self.send(ev="error", id=rid, kind="no_key", msg="no api_key", retryable=False)
        try:
            parsed = urllib.parse.urlparse(cfg["base_url"])
        except Exception:
            return self.send(ev="error", id=rid, kind="offline", msg="bad base_url", retryable=False)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        if not parsed.hostname or not net_up(parsed.hostname, port):
            return self.send(ev="error", id=rid, kind="offline",
                             msg="cannot reach host", retryable=True)
        turns = int(cfg.get("history_turns") or 0)
        msgs = ([{"role": "system", "content": cfg["system"]}] + self.history[-2 * turns:]
                + [{"role": "user", "content": text}])
        body = {
            "model": cfg["model"],
            "messages": msgs,
            "stream": True,
            "max_completion_tokens": int(cfg["max_tokens"]),
        }
        thinking = cfg.get("thinking")
        if thinking is None and cfg.get("model") == MINIMAX_MODEL:
            thinking = "disabled"
        if thinking in ("disabled", "adaptive"):
            body["thinking"] = {"type": thinking}
        raw = json.dumps(body).encode()
        req = urllib.request.Request(
            cfg["base_url"].rstrip("/") + "/chat/completions",
            data=raw,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + cfg["api_key"],
                "Accept": "text/event-stream",
            })
        self.send(ev="start", id=rid)
        out, stop = [], self.cancel.setdefault(rid, threading.Event())
        strip = ThinkStrip()

        def emit(piece):
            piece = strip.feed(piece)
            if piece:
                out.append(piece)
                self.send(ev="delta", id=rid, text=piece)

        try:
            ctx = tls_ctx() if parsed.scheme == "https" else None
            handlers = [NoRedirect]
            if ctx is not None:
                handlers.append(urllib.request.HTTPSHandler(context=ctx))
            resp = urllib.request.build_opener(*handlers).open(req, timeout=CONNECT_TIMEOUT)
            try:
                resp.fp.raw._sock.settimeout(IDLE_TIMEOUT)
            except Exception:
                pass
            for line in resp:
                if stop.is_set():
                    resp.close()
                    return self.send(ev="error", id=rid, kind="cancelled", msg="", retryable=True)
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if not data or data == b"[DONE]":
                    if data == b"[DONE]":
                        break
                    continue
                try:
                    event = json.loads(data)
                except ValueError:
                    continue
                base = event.get("base_resp") or {}
                code = base.get("status_code")
                if code:
                    kind = "auth" if code in (1004, 2049) else "server"
                    return self.send(ev="error", id=rid, kind=kind,
                                     msg=redact(cfg, base.get("status_msg") or ("status " + str(code))),
                                     partial="".join(out), retryable=kind == "server")
                err = event.get("error")
                if isinstance(err, dict):
                    return self.send(ev="error", id=rid, kind="server",
                                     msg=redact(cfg, err.get("message") or "error"),
                                     partial="".join(out), retryable=True)
                for choice in event.get("choices") or []:
                    emit(delta_text(choice.get("delta") or {}))
        except urllib.error.HTTPError as e:
            kind = {401: "auth", 403: "auth", 429: "rate_limit"}.get(e.code, "server")
            return self.send(ev="error", id=rid, kind=kind, msg="HTTP %s" % e.code,
                             partial="".join(out), retryable=kind in ("rate_limit", "server"))
        except (socket.timeout, TimeoutError):
            return self.send(ev="error", id=rid, kind="interrupted" if out else "timeout",
                             msg="timeout", partial="".join(out), retryable=True)
        except (urllib.error.URLError, OSError, ssl.SSLError) as e:
            return self.send(ev="error", id=rid, kind="interrupted" if out else "offline",
                             msg=redact(cfg, e), partial="".join(out), retryable=True)
        finally:
            self.cancel.pop(rid, None)
        tail = strip.finish()
        if tail:
            out.append(tail)
            self.send(ev="delta", id=rid, text=tail)
        reply = "".join(out).strip()
        self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": reply}]
        self.history = self.history[-2 * int(cfg["history_turns"]):]
        self.send(ev="done", id=rid)

    def serve(self):
        f = self.sock.makefile("rb")
        for line in f:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op = msg.get("op")
            if op == "chat" and isinstance(msg.get("text"), str):
                threading.Thread(target=self.chat, args=(msg.get("id", "r"), msg["text"]),
                                 daemon=True).start()
            elif op == "cancel" and msg.get("id") in self.cancel:
                self.cancel[msg["id"]].set()
            elif op == "reset":
                self.history.clear()
                self.send(ev="status", reset=True)
            elif op == "status":
                try:
                    cfg = load_cfg()
                    parsed = urllib.parse.urlparse(cfg.get("base_url") or "")
                    up = bool(parsed.hostname) and net_up(
                        parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80))
                    self.send(ev="status", net="ok" if up else "offline",
                              model=cfg.get("model"), key=bool(cfg.get("api_key")))
                except Exception:
                    self.send(ev="status", net="unknown", key=False, msg="config unreadable")


def main():
    # The game thread that spawns us blocks most signals. Undo that so quit can SIGTERM.
    try:
        import signal
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    except Exception:
        pass
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(2)
    print("rgds-aid listening on %s:%d" % LISTEN, file=sys.stderr, flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=Conn(conn).serve, daemon=True).start()


if __name__ == "__main__":
    main()
