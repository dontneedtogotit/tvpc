"""Camera network discovery.

Discovers IP security cameras on the local network(s) using several methods:

* parallel TCP port sweep on the well-known camera ports (RTSP 554, HTTP 80,
  ISAPI 8080, MJPEG 8000)
* raw RTSP DESCRIBE (no ffmpeg required) to confirm a port-554 service is
  actually a camera and to identify its vendor
* HTTP probe of vendor-specific endpoints (Hikvision ISAPI, Dahua CGI,
  Reolink, MJPEG streams, ONVIF device service)
* ONVIF WS-Discovery multicast (UDP/3702) + ONVIF GetDeviceInformation +
  GetProfiles for the discovered XAddrs — gives the real stream URL plus
  manufacturer / model / firmware
* ARP table read from /proc/net/arp to seed candidates without sweeping
* mDNS query for _rtsp._tcp / _onvif._tcp / _http._tcp

The output is a list of `DiscoveredCamera` records. Each result is
de-duplicated by (host, url) so a camera found by RTSP *and* ONVIF does
not show up twice.
"""
from __future__ import annotations

import concurrent.futures
import dataclasses
import http.client
import ipaddress
import re
import socket
import struct
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Iterable, List, Optional, Set, Tuple


# ---------------------------------------------------------------------------
# Common network ports probed during the sweep.
# ---------------------------------------------------------------------------
# RTSP:  554 standard, 8554/10554 common alt, 6554 Tuya, 10554 some OEMs
RTSP_PORTS = (554, 8554, 10554, 6554)
HTTP_PORTS = (80, 8080, 8000, 443, 5000, 8899)
TUYA_PORTS = (6668,)
DVR_PORTS = (8000, 37777, 34567, 9000, 8001)



# ---------------------------------------------------------------------------
# RTSP path probes (used as DESCRIBE URLs after the port check confirms a
# service is listening).  Order matters: the first one that responds is the
# one reported.
# ---------------------------------------------------------------------------
RTSP_PATHS: List[str] = [
    "/Streaming/Channels/101",   # Hikvision main
    "/Streaming/Channels/1",     # Hikvision alt
    "/Streaming/Channels/102",   # Hikvision sub
    "/cam/realmonitor",          # Dahua
    "/onvif/Streaming/Channels/101",
    "/onvif/Streaming/Channels/1",
    "/live/main",                # generic / Reolink
    "/live/sub",
    "/live/0/main",              # Reolink
    "/h264Preview_01_main",      # Axis-like
    "/11",                       # Reolink alt / HiSilicon clone
    "/0",                        # HiSilicon / TC98
    "/1",                        # TC98 alt
    "/ch0_0.h264",               # HiSilicon 3516
    "/stream_0",                 # Tuya (port 6554)
    "/cam1/mpeg4",               # Tuya / generic Chinese
    "/stream1",                  # generic
    "/stream2",
    "/av0_0",                    # some Chinese cams
    "/video",                    # MJPEG-over-RTSP
    "/live1.264",                # HiSilicon unknown
    "/",                         # root (Tuya root URL)
]


# HTTP probe paths. Each tuple is (path, method, what-it-means-if-200).
HTTP_PROBES: List[Tuple[str, str, str]] = [
    # Hikvision
    ("/ISAPI/Streaming/channels", "GET", "hikvision"),
    ("/ISAPI/System/deviceInfo", "GET", "hikvision"),
    ("/cgi-bin/magicBox.cgi?action=getProductClass", "GET", "hikvision"),
    # Dahua
    ("/cgi-bin/devInfo.cgi?action=get", "GET", "dahua"),
    ("/cgi-bin/menu.cgi?action=getProductModel", "GET", "dahua"),
    # Reolink
    ("/api.cgi?cmd=GetDevInfo&token=", "GET", "reolink"),
    # ONVIF device service
    ("/onvif/device_service", "POST", "onvif"),
    # Axis MJPEG
    ("/axis-cgi/mjpg/video.cgi", "GET", "axis-mjpeg"),
    # Generic MJPEG
    ("/mjpg/video.mjpg", "GET", "generic-mjpeg"),
    ("/video.mjpg", "GET", "generic-mjpeg"),
    # HiSilicon / Chinese OEM (ORION rebadges use these)
    ("/videostream.cgi", "GET", "hisilicon"),
    ("/tmpfs/auto.jpg", "GET", "hisilicon"),
    ("/cgi-bin/net_jpeg.cgi?ch=1", "GET", "hisilicon"),
    ("/img/snapshot.cgi?size=2", "GET", "hisilicon"),
    ("/snapshot.cgi", "GET", "hisilicon"),
    # Tuya / Grid Connect — many Tuya cams expose a tiny web UI on :80
    # that contains the device UUID and "tuya" or "smart life" branding
    ("/", "GET", "http-root"),
]


# mDNS service types to query.
MDNS_SERVICE_TYPES = ("_rtsp._tcp.local", "_onvif._tcp.local", "_http._tcp.local")

# Cache of working RTSP paths keyed by (host_lower, port, vendor_lower).
# Persists for the lifetime of the process; speeds up rescans.
_RTSP_PATH_CACHE: dict[tuple[str, int, str], str] = {}


# ---------------------------------------------------------------------------
# Vendor-specific RTSP path hints
# ---------------------------------------------------------------------------
# Maps vendor patterns to preferred RTSP paths. Used to speed up discovery
# by trying the most likely paths first for a given vendor.
VENDOR_RTSP_PATH_HINTS: dict[str, List[str]] = {
    "hikvision": [
        "/Streaming/Channels/101",
        "/Streaming/Channels/1",
        "/Streaming/Channels/102",
    ],
    "dahua": [
        "/cam/realmonitor",
        "/live/main",
        "/live/sub",
    ],
    "reolink": [
        "/live/main",
        "/live/sub",
        "/live/0/main",
        "/11",
    ],
    "axis": [
        "/axis-cgi/mjpg/video.cgi",
        "/h264Preview_01_main",
        "/mpeg4/1/media.amp",
    ],
    "hisilicon": [
        "/11",
        "/0",
        "/1",
        "/ch0_0.h264",
        "/stream_0",
        "/cam1/mpeg4",
    ],
    "tuya": [
        "/stream_0",
        "/cam1/mpeg4",
        "/stream1",
        "/",
    ],
    "onvif": [
        "/onvif/Streaming/Channels/101",
        "/onvif/Streaming/Channels/1",
        "/live/main",
    ],
}


def _hint_paths_for_vendor(vendor: str) -> List[str]:
    """Return preferred RTSP paths for a vendor, or the default list."""
    key = vendor.lower()
    for k, v in VENDOR_RTSP_PATH_HINTS.items():
        if k in key:
            return v
    return RTSP_PATHS


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class DiscoveredCamera:
    host: str
    url: str
    method: str = "rtsp"            # "rtsp", "http", "onvif", "mdns", "arp", "cloud", "dvr"
    vendor: str = ""
    model: str = ""
    firmware: str = ""
    note: str = ""
    port: int = 0
    channel: int = 0                # 1-indexed channel number on DVR/NVR (0 = standalone camera)
    total_channels: int = 0         # Total channels detected on the DVR/NVR
    is_dvr: bool = False            # True if stream belongs to a DVR/NVR channel
    dvr_type: str = ""              # DVR classification / vendor name
    mac: str = ""

    def key(self) -> Tuple[str, str]:
        return (self.host, self.url)

    def display(self) -> str:
        bits: List[str] = []
        bits.append(f"[{self.method.upper():<5}]")
        bits.append(self.host)
        if self.port:
            bits.append(f":{self.port}")
        ident_parts = [x for x in (self.vendor, self.model) if x]
        if self.is_dvr and self.channel:
            ch_str = f"Camera {self.channel}" + (f"/{self.total_channels}" if self.total_channels else "")
            ident_parts.append(f"[{ch_str}]")
        if ident_parts:
            bits.append(f"  ({' '.join(ident_parts)})")
        if self.mac:
            bits.append(f"  [{self.mac}]")
        if self.url:
            bits.append(f"  →  {self.url}")
        else:
            bits.append("  (no URL — see note)")
        return "".join(bits)


# ---------------------------------------------------------------------------
# Subnet enumeration
# ---------------------------------------------------------------------------
def all_local_subnets(prefix_len: int = 24) -> List[ipaddress.IPv4Network]:
    """Return one IPv4Network per non-loopback, up interface.

    A typical home box has one interface (192.168.1.42/24 → 192.168.1.0/24)
    but laptops dock + undock, and routers sometimes run multiple subnets on
    one box. We try every active interface so the user does not have to pick.
    """
    nets: List[ipaddress.IPv4Network] = []
    try:
        out = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show", "up"],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        )
    except Exception:  # noqa: BLE001
        # Fall back to the default-route method.
        base = local_subnet_base()
        if base:
            nets.append(ipaddress.IPv4Network(f"{base}.0/{prefix_len}", strict=False))
        return nets

    for line in out.splitlines():
        m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", line)
        if not m:
            continue
        ip = m.group(1)
        plen = int(m.group(2))
        if ip.startswith("127."):
            continue
        # Skip point-to-point /32s without a /24 context.
        if plen == 32:
            # Re-derive a /24 from the host address.
            base = ".".join(ip.split(".")[:3])
            nets.append(ipaddress.IPv4Network(f"{base}.0/24", strict=False))
        else:
            nets.append(ipaddress.IPv4Network(f"{ip}/{plen}", strict=False))
    # De-dup
    seen: Set[ipaddress.IPv4Network] = set()
    out: List[ipaddress.IPv4Network] = []
    for n in nets:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def local_subnet_base() -> Optional[str]:
    """Return the /24 base for the default route's interface, e.g. '192.168.1'."""
    try:
        out = subprocess.check_output(
            ["ip", "-4", "route", "get", "1.1.1.1"],
            stderr=subprocess.DEVNULL, text=True, timeout=2,
        )
    except Exception:  # noqa: BLE001
        return None
    m = re.search(r"src\s+(\d+\.\d+\.\d+)\.\d+", out)
    if not m:
        return None
    return ".".join(m.group(1).split(".")[:3])


def hosts_in(net: ipaddress.IPv4Network) -> Iterable[str]:
    for ip in net.hosts():
        yield ip.exploded


def parse_cidr_or_subnet(text: str) -> Optional[ipaddress.IPv4Network]:
    """Accept a CIDR (10.0.0.0/16) or a base (192.168.1) and normalize."""
    text = text.strip()
    if not text:
        return None
    try:
        if "/" in text:
            return ipaddress.IPv4Network(text, strict=False)
        # Bare base — assume /24.
        if re.fullmatch(r"\d+\.\d+\.\d+", text):
            return ipaddress.IPv4Network(f"{text}.0/24", strict=False)
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", text):
            return ipaddress.IPv4Network(f"{text}/32", strict=False)
    except (ValueError, TypeError):
        return None
    return None


# ---------------------------------------------------------------------------
# Low-level probes
# ---------------------------------------------------------------------------
def tcp_open(host: str, port: int, timeout: float = 0.6) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def parallel_tcp_open(hosts: Iterable[str], port: int, *,
                      timeout: float = 0.6, workers: int = 32) -> List[str]:
    """Open a TCP port against many hosts in parallel. Returns the live ones.

    32 concurrent workers is the sweet spot: faster than serial, well below
    the per-process FD limit on common Linux defaults.
    """
    host_list = list(hosts)
    if not host_list:
        return []
    open_hosts: List[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(tcp_open, h, port, timeout): h for h in host_list}
        for fut in concurrent.futures.as_completed(futs):
            if fut.result():
                open_hosts.append(futs[fut])
    return open_hosts


def quick_probe_host(host: str, ports: Tuple[int, ...] = (554, 80, 8080, 8000),
                     timeout: float = 0.4) -> Set[int]:
    """Quickly check which ports are open on a host in parallel.

    Returns the set of open ports. Useful for fast pre-filtering before
    deeper probes.
    """
    open_ports: Set[int] = set()
    port_list = list(ports)
    if not port_list:
        return open_ports
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(len(port_list), 16)) as ex:
        futs = {ex.submit(tcp_open, host, p, timeout): p for p in port_list}
        for fut in concurrent.futures.as_completed(futs):
            if fut.result():
                open_ports.add(futs[fut])
    return open_ports


# ---------------------------------------------------------------------------
# Raw RTSP DESCRIBE — no ffmpeg required.
# ---------------------------------------------------------------------------
_RTSP_TIMEOUT = 2.5


def rtsp_describe(host: str, port: int, path: str,
                  user: str = "", password: str = "",
                  timeout: float = _RTSP_TIMEOUT) -> Optional[dict]:
    """Send an RTSP DESCRIBE and parse the response.

    Returns a dict with `server`, `content_type`, `www_authenticate`, and the
    raw `body` (truncated) — or None if the server did not respond like an
    RTSP endpoint. The Caller decides what to do with it.
    """
    auth = ""
    if user:
        import base64
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        auth = f"Authorization: Basic {token}\r\n"

    req = (
        f"DESCRIBE rtsp://{host}:{port}{path} RTSP/1.0\r\n"
        f"CSeq: 1\r\n"
        f"User-Agent: tvpc-cameras-gui/1.0\r\n"
        f"Accept: application/sdp\r\n"
        f"{auth}"
        f"\r\n"
    )
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.sendall(req.encode())
            buf = b""
            s.settimeout(timeout)
            while b"\r\n\r\n" not in buf and len(buf) < 8192:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if not buf.startswith(b"RTSP/"):
                return None
            head, _, body = buf.partition(b"\r\n\r\n")
            headers: dict = {}
            for line in head.split(b"\r\n")[1:]:
                if b":" in line:
                    k, v = line.split(b":", 1)
                    headers[k.strip().lower().decode("ascii", "replace")] = v.strip().decode("ascii", "replace")
            return {
                "server": headers.get("server", ""),
                "content_type": headers.get("content-type", ""),
                "www_authenticate": headers.get("www-authenticate", ""),
                "status": head.split(b"\r\n", 1)[0].decode("ascii", "replace"),
                "body": body[:4096].decode("utf-8", "replace"),
                "path": path,
                "port": port,
            }
    except (OSError, socket.timeout):
        return None


# ---------------------------------------------------------------------------
# MAC OUI Vendor Table (Top IP Camera Manufacturers & Chipsets)
# ---------------------------------------------------------------------------
MAC_OUI_VENDORS: dict[str, str] = {
    # Tuya / Smart Life / OEM WiFi chips (Shenzhen Bilian, Espressif, etc.)
    "98:03:cf": "Tuya / Orion",
    "10:5a:f7": "Tuya / Orion",
    "d4:a6:51": "Tuya / Orion",
    "70:89:76": "Tuya / Orion",
    "18:69:d8": "Tuya / Smart Life",
    "68:57:2c": "Tuya / Smart Life",
    "20:f4:1b": "Tuya / Smart Life",
    "40:22:d8": "Tuya / Smart Life",
    "84:f3:eb": "Tuya / Smart Life",
    "00:0c:43": "Ralink / Tuya OEM",
    # TP-Link / Tapo
    "50:d4:f7": "TP-Link Tapo",
    "b0:a7:b9": "TP-Link Tapo",
    "30:de:4b": "TP-Link Tapo",
    "54:af:97": "TP-Link Tapo",
    "ec:21:e5": "TP-Link Tapo",
    "60:32:b1": "TP-Link Tapo",
    "9c:53:22": "TP-Link Tapo",
    "cc:32:e5": "TP-Link Tapo",
    # Reolink
    "ec:71:db": "Reolink",
    "48:e7:da": "Reolink",
    "bc:32:53": "Reolink",
    "1c:3b:f3": "Reolink",
    # Hikvision & Annke / Ezviz
    "bc:ba:e1": "Hikvision",
    "c8:02:8f": "Hikvision",
    "44:19:b6": "Hikvision",
    "10:12:fb": "Hikvision",
    "00:40:48": "Hikvision",
    "54:c4:15": "Hikvision",
    "a4:14:37": "Hikvision / Ezviz",
    "e0:50:8b": "Hikvision / Ezviz",
    # Dahua & Amcrest / Imou
    "3c:ef:8c": "Dahua",
    "4c:11:bf": "Dahua",
    "90:02:a9": "Dahua",
    "a0:bd:cd": "Dahua",
    "bc:54:51": "Amcrest",
    # Axis Communications
    "00:40:8c": "Axis Communications",
    "ac:cc:8e": "Axis Communications",
    "b8:a4:4f": "Axis Communications",
    # Foscam (Shenzhen Foscam)
    "00:62:6e": "Foscam",
    "e4:3e:d7": "Foscam",
    "c4:d6:55": "Foscam",
    # Wyze
    "2c:aa:8e": "Wyze",
    "7c:78:b2": "Wyze",
    "a4:da:22": "Wyze",
    # Eufy (Anker)
    "8c:85:80": "Eufy",
    "ac:12:03": "Eufy",
    # Ubiquiti / UniFi Protect
    "74:83:c2": "Ubiquiti UniFi",
    "b4:fb:e4": "Ubiquiti UniFi",
    "fc:ec:da": "Ubiquiti UniFi",
    "24:5a:4c": "Ubiquiti UniFi",
    # Hanwha / Samsung Techwin
    "00:09:18": "Hanwha Techwin",
    "00:16:6c": "Samsung / Hanwha",
    # Vivotek
    "00:02:d1": "Vivotek",
}


def identify_vendor_from_mac(mac: str) -> str:
    """Identify camera vendor from its MAC address (OUI prefix)."""
    if not mac:
        return ""
    clean = mac.lower().replace("-", ":").strip()
    prefix = ":".join(clean.split(":")[:3])
    return MAC_OUI_VENDORS.get(prefix, "")


_VENDOR_RE = [
    # Specific OEMs that identify themselves in the Server header or SDP body.
    (re.compile(r"\bOrion\b", re.I), "Orion"),
    (re.compile(r"Grid[-\s]?Connect", re.I), "Grid Connect (Orion / Tuya)"),
    (re.compile(r"\bTuya\b", re.I), "Tuya"),
    (re.compile(r"\bConvision\b", re.I), "Convision"),
    # TP-Link must come before Tapo (Tapo also matches TP-LINK) and
    # before ONVIF/HiSilicon fallbacks.
    (re.compile(r"\bTapo\b", re.I), "TP-Link Tapo"),
    (re.compile(r"\bTP-LINK\b", re.I), "TP-Link"),
    (re.compile(r"\bHikvision\b", re.I), "Hikvision"),
    (re.compile(r"\bEzviz\b", re.I), "Ezviz (Hikvision)"),
    (re.compile(r"\bAnnke\b", re.I), "Annke"),
    (re.compile(r"\bDahua\b", re.I), "Dahua"),
    (re.compile(r"\bImou\b", re.I), "Imou (Dahua)"),
    (re.compile(r"\bAmcrest\b", re.I), "Amcrest"),
    (re.compile(r"\bLorex\b", re.I), "Lorex"),
    (re.compile(r"\bReolink\b", re.I), "Reolink"),
    (re.compile(r"\bUniview\b|\bUNV\b", re.I), "Uniview"),
    (re.compile(r"\bAxis\b", re.I), "Axis"),
    (re.compile(r"\bBosch\b", re.I), "Bosch"),
    (re.compile(r"\bVivotek\b", re.I), "Vivotek"),
    (re.compile(r"\bFoscam\b", re.I), "Foscam"),
    (re.compile(r"\bWyze\b", re.I), "Wyze"),
    (re.compile(r"\bEufy\b", re.I), "Eufy"),
    (re.compile(r"\bUbiquiti\b|\bUniFi\b", re.I), "Ubiquiti UniFi"),
    (re.compile(r"\bWansview\b", re.I), "Wansview"),
    (re.compile(r"\bHiSilicon\b", re.I), "HiSilicon (generic)"),
    (re.compile(r"\bONVIF\b", re.I), "ONVIF device"),
    (re.compile(r"NetSurveillance", re.I), "NetSurveillance (Chinese OEM)"),
    (re.compile(r"\bXiongmai\b|\bXM\b", re.I), "Xiongmai (XM)"),
    # SDP origin fields that reveal a more specific chipset.
    (re.compile(r"o=-.*Hanwha", re.I), "Hanwha"),
]


def identify_vendor_from_rtsp(info: dict) -> str:
    """Pick the most specific vendor name from an RTSP DESCRIBE response.

    Order matters: more specific patterns (Orion, Grid Connect, Tuya) are
    tried before generic ones (HiSilicon, ONVIF).
    """
    haystack = " ".join([info.get("server", ""), info.get("body", "")])
    for rx, name in _VENDOR_RE:
        if rx.search(haystack):
            return name
    return ""


def identify_vendor_from_http(body: str, headers: dict) -> str:
    haystack = " ".join([
        body,
        headers.get("server", ""),
        headers.get("x-powered-by", ""),
        # Grid Connect / Tuya web UIs put a brand string in the title tag.
        re.search(r"<title>([^<]+)</title>", body, re.I).group(1)
        if re.search(r"<title>([^<]+)</title>", body, re.I) else "",
    ])
    for rx, name in _VENDOR_RE:
        if rx.search(haystack):
            return name
    return ""


def rtsp_probe_paths(host: str, port: int = 554,
                     user: str = "", password: str = "",
                     paths: List[str] = None,
                     timeout: float = _RTSP_TIMEOUT,
                     workers: int = 8,
                     vendor_hint: str = "") -> Optional[DiscoveredCamera]:
    """Try each path in RTSP_PATHS in parallel until one returns a valid RTSP response.

    Paths are probed concurrently so a single unreachable host only blocks
    for `timeout` seconds (not `timeout * len(paths)`).

    If `vendor_hint` is provided, vendor-specific paths are tried first.
    Results are cached per (host, port, vendor) to speed up rescans.
    """
    import concurrent.futures
    cache_key = (host.lower(), port, vendor_hint.lower())
    cached = _RTSP_PATH_CACHE.get(cache_key)
    if cached:
        info = rtsp_describe(host, port, cached, user, password, timeout)
        if info is not None:
            vendor = identify_vendor_from_rtsp(info)
            return DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{port}{cached}",
                method="rtsp",
                vendor=vendor,
                note=f"Server: {info['server']}" if info.get("server") else "",
                port=port,
            )
    # Reorder paths: vendor-specific hints first, then defaults.
    hint_paths = _hint_paths_for_vendor(vendor_hint) if vendor_hint else []
    remaining = [p for p in (paths or RTSP_PATHS) if p not in hint_paths]
    ordered = hint_paths + remaining
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, len(ordered))) as ex:
        futs = {ex.submit(rtsp_describe, host, port, p, user, password, timeout): p
                for p in ordered}
        for fut in concurrent.futures.as_completed(futs):
            info = fut.result()
            if info is None:
                continue
            vendor = identify_vendor_from_rtsp(info)
            path = futs[fut]
            _RTSP_PATH_CACHE[cache_key] = path
            return DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{port}{path}",
                method="rtsp",
                vendor=vendor,
                note=f"Server: {info['server']}" if info.get("server") else "",
                port=port,
            )
    return None


# ---------------------------------------------------------------------------
# HTTP probe
# ---------------------------------------------------------------------------
def http_get(host: str, port: int, path: str, *,
             user: str = "", password: str = "",
             timeout: float = 3.0) -> Optional[Tuple[int, str, dict]]:
    """Tiny HTTP GET. Returns (status, body, headers) on success, else None."""
    if port == 443:
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
        except OSError:
            return None
    else:
        try:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
        except OSError:
            return None
    try:
        headers = {"User-Agent": "tvpc-cameras-gui/1.0",
                   "Accept": "*/*"}
        if user:
            import base64
            token = base64.b64encode(f"{user}:{password}".encode()).decode()
            headers["Authorization"] = f"Basic {token}"
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        body = resp.read(8192).decode("utf-8", "replace")
        out_headers = {k.lower(): v for k, v in resp.getheaders()}
        return resp.status, body, out_headers
    except (OSError, http.client.HTTPException):
        return None
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def http_probe(host: str, port: int = 80,
               user: str = "", password: str = "",
               timeout: float = 3.0) -> List[DiscoveredCamera]:
    """Run the HTTP_PROBES list against host:port and return any matches."""
    found: List[DiscoveredCamera] = []
    for path, _method, hint in HTTP_PROBES:
        res = http_get(host, port, path, user=user, password=password, timeout=timeout)
        if res is None:
            continue
        status, body, headers = res
        if status >= 400 and status != 401:  # 401 still proves the host is alive
            continue
        vendor = identify_vendor_from_http(body, headers)
        # The MJPEG path is itself a stream — add it as a stream URL.
        if "mjpeg" in hint or "video" in path and path.endswith(".mjpg"):
            url = f"http://{host}:{port}{path}"
        elif hint == "onvif":
            url = f"http://{host}:{port}{path}"
        elif hint == "hikvision" and "ISAPI" in path:
            url = f"http://{host}:{port}{path}"
        elif "cgi-bin" in path or "/api" in path:
            url = f"http://{host}:{port}{path}"
        else:
            # Generic 200 on / — still useful as a candidate but no stream URL.
            continue
        found.append(DiscoveredCamera(
            host=host,
            url=url,
            method="http",
            vendor=vendor or hint,
            note=f"HTTP {status} {hint}",
            port=port,
        ))
    return found


# ---------------------------------------------------------------------------
# ARP table
# ---------------------------------------------------------------------------
def arp_table() -> dict[str, str]:
    """Read /proc/net/arp and `ip neigh` to return a mapping of IP -> MAC address."""
    table: dict[str, str] = {}
    try:
        with open("/proc/net/arp", "r", encoding="ascii") as f:
            next(f)  # header
            for line in f:
                parts = line.split()
                if len(parts) < 6:
                    continue
                ip, _hw, flags, mac, _mask, _dev = parts[:6]
                if flags == "0x0" or mac == "00:00:00:00:00:00":
                    continue
                if ip.startswith("127."):
                    continue
                table[ip] = mac.lower()
    except OSError:
        pass

    try:
        import subprocess
        res = subprocess.run(
            ["ip", "-4", "neigh", "show"],
            capture_output=True, text=True, timeout=2
        )
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4 and "lladdr" in parts:
                ip = parts[0]
                if ip.startswith("127."):
                    continue
                idx = parts.index("lladdr")
                if idx + 1 < len(parts):
                    mac = parts[idx + 1].lower()
                    if mac != "00:00:00:00:00:00":
                        table[ip] = mac
    except Exception:
        pass

    return table


def arp_hosts() -> Set[str]:
    """Return IPs that have a resolved MAC."""
    return set(arp_table().keys())


def get_mac_for_host(host: str) -> str:
    """Return MAC address for a host from the ARP table."""
    return arp_table().get(host, "")


def arp_scan(nets: List[ipaddress.IPv4Network], timeout: int = 1) -> Set[str]:
    """Actively ping all hosts in the subnets to force ARP resolution.
    
    Uses standard `ping -b` or parallel `ping` as an unprivileged fallback,
    which will populate the ARP table so `arp_hosts()` can see them.
    """
    import subprocess
    import concurrent.futures
    
    alive: Set[str] = set()
    hosts_to_ping = []
    for net in nets:
        for host in hosts_in(net):
            hosts_to_ping.append(host)
            
    if not hosts_to_ping:
        return set()
        
    def ping_host(h: str) -> Optional[str]:
        try:
            res = subprocess.run(
                ["ping", "-c", "1", "-W", str(timeout), h],
                capture_output=True, timeout=timeout + 1
            )
            if res.returncode == 0:
                return h
        except Exception:
            pass
        return None

    # Limit workers to avoid too many processes
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
        for h in ex.map(ping_host, hosts_to_ping):
            if h:
                alive.add(h)
                
    # Now that we've pinged them, they will be in the ARP table.
    return alive


# ---------------------------------------------------------------------------
# ICMP ping (with TCP fallback for unprivileged environments)
# ---------------------------------------------------------------------------
def _icmp_ping(host: str, timeout: float = 0.5) -> bool:
    """Send one ICMP echo request. Requires root (CAP_NET_RAW).

    Returns True if a reply arrived within `timeout` seconds.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    except (PermissionError, OSError):
        return False
    try:
        sock.settimeout(timeout)
        # ICMP echo: type=8, code=0, checksum=0, id=0x1234, seq=1
        # The kernel fills in the checksum for SOCK_RAW ICMP, but on
        # some platforms we need to compute it ourselves.
        pkt = b"\x08\x00\x00\x00\x12\x34\x00\x01" + b"\x00" * 8
        # Simple checksum (RFC 1071).
        if len(pkt) % 2:
            pkt += b"\x00"
        words = struct.unpack("!%dH" % (len(pkt) // 2), pkt)
        s = sum(words)
        s = (s >> 16) + (s & 0xFFFF)
        s += s >> 16
        pkt = struct.pack("!BBHHH", 8, 0, (~s) & 0xFFFF, 0x1234, 1) + b"\x00" * 8
        sock.sendto(pkt, (host, 0))
        try:
            data, _ = sock.recvfrom(1024)
            return data and data[20] == 0  # type 0 = echo reply
        except socket.timeout:
            return False
    finally:
        sock.close()


def _tcp_ping(host: str, timeout: float = 0.5) -> bool:
    """Probe a host via TCP. Returns True if the host is reachable.

    * errno 0 (success)  — host is up and answered the SYN
    * errno ECONNREFUSED — host is up and replied with RST
    * anything else (timeout, ENETUNREACH, EHOSTUNREACH) — host is down
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        err = s.connect_ex((host, 80))
        s.close()
        # 0 = success, ECONNREFUSED (111) = RST, EHOSTUNREACH (113) = no route
        # but with a short timeout, EHOSTUNREACH may be reported by the
        # kernel as a synchronous ICMP error during connect_ex.
        return err in (0, 111)  # success or refused
    except OSError:
        return False


def alive_hosts(hosts: Iterable[str], timeout: int = 1) -> Set[str]:
    """Return the subset of `hosts` that respond to ICMP ping or TCP connect.

    Uses the system ping utility with -c 1 -W timeout for ICMP echo.
    Falls back to a TCP connect probe if ping fails (unprivileged environments).
    Safe to call from a worker thread.
    Handles subprocess exceptions (TimeoutExpired, CalledProcessError, OSError).
    """
    import subprocess
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def ping_host(host: str) -> bool:
        """Ping a single host and return True if it responds."""
        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', str(timeout), host],
                capture_output=True,
                text=True,
                timeout=timeout + 1
            )
            if result.returncode == 0:
                return True
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError):
            pass
        # Fallback: TCP connect to port 80 (many cameras respond here).
        return _tcp_ping(host, timeout=timeout * 0.8)

    host_list = list(hosts)
    if not host_list:
        return set()

    alive: Set[str] = set()
    max_workers = min(32, len(host_list))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_host = {executor.submit(ping_host, host): host for host in host_list}
        for future in as_completed(future_to_host):
            if future.result():
                alive.add(future_to_host[future])

    return alive


# ---------------------------------------------------------------------------
# mDNS query
# ---------------------------------------------------------------------------
def _mdns_query(service: str, timeout: float = 1.0) -> List[str]:
    """Send a single mDNS PTR query and return the answer names.

    No external dependencies. We craft a minimal DNS packet, send it to
    224.0.0.251:5353, and parse the response.
    """
    pkt = _build_dns_query(service)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        sock.settimeout(timeout)
        sock.sendto(pkt, ("224.0.0.251", 5353))
        names: List[str] = []
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                break
            for name in _parse_dns_ptr_answers(data):
                names.append(name)
        return names
    except OSError:
        return []
    finally:
        sock.close()


def _build_dns_query(name: str) -> bytes:
    """Build a minimal DNS query for a PTR record of `name`."""
    tid = b"\xaa\xbb"
    flags = b"\x01\x00"     # standard query, recursion desired
    qdcount = b"\x00\x01"
    ancount = b"\x00\x00"
    nscount = b"\x00\x00"
    arcount = b"\x00\x00"
    qname = b""
    for label in name.split("."):
        qname += bytes([len(label)]) + label.encode()
    qname += b"\x00"
    qtype = b"\x00\x0c"     # PTR
    qclass = b"\x00\x01"    # IN
    return tid + flags + qdcount + ancount + nscount + arcount + qname + qtype + qclass


def _parse_dns_name(data: bytes, offset: int) -> Tuple[str, int]:
    """Parse a (possibly compressed) DNS name starting at offset.

    Returns `(name, new_offset)`. The new offset is the position immediately
    after the first (uncompressed) name in `data`, even if the name itself
    dereferences one or more compression pointers.
    """
    labels: List[str] = []
    orig = offset
    seen_ptrs: Set[int] = set()
    while True:
        if offset >= len(data):
            return ".".join(labels), orig + 1
        ln = data[offset]
        if ln == 0:
            if not labels:
                return "", offset + 1
            return ".".join(labels), offset + 1
        if (ln & 0xC0) == 0xC0:
            if offset + 1 >= len(data):
                return ".".join(labels), orig + 2
            ptr = ((ln & 0x3F) << 8) | data[offset + 1]
            if ptr in seen_ptrs or ptr == orig:
                # Loop or back-reference: stop parsing.
                return ".".join(labels), offset + 2
            seen_ptrs.add(ptr)
            # Follow the pointer to extract any further labels. We
            # iterate manually rather than recursing so a long chain
            # of pointers (RFC 1035 forbids but real devices do) cannot
            # blow the stack.
            sub_labels: List[str] = []
            sub_offset = ptr
            while True:
                if sub_offset >= len(data):
                    break
                sln = data[sub_offset]
                if sln == 0:
                    break
                if (sln & 0xC0) == 0xC0:
                    if sub_offset + 1 >= len(data):
                        break
                    nptr = ((sln & 0x3F) << 8) | data[sub_offset + 1]
                    if nptr in seen_ptrs or nptr == orig:
                        break
                    seen_ptrs.add(nptr)
                    sub_offset = nptr
                    continue
                sub_offset += 1
                sub_labels.append(
                    data[sub_offset:sub_offset + sln].decode("utf-8", "replace")
                )
                sub_offset += sln
            if sub_labels:
                labels.append(".".join(sub_labels))
            return ".".join(labels), offset + 2
        offset += 1
        labels.append(data[offset:offset + ln].decode("utf-8", "replace"))
        offset += ln
    return ".".join(labels), offset


def _parse_dns_ptr_answers(data: bytes) -> List[str]:
    """Return PTR target names from a DNS response."""
    names: List[str] = []
    if len(data) < 12:
        return names
    qdcount = struct.unpack("!H", data[4:6])[0]
    ancount = struct.unpack("!H", data[6:8])[0]
    offset = 12
    # skip questions
    for _ in range(qdcount):
        _, offset = _parse_dns_name(data, offset)
        offset += 4  # qtype + qclass
    for _ in range(ancount):
        name, offset = _parse_dns_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlen]
        if rtype == 12:  # PTR
            target, _ = _parse_dns_name(rdata, 0)
            if target:
                names.append(target)
        offset += rdlen
    return names


def mdns_resolve_host(name: str) -> Optional[str]:
    try:
        import socket
        return socket.gethostbyname(name)
    except OSError:
        pass
    try:
        import socket
        res = socket.getaddrinfo(name, None, socket.AF_INET)
        if res:
            return res[0][4][0]
    except OSError:
        pass
    return None


def mdns_discover(timeout_per_service: float = 2.0, retries: int = 1) -> List[DiscoveredCamera]:
    """Send mDNS PTR queries with retries for better reliability.

    Some cameras are slow to respond to mDNS. We retry each service type
    and merge results. Resolves .local names to IPs.
    """
    found: List[DiscoveredCamera] = []
    seen_names: Set[str] = set()
    for svc in MDNS_SERVICE_TYPES:
        for attempt in range(retries + 1):
            for name in _mdns_query(svc, timeout=timeout_per_service):
                if name in seen_names:
                    continue
                seen_names.add(name)
                try:
                    short = name.split(".")[0]
                except IndexError:
                    short = name
                method = "mdns"
                if "rtsp" in name:
                    method = "rtsp"
                elif "onvif" in name:
                    method = "onvif"
                elif "http" in name:
                    method = "http"
                
                # Resolve host IP
                ip = mdns_resolve_host(name)
                
                found.append(DiscoveredCamera(
                    host=ip or "",  # resolved IP if possible
                    url=name,
                    method=method,
                    note=f"mDNS: {name}" + (f" (resolved to {ip})" if ip else ""),
                ))
    return found


# ---------------------------------------------------------------------------
# SSDP / UPnP Discovery
# ---------------------------------------------------------------------------
_SSDP_INFO_CACHE: dict[str, dict[str, str]] = {}


def get_ssdp_info(host: str) -> dict[str, str]:
    """Return cached SSDP/UPnP info for a host (manufacturer, model, friendlyName)."""
    return _SSDP_INFO_CACHE.get(host, {})


def _fetch_upnp_description(url: str, timeout: float = 1.5) -> dict[str, str]:
    """Fetch and parse UPnP device description XML from LOCATION header."""
    import urllib.request
    import xml.etree.ElementTree as ET

    info: dict[str, str] = {}
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "tvpc-cameras/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            root = ET.fromstring(data)
            for elem in root.iter():
                tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
                if tag in (
                    "friendlyName", "manufacturer", "modelDescription",
                    "modelName", "modelNumber", "modelURL", "serialNumber",
                    "presentationURL", "deviceType",
                ):
                    if elem.text and tag not in info:
                        info[tag] = elem.text.strip()
    except Exception:
        pass
    return info


def ssdp_discover(timeout: float = 2.0) -> List[DiscoveredCamera]:
    """Discover IP cameras via SSDP / UPnP multicast (239.255.255.250:1900)."""
    from urllib.parse import urlparse

    msg = (
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        "ST: ssdp:all\r\n"
        "\r\n"
    ).encode("ascii")

    try:
        out = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show", "up"],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        )
        iface_ips = []
        for line in out.splitlines():
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", line)
            if m and not m.group(1).startswith("127."):
                iface_ips.append(m.group(1))
    except Exception:
        iface_ips = ["0.0.0.0"]

    if not iface_ips:
        iface_ips = ["0.0.0.0"]

    sockets = []
    for ip in set(iface_ips):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
            if ip != "0.0.0.0":
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
            sock.settimeout(0.5)
            sock.sendto(msg, ("239.255.255.250", 1900))
            sockets.append(sock)
        except OSError:
            pass

    import select
    end = time.time() + timeout
    locations: dict[str, str] = {}  # host -> location_url
    try:
        while time.time() < end and sockets:
            rem = max(0.05, min(0.5, end - time.time()))
            r, _, _ = select.select(sockets, [], [], rem)
            for sock in r:
                try:
                    data, (src_ip, _) = sock.recvfrom(4096)
                    text = data.decode("utf-8", "ignore")
                    m = re.search(r"LOCATION:\s*(\S+)", text, re.I)
                    if m and src_ip not in locations:
                        locations[src_ip] = m.group(1).strip()
                except OSError:
                    continue
    finally:
        for sock in sockets:
            try:
                sock.close()
            except Exception:
                pass

    found: List[DiscoveredCamera] = []
    _CAMERA_KEYWORDS = (
        "cam", "camera", "cctv", "nvr", "dvr", "surveillance", "tapo",
        "reolink", "hikvision", "dahua", "amcrest", "foscam", "ezviz",
        "wyze", "eufy", "axis", "uniview", "video", "transmitter",
    )

    for host, loc_url in locations.items():
        info = _fetch_upnp_description(loc_url)
        if not info:
            continue
        _SSDP_INFO_CACHE[host] = info

        haystack = " ".join([
            info.get("deviceType", ""),
            info.get("modelDescription", ""),
            info.get("friendlyName", ""),
            info.get("manufacturer", ""),
            info.get("modelName", ""),
        ]).lower()

        is_cam = any(kw in haystack for kw in _CAMERA_KEYWORDS)
        if not is_cam:
            continue

        p = urlparse(loc_url)
        port = p.port or 80
        vendor = info.get("manufacturer", "")
        for rx, name in _VENDOR_RE:
            if rx.search(haystack):
                vendor = name
                break

        mac = get_mac_for_host(host)
        if not vendor and mac:
            vendor = identify_vendor_from_mac(mac)

        model = info.get("modelName", "") or info.get("modelNumber", "")
        friendly = info.get("friendlyName", "")
        note = f"SSDP: {friendly or model or 'Camera'}"

        found.append(DiscoveredCamera(
            host=host,
            url=info.get("presentationURL", ""),
            method="ssdp",
            vendor=vendor,
            model=model,
            note=note,
            port=port,
            mac=mac,
        ))

    return found


# ---------------------------------------------------------------------------
# ONVIF
# ---------------------------------------------------------------------------
def _onvif_soap(action: str, body_xml: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:trt="http://www.onvif.org/ver10/media/wsdl"'
        ' xmlns:tds="http://www.onvif.org/ver10/device/wsdl"'
        ' xmlns:tt="http://www.onvif.org/ver10/schema">'
        '<soap:Header>'
        f'<wsa:MessageID xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
        f'uuid:{uuid.uuid4()}</wsa:MessageID>'
        '</soap:Header>'
        '<soap:Body>'
        f'{body_xml}'
        '</soap:Body>'
        '</soap:Envelope>'
    ).encode("utf-8")


# ---------------------------------------------------------------------------
# ONVIF
# ---------------------------------------------------------------------------
def _onvif_post_once(xaddr: str, action: str, body_xml: str,
                     user: str = "", password: str = "",
                     timeout: float = 4.0) -> Optional[str]:
    from urllib.parse import urlparse
    p = urlparse(xaddr)
    host = p.hostname or ""
    port = p.port or (443 if p.scheme == "https" else 80)
    path = p.path or "/onvif/device_service"
    envelope = _onvif_soap(action, body_xml)

    auth = ""
    if user:
        import base64
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        auth = f"Basic {token}"

    if p.scheme == "https":
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        headers = {
            "Content-Type": 'application/soap+xml; charset="utf-8"',
            "SOAPAction": f'"{action}"',
        }
        if auth:
            headers["Authorization"] = auth
        conn.request("POST", path, body=envelope, headers=headers)
        resp = conn.getresponse()
        return resp.read(65536).decode("utf-8", "replace")
    except (OSError, http.client.HTTPException):
        return None
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def onvif_post(xaddr: str, action: str, body_xml: str,
               user: str = "", password: str = "",
               timeout: float = 4.0, retries: int = 2) -> Optional[str]:
    """POST a SOAP envelope to an ONVIF XAddr with retries.

    Some cameras fail the first request due to firmware bugs or busy
    CPUs. We retry a few times before giving up.
    """
    last_err: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            return _onvif_post_once(xaddr, action, body_xml, user, password, timeout)
        except (OSError, http.client.HTTPException) as exc:
            last_err = exc
            if attempt < retries:
                time.sleep(0.3 * attempt)
    return None


def onvif_getdeviceinformation(xaddr: str, user: str = "", password: str = "",
                               timeout: float = 4.0) -> dict:
    """Call GetDeviceInformation and parse Manufacturer/Model/Firmware."""
    body = '<tds:GetDeviceInformation/>'
    resp = onvif_post(xaddr, "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation",
                      body, user=user, password=password, timeout=timeout)
    if not resp:
        return {}
    out: dict = {}
    for field_name in ("Manufacturer", "Model", "FirmwareVersion", "SerialNumber", "HardwareId"):
        m = re.search(rf"<[^:>]*:?{field_name}>([^<]+)</", resp)
        if m:
            out[field_name] = m.group(1).strip()
    return out


def onvif_get_profiles(xaddr: str, user: str = "", password: str = "",
                       timeout: float = 4.0) -> List[dict]:
    """Call GetProfiles and return a list of {name, token}."""
    body = '<trt:GetProfiles/>'
    resp = onvif_post(xaddr, "http://www.onvif.org/ver10/media/wsdl/GetProfiles",
                      body, user=user, password=password, timeout=timeout)
    if not resp:
        return []
    out: List[dict] = []
    for m in re.finditer(r"<trt:Profiles[^>]*token=\"([^\"]+)\"[^>]*>(.*?)</trt:Profiles>", resp, re.S):
        token, inner = m.group(1), m.group(2)
        name_m = re.search(r"<tt:Name>([^<]+)</tt:Name>", inner)
        out.append({"token": token, "name": name_m.group(1) if name_m else token})
    return out


def onvif_get_stream_uri(xaddr: str, profile_token: str,
                         user: str = "", password: str = "",
                         timeout: float = 4.0) -> Optional[str]:
    """Call GetStreamUri and return the URI."""
    body = f'<trt:GetStreamUri><trt:StreamSetup><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>{profile_token}</trt:ProfileToken></trt:GetStreamUri>'
    resp = onvif_post(xaddr, "http://www.onvif.org/ver10/media/wsdl/GetStreamUri",
                      body, user=user, password=password, timeout=timeout)
    if not resp:
        return None
    m = re.search(r"<tt:Uri>([^<]+)</tt:Uri>", resp)
    return m.group(1) if m else None


def onvif_get_video_sources(xaddr: str, user: str = "", password: str = "",
                            timeout: float = 4.0) -> List[dict]:
    """Call GetVideoSources and return a list of {token, name} for each video input/channel."""
    body = '<trt:GetVideoSources/>'
    resp = onvif_post(xaddr, "http://www.onvif.org/ver10/media/wsdl/GetVideoSources",
                      body, user=user, password=password, timeout=timeout)
    if not resp:
        return []
    out: List[dict] = []
    for m in re.finditer(r"<trt:VideoSources[^>]*token=\"([^\"]+)\"[^>]*>(.*?)</trt:VideoSources>", resp, re.S):
        token, inner = m.group(1), m.group(2)
        out.append({"token": token, "name": f"VideoSource {token}"})
    if not out:
        for m in re.finditer(r"token=\"([^\"]+)\"[^>]*>.*?VideoSources", resp, re.S):
            out.append({"token": m.group(1), "name": f"VideoSource {m.group(1)}"})
    return out


# ---------------------------------------------------------------------------
# WS-Discovery & Scopes Cache
# ---------------------------------------------------------------------------
_ONVIF_SCOPES_CACHE: dict[str, dict[str, str]] = {}


def get_onvif_scopes_info(xaddr_or_host: str) -> dict[str, str]:
    """Return cached vendor/model info extracted from ONVIF WS-Discovery Scopes."""
    if xaddr_or_host in _ONVIF_SCOPES_CACHE:
        return _ONVIF_SCOPES_CACHE[xaddr_or_host]
    from urllib.parse import urlparse
    host = urlparse(xaddr_or_host).hostname or xaddr_or_host
    return _ONVIF_SCOPES_CACHE.get(host, {})


def onvif_ws_discovery(timeout: float = 3.0) -> List[str]:
    """Send WS-Discovery probe on all interfaces and return the XAddrs."""
    msg = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Envelope xmlns:dn="http://www.onvif.org/ver10/network/wsdl"'
        ' xmlns="http://www.w3.org/2003/05/soap-envelope">'
        '<Header>'
        f'<wsa:MessageID xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
        f'uuid:{uuid.uuid4()}</wsa:MessageID>'
        '<wsa:To xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
        'urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
        '<wsa:Action xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
        'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
        '</Header>'
        '<Body>'
        '<Probe xmlns="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
        '<Types>dn:NetworkVideoTransmitter</Types>'
        '</Probe>'
        '</Body>'
        '</Envelope>'
    ).encode("utf-8")
    
    xaddrs: List[str] = []
    
    # Try all subnets to bind to correct interfaces
    nets = all_local_subnets()
    iface_ips = [n.network_address.exploded[:-1] + "1" for n in nets] # Approximation
    # A better way to get iface IPs:
    import subprocess
    try:
        out = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show", "up"],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        )
        iface_ips = []
        for line in out.splitlines():
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", line)
            if m and not m.group(1).startswith("127."):
                iface_ips.append(m.group(1))
    except Exception:
        try:
            iface_ips = [socket.gethostbyname(socket.gethostname())]
        except OSError:
            iface_ips = ["0.0.0.0"]

    if not iface_ips:
        iface_ips = ["0.0.0.0"]

    sockets = []
    for ip in set(iface_ips):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
            if ip != "0.0.0.0":
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
            sock.settimeout(0.5)
            # Send 2 probes to combat UDP drop
            sock.sendto(msg, ("239.255.255.250", 3702))
            sock.sendto(msg, ("239.255.255.250", 3702))
            sockets.append(sock)
        except OSError:
            pass
            
    import select
    end = time.time() + timeout
    try:
        while time.time() < end and sockets:
            rem = max(0.05, min(0.5, end - time.time()))
            r, _, _ = select.select(sockets, [], [], rem)
            for sock in r:
                try:
                    data, (src_ip, _) = sock.recvfrom(8192)
                    text = data.decode("utf-8", "ignore")

                    # Extract scopes (vendor/name, hardware/model)
                    scopes_vendor = ""
                    scopes_model = ""
                    scopes_m = re.search(r"<(?:\w+:)?Scopes>([^<]+)</", text, re.I)
                    if scopes_m:
                        from urllib.parse import unquote
                        for scope in scopes_m.group(1).strip().split():
                            unquoted = unquote(scope)
                            if "/name/" in unquoted:
                                scopes_vendor = unquoted.split("/name/", 1)[-1].strip()
                            elif "/hardware/" in unquoted:
                                scopes_model = unquoted.split("/hardware/", 1)[-1].strip()

                    for m in re.finditer(r"XAddrs>([^<]+)</", text):
                        for x in m.group(1).strip().split():
                            xaddrs.append(x)
                            if scopes_vendor or scopes_model:
                                from urllib.parse import urlparse
                                host = urlparse(x).hostname or src_ip
                                info = {"vendor": scopes_vendor, "model": scopes_model}
                                _ONVIF_SCOPES_CACHE[x] = info
                                if host:
                                    _ONVIF_SCOPES_CACHE[host] = info
                    if (scopes_vendor or scopes_model) and src_ip:
                        _ONVIF_SCOPES_CACHE[src_ip] = {"vendor": scopes_vendor, "model": scopes_model}
                except OSError:
                    continue
    finally:
        for sock in sockets:
            try:
                sock.close()
            except Exception:
                pass

    # De-dup while preserving order
    seen: Set[str] = set()
    out: List[str] = []
    for x in xaddrs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ---------------------------------------------------------------------------
# DVR & Multi-Channel Detection
# ---------------------------------------------------------------------------

_DVR_SIGNATURE_RE = re.compile(
    r"\b(DVR|NVR|XVR|HCVR|NetSurveillance|Recorder)\b|\bDS-[789]\d{3}\b|\bRLN\d+\b",
    re.I,
)


def is_dvr_device(haystack: str) -> bool:
    """Check if a string indicates a DVR/NVR device."""
    return bool(_DVR_SIGNATURE_RE.search(haystack))


DVR_RTSP_TEMPLATES = [
    # Hikvision DVR / NVR: channels 101, 201, 301, 401...
    {"vendor": "Hikvision", "fmt": "/Streaming/Channels/{ch}01", "type": "hik_100"},
    # Dahua / Amcrest / Lorex DVR: channel=1, 2, 3...
    {"vendor": "Dahua", "fmt": "/cam/realmonitor?channel={ch}&subtype=0", "type": "dahua"},
    # Reolink NVR: 01, 02, 03...
    {"vendor": "Reolink", "fmt": "/h264Preview_{ch:02d}_main", "type": "reolink"},
    # Xiongmai / XM / NetSurveillance DVR
    {"vendor": "NetSurveillance", "fmt": "/cam{ch}/h264", "type": "xm"},
    # Generic channel paths
    {"vendor": "Generic DVR", "fmt": "/ch{ch}/main", "type": "generic"},
    {"vendor": "Generic DVR", "fmt": "/live/ch{ch}", "type": "generic"},
    {"vendor": "Generic DVR", "fmt": "/channel{ch}", "type": "generic"},
]


def detect_hikvision_dvr(host: str, rtsp_port: int = 554, http_port: int = 80,
                         user: str = "", password: str = "",
                         open_ports: Optional[Set[int]] = None,
                         timeout: float = 2.5) -> List[DiscoveredCamera]:
    """Check for Hikvision DVR/NVR via ISAPI and RTSP channel probes."""
    found: List[DiscoveredCamera] = []
    model = ""
    firmware = ""
    device_type = ""

    # 1. Try ISAPI System/deviceInfo
    info_res = http_get(host, http_port, "/ISAPI/System/deviceInfo", user=user, password=password, timeout=timeout)
    if info_res is not None:
        _status, body, _headers = info_res
        if _status == 200:
            m_dt = re.search(r"<deviceType>([^<]+)</deviceType>", body)
            if m_dt:
                device_type = m_dt.group(1).strip()
            m_mod = re.search(r"<model>([^<]+)</model>", body)
            if m_mod:
                model = m_mod.group(1).strip()
            m_fw = re.search(r"<firmwareVersion>([^<]+)</firmwareVersion>", body)
            if m_fw:
                firmware = m_fw.group(1).strip()

    # 2. Try ISAPI Streaming/channels
    chan_res = http_get(host, http_port, "/ISAPI/Streaming/channels", user=user, password=password, timeout=timeout)
    channel_ids: List[Tuple[int, str, str]] = []  # (ch_number, ch_id, ch_name)
    if chan_res is not None and chan_res[0] == 200:
        for m in re.finditer(r"<StreamingChannel[^>]*>(.*?)</StreamingChannel>", chan_res[1], re.S):
            inner = m.group(1)
            id_m = re.search(r"<id>([^<]+)</id>", inner)
            name_m = re.search(r"<channelName>([^<]+)</channelName>", inner)
            enabled_m = re.search(r"<enabled>([^<]+)</enabled>", inner)
            if enabled_m and enabled_m.group(1).strip().lower() == "false":
                continue
            if id_m:
                raw_id = id_m.group(1).strip()
                if raw_id.endswith("01"):
                    try:
                        ch_num = int(raw_id[:-2])
                    except ValueError:
                        ch_num = len(channel_ids) + 1
                    ch_name = name_m.group(1).strip() if name_m else f"Camera {ch_num}"
                    channel_ids.append((ch_num, raw_id, ch_name))
                elif raw_id.isdigit() and int(raw_id) < 100:
                    ch_num = int(raw_id)
                    ch_name = name_m.group(1).strip() if name_m else f"Camera {ch_num}"
                    channel_ids.append((ch_num, raw_id, ch_name))

    if not channel_ids:
        proxy_res = http_get(host, http_port, "/ISAPI/ContentMgmt/InputProxy/channels", user=user, password=password, timeout=timeout)
        if proxy_res is not None and proxy_res[0] == 200:
            for m in re.finditer(r"<InputProxyChannel[^>]*>(.*?)</InputProxyChannel>", proxy_res[1], re.S):
                inner = m.group(1)
                id_m = re.search(r"<id>([^<]+)</id>", inner)
                name_m = re.search(r"<name>([^<]+)</name>", inner)
                if id_m:
                    try:
                        ch_num = int(id_m.group(1).strip())
                    except ValueError:
                        ch_num = len(channel_ids) + 1
                    ch_name = name_m.group(1).strip() if name_m else f"Camera {ch_num}"
                    channel_ids.append((ch_num, f"{ch_num}01", ch_name))

    if len(channel_ids) >= 2:
        total = len(channel_ids)
        dvr_label = f"Hikvision {total}-Channel {device_type or 'DVR'}"
        for ch_num, ch_id, ch_name in channel_ids:
            found.append(DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{rtsp_port}/Streaming/Channels/{ch_id}",
                method="dvr",
                vendor="Hikvision",
                model=model,
                firmware=firmware,
                note=f"DVR Channel {ch_num} ({ch_name})",
                port=rtsp_port,
                channel=ch_num,
                total_channels=total,
                is_dvr=True,
                dvr_type=dvr_label,
            ))
        return found

    # 3. RTSP multi-channel DESCRIBE fallback
    d1 = rtsp_describe(host, rtsp_port, "/Streaming/Channels/101", user=user, password=password, timeout=timeout)
    if d1 is not None and d1.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
        vendor_name = identify_vendor_from_rtsp(d1)
        if vendor_name and vendor_name != "Hikvision":
            return []
        haystack = " ".join([d1.get("server", ""), d1.get("body", ""), model, device_type])
        has_dvr_port = bool(open_ports and (8000 in open_ports or 37777 in open_ports or 34567 in open_ports or 9000 in open_ports))
        if not (is_dvr_device(haystack) or has_dvr_port or "Embedded Net DVR" in haystack):
            return []

        d2 = rtsp_describe(host, rtsp_port, "/Streaming/Channels/201", user=user, password=password, timeout=timeout)
        if d2 is not None and d2.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
            active_channels: List[int] = [1, 2]
            fails = 0
            for ch in range(3, 33):
                dc = rtsp_describe(host, rtsp_port, f"/Streaming/Channels/{ch}01", user=user, password=password, timeout=timeout)
                if dc is not None and dc.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
                    active_channels.append(ch)
                    fails = 0
                else:
                    fails += 1
                    if fails >= 2:
                        break
            total = len(active_channels)
            dvr_label = f"Hikvision {total}-Channel DVR"
            for ch in active_channels:
                found.append(DiscoveredCamera(
                    host=host,
                    url=f"rtsp://{host}:{rtsp_port}/Streaming/Channels/{ch}01",
                    method="dvr",
                    vendor="Hikvision",
                    model=model,
                    firmware=firmware,
                    note=f"DVR Channel {ch} (main stream)",
                    port=rtsp_port,
                    channel=ch,
                    total_channels=total,
                    is_dvr=True,
                    dvr_type=dvr_label,
                ))
            return found

    return found


def detect_dahua_dvr(host: str, rtsp_port: int = 554, http_port: int = 80,
                     user: str = "", password: str = "",
                     open_ports: Optional[Set[int]] = None,
                     timeout: float = 2.5) -> List[DiscoveredCamera]:
    """Check for Dahua / Amcrest DVR/NVR via CGI and RTSP channel probes."""
    found: List[DiscoveredCamera] = []
    device_type = ""
    vendor = "Dahua"

    # 1. Try CGI devInfo
    dev_res = http_get(host, http_port, "/cgi-bin/devInfo.cgi?action=get", user=user, password=password, timeout=timeout)
    if dev_res is not None and dev_res[0] == 200:
        m_dt = re.search(r"deviceType=([^\r\n]+)", dev_res[1])
        if m_dt:
            device_type = m_dt.group(1).strip()
        m_vendor = re.search(r"vendor=([^\r\n]+)", dev_res[1], re.I)
        if m_vendor:
            vendor = m_vendor.group(1).strip()

    # 2. Try CGI ChannelTitle
    title_res = http_get(host, http_port, "/cgi-bin/configManager.cgi?action=getConfig&name=ChannelTitle",
                         user=user, password=password, timeout=timeout)
    channel_titles: dict[int, str] = {}
    if title_res is not None and title_res[0] == 200:
        for m in re.finditer(r"table\.ChannelTitle\[(\d+)\]\.Name=([^\r\n]+)", title_res[1]):
            idx = int(m.group(1))
            channel_titles[idx + 1] = m.group(2).strip()

    if len(channel_titles) >= 2:
        total = len(channel_titles)
        dvr_label = f"{vendor} {total}-Channel {device_type or 'DVR'}"
        for ch, name in sorted(channel_titles.items()):
            found.append(DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{rtsp_port}/cam/realmonitor?channel={ch}&subtype=0",
                method="dvr",
                vendor=vendor,
                note=f"DVR Channel {ch} ({name})",
                port=rtsp_port,
                channel=ch,
                total_channels=total,
                is_dvr=True,
                dvr_type=dvr_label,
            ))
        return found

    # 3. RTSP multi-channel DESCRIBE fallback
    d1 = rtsp_describe(host, rtsp_port, "/cam/realmonitor?channel=1&subtype=0", user=user, password=password, timeout=timeout)
    if d1 is not None and d1.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
        vendor_name = identify_vendor_from_rtsp(d1)
        if vendor_name and vendor_name not in ("Dahua", "Amcrest", "Lorex"):
            return []
        haystack = " ".join([d1.get("server", ""), d1.get("body", ""), device_type])
        has_dvr_port = bool(open_ports and 37777 in open_ports)
        if not (is_dvr_device(haystack) or has_dvr_port):
            return []

        d2 = rtsp_describe(host, rtsp_port, "/cam/realmonitor?channel=2&subtype=0", user=user, password=password, timeout=timeout)
        if d2 is not None and d2.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
            active_channels: List[int] = [1, 2]
            fails = 0
            for ch in range(3, 33):
                dc = rtsp_describe(host, rtsp_port, f"/cam/realmonitor?channel={ch}&subtype=0", user=user, password=password, timeout=timeout)
                if dc is not None and dc.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
                    active_channels.append(ch)
                    fails = 0
                else:
                    fails += 1
                    if fails >= 2:
                        break
            total = len(active_channels)
            dvr_label = f"{vendor} {total}-Channel DVR"
            for ch in active_channels:
                found.append(DiscoveredCamera(
                    host=host,
                    url=f"rtsp://{host}:{rtsp_port}/cam/realmonitor?channel={ch}&subtype=0",
                    method="dvr",
                    vendor=vendor,
                    note=f"DVR Channel {ch} (main stream)",
                    port=rtsp_port,
                    channel=ch,
                    total_channels=total,
                    is_dvr=True,
                    dvr_type=dvr_label,
                ))
            return found

    return found


def detect_reolink_dvr(host: str, rtsp_port: int = 554, http_port: int = 80,
                       user: str = "", password: str = "",
                       open_ports: Optional[Set[int]] = None,
                       timeout: float = 2.5) -> List[DiscoveredCamera]:
    """Check for Reolink NVR via API and RTSP channel probes."""
    import json
    found: List[DiscoveredCamera] = []
    model = ""

    # 1. Reolink GetDevInfo
    dev_res = http_get(host, http_port, "/api.cgi?cmd=GetDevInfo", user=user, password=password, timeout=timeout)
    is_nvr = False
    if dev_res is not None and dev_res[0] == 200:
        try:
            data = json.loads(dev_res[1])
            if isinstance(data, list) and data:
                val = data[0].get("value", {}).get("DevInfo", {})
                if val.get("type") == "NVR" or str(val.get("model", "")).upper().startswith("RLN"):
                    is_nvr = True
                    model = val.get("model", "")
        except Exception:
            pass

    # 2. Reolink GetChannelstatus
    chan_res = http_get(host, http_port, "/api.cgi?cmd=GetChannelstatus", user=user, password=password, timeout=timeout)
    active_channels: List[Tuple[int, str]] = []
    if chan_res is not None and chan_res[0] == 200:
        try:
            data = json.loads(chan_res[1])
            if isinstance(data, list) and data:
                statuses = data[0].get("value", {}).get("status", [])
                for item in statuses:
                    if item.get("online") == 1:
                        ch_idx = item.get("channel", 0) + 1
                        name = item.get("name", "") or f"Camera {ch_idx}"
                        active_channels.append((ch_idx, name))
        except Exception:
            pass

    if active_channels and (is_nvr or len(active_channels) >= 2):
        total = len(active_channels)
        dvr_label = f"Reolink {total}-Channel NVR"
        for ch, name in active_channels:
            found.append(DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{rtsp_port}/h264Preview_{ch:02d}_main",
                method="dvr",
                vendor="Reolink",
                model=model,
                note=f"DVR Channel {ch} ({name})",
                port=rtsp_port,
                channel=ch,
                total_channels=total,
                is_dvr=True,
                dvr_type=dvr_label,
            ))
        return found

    # 3. RTSP multi-channel fallback
    d1 = rtsp_describe(host, rtsp_port, "/h264Preview_01_main", user=user, password=password, timeout=timeout)
    if d1 is not None and d1.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
        vendor_name = identify_vendor_from_rtsp(d1)
        if vendor_name and vendor_name != "Reolink":
            return []
        haystack = " ".join([d1.get("server", ""), d1.get("body", ""), model])
        has_dvr_port = bool(open_ports and 9000 in open_ports)
        if not (is_dvr_device(haystack) or has_dvr_port):
            return []

        d2 = rtsp_describe(host, rtsp_port, "/h264Preview_02_main", user=user, password=password, timeout=timeout)
        if d2 is not None and d2.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
            channels: List[int] = [1, 2]
            fails = 0
            for ch in range(3, 17):
                dc = rtsp_describe(host, rtsp_port, f"/h264Preview_{ch:02d}_main", user=user, password=password, timeout=timeout)
                if dc is not None and dc.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
                    channels.append(ch)
                    fails = 0
                else:
                    fails += 1
                    if fails >= 2:
                        break
            total = len(channels)
            dvr_label = f"Reolink {total}-Channel NVR"
            for ch in channels:
                found.append(DiscoveredCamera(
                    host=host,
                    url=f"rtsp://{host}:{rtsp_port}/h264Preview_{ch:02d}_main",
                    method="dvr",
                    vendor="Reolink",
                    model=model,
                    note=f"DVR Channel {ch} (main stream)",
                    port=rtsp_port,
                    channel=ch,
                    total_channels=total,
                    is_dvr=True,
                    dvr_type=dvr_label,
                ))
            return found

    return found


def detect_generic_rtsp_dvr(host: str, rtsp_port: int = 554,
                            user: str = "", password: str = "",
                            open_ports: Optional[Set[int]] = None,
                            timeout: float = 2.5) -> List[DiscoveredCamera]:
    """Probe generic RTSP channel patterns for multi-channel DVRs."""
    found: List[DiscoveredCamera] = []

    for t in DVR_RTSP_TEMPLATES:
        fmt = t["fmt"]
        v_name = t["vendor"]
        p1 = fmt.format(ch=1)
        p2 = fmt.format(ch=2)
        d1 = rtsp_describe(host, rtsp_port, p1, user=user, password=password, timeout=timeout)
        if d1 is None or not d1.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
            continue

        haystack = " ".join([d1.get("server", ""), d1.get("body", "")])
        has_dvr_port = bool(open_ports and any(p in open_ports for p in DVR_PORTS))
        if not (is_dvr_device(haystack) or has_dvr_port):
            continue

        d2 = rtsp_describe(host, rtsp_port, p2, user=user, password=password, timeout=timeout)
        if d2 is None or not d2.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
            continue

        # Both channels 1 and 2 responded and device has DVR signature
        channels: List[int] = [1, 2]
        fails = 0
        max_ch = 17 if "Reolink" in v_name else 33
        for ch in range(3, max_ch):
            path = fmt.format(ch=ch)
            dc = rtsp_describe(host, rtsp_port, path, user=user, password=password, timeout=timeout)
            if dc is not None and dc.get("status", "").startswith(("RTSP/1.0 200", "RTSP/1.0 401")):
                channels.append(ch)
                fails = 0
            else:
                fails += 1
                if fails >= 2:
                    break
        total = len(channels)
        vendor = identify_vendor_from_rtsp(d1) or v_name
        dvr_label = f"{vendor} {total}-Channel DVR"
        for ch in channels:
            path = fmt.format(ch=ch)
            found.append(DiscoveredCamera(
                host=host,
                url=f"rtsp://{host}:{rtsp_port}{path}",
                method="dvr",
                vendor=vendor,
                note=f"DVR Channel {ch} (main stream)",
                port=rtsp_port,
                channel=ch,
                total_channels=total,
                is_dvr=True,
                dvr_type=dvr_label,
            ))
        return found
    return found


def detect_dvr_channels(host: str,
                        rtsp_port: int = 554,
                        http_port: int = 80,
                        user: str = "",
                        password: str = "",
                        open_ports: Optional[Set[int]] = None,
                        timeout: float = 2.5) -> List[DiscoveredCamera]:
    """Detect if a host is a DVR/NVR and discover all connected camera channels.

    Returns a list of DiscoveredCamera records (one per connected camera channel)
    if the host is a multi-channel DVR/NVR, or an empty list if not.
    """
    ports = open_ports or set()

    candidate_rtsp = [p for p in RTSP_PORTS if p in ports] or [rtsp_port]
    candidate_http = [p for p in HTTP_PORTS if p in ports] or [http_port]

    # Dahua port 37777 prioritized
    if 37777 in ports:
        for rp in candidate_rtsp:
            for hp in candidate_http:
                cams = detect_dahua_dvr(host, rtsp_port=rp, http_port=hp, user=user, password=password, open_ports=ports, timeout=timeout)
                if cams:
                    return cams

    # Hikvision port 8000 prioritized
    if 8000 in ports or 8000 in candidate_http:
        for rp in candidate_rtsp:
            cams = detect_hikvision_dvr(host, rtsp_port=rp, http_port=8000, user=user, password=password, open_ports=ports, timeout=timeout)
            if cams:
                return cams

    # Try vendor HTTP checks on available HTTP ports
    for hp in candidate_http:
        # Hikvision
        for rp in candidate_rtsp:
            cams = detect_hikvision_dvr(host, rtsp_port=rp, http_port=hp, user=user, password=password, open_ports=ports, timeout=timeout)
            if cams:
                return cams
        # Dahua
        for rp in candidate_rtsp:
            cams = detect_dahua_dvr(host, rtsp_port=rp, http_port=hp, user=user, password=password, open_ports=ports, timeout=timeout)
            if cams:
                return cams
        # Reolink
        for rp in candidate_rtsp:
            cams = detect_reolink_dvr(host, rtsp_port=rp, http_port=hp, user=user, password=password, open_ports=ports, timeout=timeout)
            if cams:
                return cams

    # Xiongmai / NetSurveillance port 34567
    if 34567 in ports:
        for rp in candidate_rtsp:
            cams = detect_generic_rtsp_dvr(host, rtsp_port=rp, user=user, password=password, open_ports=ports, timeout=timeout)
            if cams:
                return cams

    # Generic multi-channel RTSP probe
    for rp in candidate_rtsp:
        cams = detect_generic_rtsp_dvr(host, rtsp_port=rp, user=user, password=password, open_ports=ports, timeout=timeout)
        if cams:
            return cams

    return []


# ---------------------------------------------------------------------------
# Quick all-port probe for known hosts
# ---------------------------------------------------------------------------
def quick_probe_all_ports(host: str, user: str = "", password: str = "", workers: int = 16) -> List[DiscoveredCamera]:
    """Given a known host (e.g. from ARP), sweep standard camera ports and fetch streams."""
    mac = get_mac_for_host(host)
    mac_vendor = identify_vendor_from_mac(mac) if mac else ""
    ssdp_info = get_ssdp_info(host)
    scopes_info = get_onvif_scopes_info(host)
    vendor_hint = mac_vendor or ssdp_info.get("manufacturer", "") or scopes_info.get("vendor", "")

    open_ports = quick_probe_host(host, ports=(*RTSP_PORTS, *HTTP_PORTS, *TUYA_PORTS, *DVR_PORTS), timeout=0.6)

    # First check if this host is a DVR/NVR with connected cameras
    dvr_cams = detect_dvr_channels(host, user=user, password=password, open_ports=open_ports)
    if dvr_cams:
        for cam in dvr_cams:
            if not cam.mac:
                cam.mac = mac
            if not cam.vendor and vendor_hint:
                cam.vendor = vendor_hint
        return dvr_cams

    found: List[DiscoveredCamera] = []

    # Try RTSP on any open RTSP ports
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        rtsp_futs = []
        for port in RTSP_PORTS:
            if port in open_ports:
                rtsp_futs.append(ex.submit(rtsp_probe_paths, host, port, user, password, vendor_hint=vendor_hint))

        for fut in concurrent.futures.as_completed(rtsp_futs):
            cam = fut.result()
            if cam:
                found.append(cam)

    # Try HTTP on any open HTTP ports
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        http_futs = []
        for port in HTTP_PORTS:
            if port in open_ports:
                http_futs.append(ex.submit(http_probe, host, port, user, password))

        for fut in concurrent.futures.as_completed(http_futs):
            cams = fut.result()
            if cams:
                found.extend(cams)

    # If no RTSP or HTTP camera stream found, but Tuya port (6668) is open:
    if not found and any(p in open_ports for p in TUYA_PORTS):
        vendor = vendor_hint or "Orion / Tuya / Grid Connect"
        found.append(DiscoveredCamera(
            host=host,
            url="",
            method="cloud",
            vendor=vendor,
            mac=mac,
            note=(
                f"Cloud-only ({vendor}, Tuya port 6668 detected). "
                "Enable ONVIF/PC View in vendor app (Grid Connect / Tuya / Smart Life) and re-scan."
            ),
        ))

    # Enrich all found cameras with MAC and discovered vendor/model
    for cam in found:
        if not cam.mac and mac:
            cam.mac = mac
        if (not cam.vendor or cam.vendor in ("ONVIF device", "HiSilicon (generic)")) and vendor_hint:
            cam.vendor = vendor_hint
        if not cam.model:
            cam.model = scopes_info.get("model", "") or ssdp_info.get("modelName", "") or ssdp_info.get("modelNumber", "")

    return found

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
def dedupe(results: Iterable[DiscoveredCamera]) -> List[DiscoveredCamera]:
    """Drop duplicates by (host, url). First-seen wins."""
    out: List[DiscoveredCamera] = []
    seen: Set[Tuple[str, str]] = set()
    for r in results:
        k = r.key()
        if k in seen:
            continue
        seen.add(k)
        out.append(r)
    return out


# Optional ffprobe fallback for environments where the raw RTSP probe is
# blocked by the device. Kept here so the same module exposes both paths.
def ffprobe_works(url: str, user: str = "", password: str = "",
                  timeout: float = 4.0) -> bool:
    import shutil
    import subprocess
    if not shutil.which("ffprobe"):
        return False
    try:
        args = [
            "ffprobe", "-v", "error", "-rtsp_transport", "tcp", "-i", url,
        ]
        if user:
            args += ["-user", user, "-password", password]
        args += ["-show_entries", "stream=codec_name", "-of", "csv=p=0"]
        subprocess.run(args, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=timeout)
        return True
    except (subprocess.TimeoutExpired, OSError):
        return False
