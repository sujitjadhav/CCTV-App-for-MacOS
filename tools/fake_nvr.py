#!/usr/bin/env python3
"""Fake XMEye/Sofia NVR (DVRIP over TCP) for testing the app without real hardware.

Supports: login (sofia hash), KeepAlive, SystemInfo, OPTimeQuery, OPFileQuery (64 per page),
OPPlayBack Claim/DownloadStart/DownloadStop (streams an XMEye-framed .h264 file) and
AlarmSet followed by periodic VideoMotion alarms (msg 1504).

    python3 -I tools/fake_nvr.py --port 34568 --password secret
    python3 -I tools/fake_nvr.py --make-file out.h264 [--codec h265]   # just write a sample file

The sample recording is generated once with ffmpeg (test pattern + 440 Hz tone as G.711A)
and cached next to --cache. Times are NVR local time (India) and carry no time zone.
"""
import argparse
import hashlib
import json
import os
import random
import socket
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

IST = timezone(timedelta(hours=5, minutes=30))
FMT = "%Y-%m-%d %H:%M:%S"
FPS = 25
GOP = 50
SECONDS = 30
WIDTH, HEIGHT = 640, 360


def log(*a):
    print("[fake_nvr]", *a, flush=True)


def sofia_hash(password):
    d = hashlib.md5(password.encode()).digest()
    chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    return "".join(chars[(d[2 * i] + d[2 * i + 1]) % 62] for i in range(8))


# ---------- sample recording ----------

def split_nals(data):
    """Returns NAL unit payloads (without start codes) of an Annex B stream."""
    out, i, n, starts = [], 0, len(data), []
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        starts.append(j + 3)
        i = j + 3
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else n
        nal = data[s:e]
        while nal.endswith(b"\x00") and k + 1 < len(starts):
            nal = nal[:-1]
        out.append(nal)
    return out


def access_units(data, hevc):
    """Groups NALs into frames using the AUD NALs that ffmpeg inserted; AUDs are dropped."""
    frames, cur = [], []
    for nal in split_nals(data):
        t = (nal[0] >> 1) & 0x3F if hevc else nal[0] & 0x1F
        if t == (35 if hevc else 9):
            if cur:
                frames.append(cur)
            cur = []
            continue
        cur.append(nal)
    if cur:
        frames.append(cur)
    result = []
    for nals in frames:
        types = [((x[0] >> 1) & 0x3F) if hevc else (x[0] & 0x1F) for x in nals]
        key = any(16 <= t <= 21 for t in types) if hevc else 5 in types
        result.append((key, b"".join(b"\x00\x00\x00\x01" + x for x in nals)))
    return result


def make_sources(cache_dir, codec):
    os.makedirs(cache_dir, exist_ok=True)
    vpath = os.path.join(cache_dir, f"sample_{codec}.es")
    apath = os.path.join(cache_dir, "sample.alaw")
    if not os.path.exists(vpath):
        enc = (["-c:v", "libx265", "-x265-params", f"bframes=0:keyint={GOP}:min-keyint={GOP}:repeat-headers=1:log-level=error",
                "-bsf:v", "hevc_metadata=aud=insert", "-f", "hevc"] if codec == "h265" else
               ["-c:v", "libx264", "-bf", "0", "-g", str(GOP), "-keyint_min", str(GOP), "-profile:v", "main",
                "-bsf:v", "h264_metadata=aud=insert", "-f", "h264"])
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                        f"testsrc2=size={WIDTH}x{HEIGHT}:rate={FPS}", "-t", str(SECONDS),
                        "-pix_fmt", "yuv420p"] + enc + [vpath], check=True)
    if not os.path.exists(apath):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=8000",
                        "-t", str(SECONDS), "-ac", "1", "-ar", "8000", "-f", "alaw", apath], check=True)
    with open(vpath, "rb") as f:
        frames = access_units(f.read(), codec == "h265")
    with open(apath, "rb") as f:
        audio = f.read()
    return frames, audio


def pack_time(dt):
    return (dt.second | dt.minute << 6 | dt.hour << 12 | dt.day << 17 | dt.month << 22 | (dt.year - 2000) << 26)


def xmeye_file(frames, audio, begin, codec="h264"):
    """Wraps frames in XMEye private headers; one 40 ms G.711A block after each video frame."""
    media = 3 if codec == "h265" else 2
    out = bytearray()
    for i, (key, payload) in enumerate(frames):
        if key:
            t = begin + timedelta(seconds=i // FPS)
            out += b"\x00\x00\x01\xFC" + struct.pack("<BBBBII", media, FPS, WIDTH // 8, HEIGHT // 8, pack_time(t), len(payload))
        else:
            out += b"\x00\x00\x01\xFD" + struct.pack("<I", len(payload))
        out += payload
        block = audio[i * 320:(i + 1) * 320]
        if len(block) == 320:
            out += b"\x00\x00\x01\xFA" + struct.pack("<BBH", 0x0E, 0x02, 320) + block
    return bytes(out)


# ---------- server ----------

class Recordings:
    def __init__(self, frames, audio, day):
        self.frames, self.audio = frames, audio
        self.size = len(xmeye_file(frames, audio, day))
        self.files = {}  # channel -> list of dicts
        for ch in range(4):
            items, t = [], day
            while t.date() == day.date():
                e = t + timedelta(minutes=10) - timedelta(seconds=1)
                name = f"/idea0/{t:%Y-%m-%d}/{ch + 1:03d}/{t:%H.%M.%S}-{e:%H.%M.%S}[R][@{random.randint(0x1000, 0xffff):x}][0].h264"
                items.append({"BeginTime": t.strftime(FMT), "EndTime": e.strftime(FMT), "DiskNo": 0, "SerialNo": 0,
                              "FileLength": "0x%08X" % ((self.size + 1023) // 1024), "FileName": name})
                t += timedelta(minutes=10)
            self.files[ch] = items
        self.by_name = {f["FileName"]: f for items in self.files.values() for f in items}

    def query(self, ch, begin, end):
        return [f for f in self.files.get(ch, []) if f["BeginTime"] >= begin and f["BeginTime"] <= end][:64]

    def content(self, name):
        f = self.by_name[name]
        return xmeye_file(self.frames, self.audio, datetime.strptime(f["BeginTime"], FMT))


class Conn(threading.Thread):
    def __init__(self, sock, addr, args, rec):
        super().__init__(daemon=True)
        self.s, self.addr, self.args, self.rec = sock, addr, args, rec
        self.session = 0
        self.lock = threading.Lock()
        self.alive = True
        self.seq = 0

    def recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return bytes(buf)

    def send_packet(self, msg, payload):
        hdr = struct.pack("<BB2xII2xHI", 0xFF, 0, self.session, self.seq, msg, len(payload))
        with self.lock:
            self.s.sendall(hdr + payload)
            self.seq += 1

    def reply(self, msg, obj):
        self.send_packet(msg, json.dumps(obj).encode() + b"\x0a\x00")

    def sid(self):
        return "0x%08X" % self.session

    def run(self):
        log("connection from", self.addr)
        try:
            while True:
                h = self.recv_exact(20)
                head, ver, session, seq, msg, length = struct.unpack("<BB2xII2xHI", h)
                if head != 0xFF:
                    log("bad header"); return
                body = self.recv_exact(length) if length else b""
                try:
                    req = json.loads(body.rstrip(b"\x00").rstrip(b"\x0a").decode() or "{}")
                except ValueError:
                    log("bad json"); return
                if msg != 1000 and (self.session == 0 or session != self.session):
                    self.reply(msg + 1, {"Ret": 105, "SessionID": self.sid()}); continue
                self.handle(msg, req)
        except socket.timeout:
            log("session timed out (no keep-alive)")
        except (ConnectionError, OSError):
            pass
        finally:
            self.alive = False
            self.s.close()
            log("connection closed", self.addr)

    def handle(self, msg, req):
        name = req.get("Name", "")
        if msg == 1000:
            if req.get("UserName") != self.args.user:
                self.reply(1001, {"Ret": 113, "SessionID": "0x00000000"}); return
            if req.get("PassWord") != sofia_hash(self.args.password):
                log("login: wrong password")
                self.reply(1001, {"Ret": 203, "SessionID": "0x00000000"}); return
            self.session = random.randint(1, 0x7FFFFFFF)
            self.s.settimeout(3 * self.args.alive)  # like a real NVR: drop sessions without keep-alive
            log("login ok")
            self.reply(1001, {"AliveInterval": self.args.alive, "ChannelNum": 4, "DeviceType ": "NVR",
                              "ExtraChannel": 0, "Ret": 100, "SessionID": self.sid()})
        elif msg == 1006:
            log("keepalive")
            self.reply(1007, {"Name": "KeepAlive", "Ret": 100, "SessionID": self.sid()})
        elif msg in (1020, 1042) and name == "SystemInfo":
            self.reply(msg + 1, {"Name": "SystemInfo", "Ret": 100, "SessionID": self.sid(), "SystemInfo": {
                "HardWare": "FAKE-NVR", "SoftWareVersion": "V4.03.R11.fake", "VideoInChannel": 4,
                "SerialNo": "fake0000000000"}})
        elif msg == 1452:
            now = datetime.now(IST).strftime(FMT)
            self.reply(1453, {"Name": "OPTimeQuery", "OPTimeQuery": now, "Ret": 100, "SessionID": self.sid()})
        elif msg == 1440:
            q = req.get("OPFileQuery", {})
            items = self.rec.query(int(q.get("Channel", 0)), q.get("BeginTime", ""), q.get("EndTime", ""))
            log(f"file query ch{q.get('Channel')} {q.get('BeginTime')} -> {len(items)}")
            if items:
                self.reply(1441, {"Name": "OPFileQuery", "OPFileQuery": items, "Ret": 100, "SessionID": self.sid()})
            else:
                self.reply(1441, {"Name": "OPFileQuery", "Ret": 119, "SessionID": self.sid()})
        elif msg == 1424:
            p = req.get("OPPlayBack", {})
            ok = p.get("Parameter", {}).get("FileName") in self.rec.by_name
            self.reply(1425, {"Name": "OPPlayBack", "Ret": 100 if ok else 119, "SessionID": self.sid()})
        elif msg == 1420:
            p = req.get("OPPlayBack", {})
            action, fname = p.get("Action"), p.get("Parameter", {}).get("FileName")
            if action == "DownloadStart":
                if fname not in self.rec.by_name:
                    self.reply(1421, {"Name": "OPPlayBack", "Ret": 119, "SessionID": self.sid()}); return
                self.reply(1421, {"Name": "OPPlayBack", "Ret": 100, "SessionID": self.sid()})
                self.stop_download = threading.Event()
                threading.Thread(target=self.stream_file, args=(fname, self.stop_download), daemon=True).start()
            else:
                log("playback", action)
                if action == "DownloadStop" and getattr(self, "stop_download", None):
                    self.stop_download.set()
                self.reply(1421, {"Name": "OPPlayBack", "Ret": 100, "SessionID": self.sid()})
        elif msg == 1500:
            self.reply(1501, {"Name": "", "Ret": 100, "SessionID": self.sid()})
            threading.Thread(target=self.push_alarms, daemon=True).start()
        else:
            log("unsupported msg", msg, name)
            self.reply(msg + 1, {"Name": name, "Ret": 103, "SessionID": self.sid()})

    def stream_file(self, fname, stop):
        data = self.rec.content(fname)
        log(f"download {fname} ({len(data)} bytes)")
        try:
            for i in range(0, len(data), 32768):
                if stop.is_set():
                    log("download stopped early"); return
                self.send_packet(1426, data[i:i + 32768])
                if self.args.chunk_delay:
                    time.sleep(self.args.chunk_delay)
            self.send_packet(1426, b"")
        except OSError:
            pass

    def push_alarms(self):
        n = 0
        while self.alive:
            time.sleep(self.args.alarm_interval)
            if not self.alive:
                break
            info = {"Channel": n % 4, "Event": "VideoMotion", "StartTime": datetime.now(IST).strftime(FMT),
                    "Status": "Start" if n % 2 == 0 else "Stop"}
            try:
                self.send_packet(1504, json.dumps({"AlarmInfo": info, "Name": "AlarmInfo",
                                                   "SessionID": self.sid()}).encode() + b"\x0a\x00")
            except OSError:
                break
            n += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=34568)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="")
    ap.add_argument("--alive", type=int, default=2, help="AliveInterval sent at login (s)")
    ap.add_argument("--alarm-interval", type=float, default=1.0)
    ap.add_argument("--chunk-delay", type=float, default=0.005, help="pause between 32 KB download chunks (s)")
    ap.add_argument("--day", default=None, help="recording day YYYY-MM-DD (default: today in India)")
    ap.add_argument("--cache", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "fake_nvr_cache"))
    ap.add_argument("--make-file", metavar="PATH", help="write one XMEye-framed sample file and exit")
    ap.add_argument("--codec", choices=["h264", "h265"], default="h264")
    ap.add_argument("--begin", default=None, help="begin time for --make-file (YYYY-MM-DD HH:MM:SS)")
    args = ap.parse_args()

    day = datetime.strptime(args.day, "%Y-%m-%d") if args.day else datetime.now(IST).replace(tzinfo=None)
    day = day.replace(hour=0, minute=0, second=0, microsecond=0)
    if args.make_file:
        frames, audio = make_sources(args.cache, args.codec)
        begin = datetime.strptime(args.begin, FMT) if args.begin else day + timedelta(hours=10)
        with open(args.make_file, "wb") as f:
            f.write(xmeye_file(frames, audio, begin, args.codec))
        log("wrote", args.make_file)
        return
    frames, audio = make_sources(args.cache, "h264")
    rec = Recordings(frames, audio, day)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(8)
    log(f"listening on 127.0.0.1:{args.port}, {len(rec.files[0])} files per channel on {day:%Y-%m-%d}, file {rec.size} bytes")
    try:
        while True:
            s, a = srv.accept()
            Conn(s, a, args, rec).start()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
