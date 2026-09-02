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
RTSP_PORTS = (554, 8554, 10554)
HTTP_PORTS = (80, 8080, 8000, 443)


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
    "/11",                       # Reolink alt
    "/stream1",
    "/stream2",
    "/av0_0",                    # some Chinese cams
    "/video",                    # MJPEG-over-RTSP
    "/",                         # root
]


# HTTP probe paths. Each tuple is (path, method, what-it-means-if-200).
# The path is a substring we look for in the body to identify the vendor.
HTTP_PROBES: List[Tuple[str, str, str]] = [
    ("/ISAPI/Streaming/channels", "GET", "hikvision"),
    ("/ISAPI/System/deviceInfo", "GET", "hikvision"),
    ("/cgi-bin/magicBox.cgi?action=getProductClass", "GET", "hikvision"),
    ("/cgi-bin/devInfo.cgi?action=get", "GET", "dahua"),
    ("/cgi-bin/menu.cgi?action=getProductModel", "GET", "dahua"),
    ("/api.cgi?cmd=GetDevInfo&token=", "GET", "reolink"),
    ("/onvif/device_service", "POST", "onvif"),
    ("/axis-cgi/mjpg/video.cgi", "GET", "axis-mjpeg"),
    ("/mjpg/video.mjpg", "GET", "generic-mjpeg"),
    ("/video.mjpg", "GET", "generic-mjpeg"),
    ("/", "GET", "http-root"),
]


# mDNS service types to query.
MDNS_SERVICE_TYPES = ("_rtsp._tcp.local", "_onvif._tcp.local", "_http._tcp.local")


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class DiscoveredCamera:
    host: str
    url: str
    method: str = "rtsp"            # "rtsp", "http", "onvif", "mdns", "arp"
    vendor: str = ""
    model: str = ""
    firmware: str = ""
    note: str = ""
    port: int = 0

    def key(self) -> Tuple[str, str]:
        return (self.host, self.url)

    def display(self) -> str:
        bits: List[str] = []
        bits.append(f"[{self.method.upper():<5}]")
        bits.append(self.host)
        if self.port:
            bits.append(f":{self.port}")
        if self.vendor or self.model:
            ident = " ".join(x for x in (self.vendor, self.model) if x)
            bits.append(f"  ({ident})")
        bits.append(f"  →  {self.url}")
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


_VENDOR_RE = [
    (re.compile(r"Hikvision", re.I), "Hikvision"),
    (re.compile(r"Dahua", re.I), "Dahua"),
    (re.compile(r"Reolink", re.I), "Reolink"),
    (re.compile(r"Axis", re.I), "Axis"),
    (re.compile(r"Bosch", re.I), "Bosch"),
    (re.compile(r"Vivotek", re.I), "Vivotek"),
    (re.compile(r"HiSilicon", re.I), "HiSilicon (generic)"),
    (re.compile(r"ONVIF", re.I), "ONVIF device"),
    (re.compile(r"NetSurveillance", re.I), "NetSurveillance (Chinese OEM)"),
]


def identify_vendor_from_rtsp(info: dict) -> str:
    haystack = " ".join([info.get("server", ""), info.get("body", "")])
    for rx, name in _VENDOR_RE:
        if rx.search(haystack):
            return name
    return ""


def rtsp_probe_paths(host: str, port: int = 554,
                     user: str = "", password: str = "",
                     paths: List[str] = None,
                     timeout: float = _RTSP_TIMEOUT,
                     workers: int = 8) -> Optional[DiscoveredCamera]:
    """Try each path in RTSP_PATHS in parallel until one returns a valid RTSP response.

    Paths are probed concurrently so a single unreachable host only blocks
    for `timeout` seconds (not `timeout * len(paths)`).
    """
    import concurrent.futures
    paths = paths or RTSP_PATHS
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, len(paths))) as ex:
        futs = {ex.submit(rtsp_describe, host, port, p, user, password, timeout): p
                for p in paths}
        for fut in concurrent.futures.as_completed(futs):
            info = fut.result()
            if info is None:
                continue
            vendor = identify_vendor_from_rtsp(info)
            path = futs[fut]
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


def identify_vendor_from_http(body: str, headers: dict) -> str:
    haystack = " ".join([body, headers.get("server", ""), headers.get("x-powered-by", "")])
    for rx, name in _VENDOR_RE:
        if rx.search(haystack):
            return name
    return ""


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
def arp_hosts() -> Set[str]:
    """Read /proc/net/arp and return IPs that have a resolved MAC."""
    out: Set[str] = set()
    try:
        with open("/proc/net/arp", "r", encoding="ascii") as f:
            next(f)  # header
            for line in f:
                parts = line.split()
                if len(parts) < 6:
                    continue
                ip, _hw, flags, _mac, _mask, _dev = parts[:6]
                # flags: 0x0 = incomplete, 0x2 = reachable, 0x4 = stale, etc.
                if flags == "0x0":
                    continue
                if ip.startswith("127."):
                    continue
                out.add(ip)
    except OSError:
        pass
    return out


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


def mdns_discover(timeout_per_service: float = 1.5) -> List[DiscoveredCamera]:
    found: List[DiscoveredCamera] = []
    for svc in MDNS_SERVICE_TYPES:
        for name in _mdns_query(svc, timeout=timeout_per_service):
            # name looks like "Front Door._rtsp._tcp.local"
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
            found.append(DiscoveredCamera(
                host="",  # mDNS name only — host resolved later
                url=name,
                method=method,
                note=f"mDNS: {name}",
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


def onvif_post(xaddr: str, action: str, body_xml: str,
               user: str = "", password: str = "",
               timeout: float = 4.0) -> Optional[str]:
    """POST a SOAP envelope to an ONVIF XAddr and return the response body."""
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


# ---------------------------------------------------------------------------
# WS-Discovery
# ---------------------------------------------------------------------------
def onvif_ws_discovery(timeout: float = 3.0) -> List[str]:
    """Send WS-Discovery probe and return the XAddrs that respond."""
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
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    xaddrs: List[str] = []
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        try:
            iface_ip = socket.gethostbyname(socket.gethostname())
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                            socket.inet_aton(iface_ip))
        except OSError:
            pass
        sock.settimeout(1.0)
        sock.sendto(msg, ("239.255.255.250", 3702))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = sock.recvfrom(8192)
            except socket.timeout:
                break
            text = data.decode("utf-8", "ignore")
            for m in re.finditer(r"XAddrs>([^<]+)</", text):
                for x in m.group(1).strip().split():
                    xaddrs.append(x)
    except OSError:
        pass
    finally:
        sock.close()
    # De-dup while preserving order
    seen: Set[str] = set()
    out: List[str] = []
    for x in xaddrs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


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
