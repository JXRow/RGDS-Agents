#!/usr/bin/env python3
"""rgds-micd: RG DS 麦克风采集守护进程（rgds-lua-demo-v2 的启动脚本随游戏启停）。

经 ALSA dsnoop 读机身麦克风（RK817 "Main Mic"，只在左声道），dsnoop 可多进程共享，
所以别的进程（如离线语音识别）照样能自己再开一个 dsnoop 读者。读到的音频分两路发出：

1. 波形帧 → UDP 127.0.0.1:47820（游戏用 LuaSocket 非阻塞读，见 micwave.lua）
   每 20 ms 一个数据报，小端：
     头 18 字节  '<4sIIBBHH'  magic b"RGM1", seq u32, t_ms u32, state u8, nbins u8,
                              rms u16, peak u16（样本单位 0..32767，已去直流）
     state 0 (live):  后跟 nbins 对 (min i16, max i16)，每对覆盖 20 ms / nbins
     state 1 (starting) / 2 (error) / 3 (stopped):  nbins = 0，后跟 ASCII 原因
     非 live 状态每 0.5 s 发一次心跳。
2. PCM → Unix 流套接字 /tmp/rgds-micd.sock：每个连上的客户端收到裸 S16LE 16 kHz 单声道
   （左声道，未去直流，无文件头），从连接时刻开始。例：
     socat -u UNIX-CONNECT:/tmp/rgds-micd.sock - | <stt> --raw-s16le-16k
   客户端落后超过 MAX_PENDING_S 秒会被断开（日志里有记录），重连即可。

采集失败（设备忙、arecord 退出、超过 1 s 没数据）时按 1→10 s 退避重启，期间发 state 2。
--watch-pid 指定的进程（启动脚本）消失时自行退出，保证不残留占着麦克风。
"""

import argparse
import ctypes
import errno
import os
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time
import warnings

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    import audioop  # Python 3.11 仍自带；C 实现的 tomono/minmax/rms，比纯 Python 循环省一个数量级

DEFAULT_DEVICE = "plug:'dsnoop:CARD=rockchiprk817co,DEV=0,RATE=44100,FORMAT=S32_LE'"
RATE = 16000
CHUNK_FRAMES = 320                       # 20 ms @ 16 kHz
CHUNK_BYTES = CHUNK_FRAMES * 2 * 2       # S16 立体声
MAGIC = b"RGM1"
HEADER = struct.Struct("<4sIIBBHH")
LIVE, STARTING, ERROR, STOPPED = 0, 1, 2, 3
HEARTBEAT_S = 0.5
STALL_S = 1.0
MAX_PENDING_S = 2.0
PIDFILE = "/tmp/rgds-micd.pid"


def log(msg):
    sys.stderr.write(time.strftime("%H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


def die_with_parent():
    # arecord 在 daemon 被 SIGKILL 时也跟着退出（PR_SET_PDEATHSIG = 1）
    try:
        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)
    except Exception:
        pass


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_previous_instance():
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return
    if pid == os.getpid() or not pid_alive(pid):
        return
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            if b"rgds-micd" not in f.read():
                return
    except OSError:
        return
    log("stopping previous instance pid %d" % pid)
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 3
    while pid_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if pid_alive(pid):
        os.kill(pid, signal.SIGKILL)


class PcmServer:
    def __init__(self, path, sel):
        self.path = path
        self.sel = sel
        self.clients = {}
        self.max_pending = int(MAX_PENDING_S * RATE * 2)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        os.chmod(path, 0o666)
        self.sock.listen(8)
        self.sock.setblocking(False)
        sel.register(self.sock, selectors.EVENT_READ, self.accept)

    def accept(self):
        try:
            conn, _ = self.sock.accept()
        except BlockingIOError:
            return
        conn.setblocking(False)
        self.clients[conn] = bytearray()
        self.sel.register(conn, selectors.EVENT_READ, lambda c=conn: self.on_readable(c))
        log("pcm client connected (%d total)" % len(self.clients))

    def on_readable(self, conn):
        try:
            data = conn.recv(4096)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.drop(conn, "disconnected")

    def drop(self, conn, why):
        if conn not in self.clients:
            return
        del self.clients[conn]
        self.sel.unregister(conn)
        conn.close()
        log("pcm client %s (%d left)" % (why, len(self.clients)))

    def send(self, pcm):
        for conn, pending in list(self.clients.items()):
            pending += pcm
            try:
                sent = conn.send(pending)
                del pending[:sent]
            except BlockingIOError:
                pass
            except OSError as e:
                self.drop(conn, "send failed: %s" % e.strerror)
                continue
            if len(pending) > self.max_pending:
                self.drop(conn, "too slow, dropped")

    def close(self):
        for conn in list(self.clients):
            self.drop(conn, "closed")
        self.sel.unregister(self.sock)
        self.sock.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


class Capture:
    def __init__(self, device, sel, on_chunk):
        self.device = device
        self.sel = sel
        self.on_chunk = on_chunk
        self.proc = None
        self.buf = bytearray()
        self.last_err = ""
        self.last_data = 0.0
        self.overruns = 0

    def start(self):
        cmd = ["arecord", "-q", "-D", self.device, "-f", "S16_LE", "-c", "2", "-r", str(RATE),
               "-t", "raw", "--period-size=%d" % CHUNK_FRAMES, "--buffer-size=4096"]
        try:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, preexec_fn=die_with_parent)
        except OSError as e:
            self.proc = None
            self.last_err = "arecord: %s" % e.strerror
            return False
        os.set_blocking(self.proc.stdout.fileno(), False)
        os.set_blocking(self.proc.stderr.fileno(), False)
        self.sel.register(self.proc.stdout, selectors.EVENT_READ, self.on_stdout)
        self.sel.register(self.proc.stderr, selectors.EVENT_READ, self.on_stderr)
        self.buf.clear()
        self.last_err = ""
        self.last_data = time.monotonic()
        return True

    def running(self):
        return self.proc is not None

    def on_stdout(self):
        try:
            data = os.read(self.proc.stdout.fileno(), 16384)
        except BlockingIOError:
            return
        if not data:
            self.stop()
            return
        self.last_data = time.monotonic()
        self.buf += data
        while len(self.buf) >= CHUNK_BYTES:
            chunk = bytes(self.buf[:CHUNK_BYTES])
            del self.buf[:CHUNK_BYTES]
            self.on_chunk(chunk)

    def on_stderr(self):
        try:
            data = os.read(self.proc.stderr.fileno(), 4096)
        except BlockingIOError:
            return
        if not data:
            self.sel.unregister(self.proc.stderr)
            return
        for line in data.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("overrun"):
                self.overruns += 1
                if self.overruns <= 5 or self.overruns % 100 == 0:
                    log("arecord: %s (#%d)" % (line, self.overruns))
            else:
                self.last_err = line.replace("arecord: ", "")[:120]
                log("arecord: " + line)

    def stalled(self):
        return self.proc is not None and time.monotonic() - self.last_data > STALL_S

    def stop(self):
        if self.proc is None:
            return None
        proc, self.proc = self.proc, None
        for f in (proc.stdout, proc.stderr):
            try:
                self.sel.unregister(f)
            except (KeyError, ValueError):
                pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        try:
            tail = proc.stderr.read() or b""
            for line in tail.decode("utf-8", "replace").splitlines():
                if line.strip() and not line.startswith("overrun"):
                    self.last_err = line.strip().replace("arecord: ", "")[:120]
        except (OSError, ValueError):
            pass
        proc.stdout.close()
        proc.stderr.close()
        return proc.returncode


class Daemon:
    def __init__(self, args):
        self.args = args
        self.sel = selectors.DefaultSelector()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setblocking(False)
        self.dest = ("127.0.0.1", args.wave_port)
        self.nbins = args.bins
        self.bin_bytes = CHUNK_FRAMES // self.nbins * 2
        self.seq = 0
        self.dc = 0.0
        self.chunks = 0
        self.pcm = PcmServer(args.pcm_sock, self.sel) if args.pcm_sock else None
        self.cap = Capture(args.device, self.sel, self.on_chunk)
        self.stopping = False
        self.status = (STARTING, "starting")
        self.next_heartbeat = 0.0
        self.retry_at = 0.0
        self.backoff = 1.0
        self.live_since = None

    def send_wave(self, payload):
        try:
            self.udp.sendto(payload, self.dest)
        except OSError:
            pass  # 游戏没在监听或缓冲满：丢掉即可，波形帧不需要可靠送达
        self.seq = (self.seq + 1) & 0xFFFFFFFF

    def send_status(self, state, text):
        t_ms = int(time.monotonic() * 1000) & 0xFFFFFFFF
        self.send_wave(HEADER.pack(MAGIC, self.seq, t_ms, state, 0, 0, 0) + text.encode()[:200])

    def on_chunk(self, chunk):
        mono = audioop.tomono(chunk, 2, 1, 0)
        if self.pcm and self.pcm.clients:
            self.pcm.send(mono)
        avg = audioop.avg(mono, 2)
        self.dc += (avg - self.dc) * 0.05
        dc = int(self.dc)
        rms = audioop.rms(mono, 2)
        rms_ac = int(max(0, rms * rms - avg * avg) ** 0.5)
        pairs = []
        peak = 0
        step = self.bin_bytes
        for i in range(0, len(mono), step):
            lo, hi = audioop.minmax(mono[i:i + step], 2)
            lo, hi = max(-32768, lo - dc), min(32767, hi - dc)
            pairs += (lo, hi)
            peak = max(peak, -lo, hi)
        t_ms = int(time.monotonic() * 1000) & 0xFFFFFFFF
        payload = HEADER.pack(MAGIC, self.seq, t_ms, LIVE, len(pairs) // 2, min(rms_ac, 65535), min(peak, 65535))
        self.send_wave(payload + struct.pack("<%dh" % len(pairs), *pairs))
        self.chunks += 1
        if self.live_since is None:
            self.live_since = time.monotonic()
            self.backoff = 1.0
            self.status = (LIVE, "")
            log("capture live: %s" % self.args.device)

    def capture_failed(self, why):
        rc = self.cap.stop()
        reason = self.cap.last_err or why
        if rc not in (None, 0):
            reason = "%s (rc %d)" % (reason, rc)
        self.status = (ERROR, reason)
        self.live_since = None
        self.retry_at = time.monotonic() + self.backoff
        log("capture failed: %s; retry in %.0fs" % (reason, self.backoff))
        self.backoff = min(self.backoff * 2, 10.0)

    def tick(self, now):
        if not self.cap.running() and now >= self.retry_at:
            if self.status[0] != ERROR:
                self.status = (STARTING, "starting")
            if not self.cap.start():
                self.capture_failed("arecord failed to start")
        elif self.cap.running() and self.cap.stalled():
            self.capture_failed("no audio for %.0fs" % STALL_S)
        if self.status[0] != LIVE and now >= self.next_heartbeat:
            self.send_status(*self.status)
            self.next_heartbeat = now + HEARTBEAT_S

    def run(self):
        last_watch = 0.0
        last_stats = time.monotonic()
        while not self.stopping:
            for key, _ in self.sel.select(timeout=0.1):
                key.data()
            now = time.monotonic()
            if self.cap.running() and self.cap.proc.poll() is not None and not self.cap.buf:
                self.capture_failed("arecord exited")
            self.tick(now)
            if self.args.watch_pid and now - last_watch > 1.0:
                last_watch = now
                if not pid_alive(self.args.watch_pid):
                    log("watched pid %d is gone, exiting" % self.args.watch_pid)
                    break
            if now - last_stats > 60:
                last_stats = now
                log("stats: %d chunks, %d overruns, %d pcm clients"
                    % (self.chunks, self.cap.overruns, len(self.pcm.clients) if self.pcm else 0))
        self.shutdown()

    def shutdown(self):
        self.cap.stop()
        self.send_status(STOPPED, "daemon stopped")
        if self.pcm:
            self.pcm.close()
        self.udp.close()
        log("stopped after %d chunks" % self.chunks)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--device", default=os.environ.get("RGDS_MICD_DEVICE", DEFAULT_DEVICE))
    p.add_argument("--wave-port", type=int, default=47820)
    p.add_argument("--bins", type=int, default=10, help="min/max pairs per 20 ms frame (divides 320)")
    p.add_argument("--pcm-sock", default="/tmp/rgds-micd.sock", help="'' disables the PCM socket")
    p.add_argument("--watch-pid", type=int, default=0, help="exit when this pid disappears")
    args = p.parse_args()
    if args.bins <= 0 or CHUNK_FRAMES % args.bins:
        p.error("--bins must divide %d" % CHUNK_FRAMES)

    stop_previous_instance()
    with open(PIDFILE, "w") as f:
        f.write("%d\n" % os.getpid())

    try:
        daemon = Daemon(args)
    except OSError as e:
        log("init failed: %s" % e)
        return 1

    def on_signal(signum, _frame):
        daemon.stopping = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    log("rgds-micd pid %d: wave udp %s:%d, pcm %s, %d bins/20ms"
        % (os.getpid(), daemon.dest[0], daemon.dest[1], args.pcm_sock or "off", args.bins))
    try:
        daemon.run()
    finally:
        try:
            with open(PIDFILE) as f:
                if f.read().strip() == str(os.getpid()):
                    os.unlink(PIDFILE)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
