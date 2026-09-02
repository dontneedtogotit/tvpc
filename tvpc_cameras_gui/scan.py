"""Network discovery: orchestrates the primitives in `discover`.

The `ScanWorker` is a `QObject` so the GUI can keep painting while the
scan runs. It emits:
  * `progress(str)`   — human-readable log line
  * `found(DiscoveredCamera)` — one per unique discovery
  * `failed(str)`     — fatal error (no usable network, etc.)
  * `finished()`      — always emitted, even on failure

Phases (all cancellable):
  1. Read /proc/net/arp for already-seen hosts (instant)
  2. mDNS PTR queries for _rtsp / _onvif / _http
  3. Parallel TCP sweep on the well-known camera ports, across every
     detected /24 (not just the default route)
  4. Raw RTSP DESCRIBE for every host with port 554 / 8554 / 10554 open
  5. HTTP probe of vendor endpoints for hosts with port 80 / 8080 / 8000
  6. ONVIF WS-Discovery multicast
  7. ONVIF GetDeviceInformation + GetProfiles + GetStreamUri for each XAddr

All results are de-duplicated by (host, url) before being emitted.
"""
from __future__ import annotations

import concurrent.futures
import ipaddress
from typing import List, Optional, Set, Tuple

from PySide6.QtCore import QObject, QThread, Signal

from . import discover as disc


# Re-export so existing callers (scan_dialog.py) keep working.
ScanResult = disc.DiscoveredCamera


class ScanWorker(QObject):
    progress = Signal(str)
    found = Signal(object)        # DiscoveredCamera
    finished = Signal()
    failed = Signal(str)

    def __init__(self,
                 user: str = "",
                 password: str = "",
                 cidr: Optional[str] = None,
                 workers: int = 64,
                 do_onvif_enrich: bool = True) -> None:
        super().__init__()
        self.user = user
        self.password = password
        self.cidr = cidr  # user-supplied CIDR; None = auto-detect
        self.workers = workers
        self.do_onvif_enrich = do_onvif_enrich
        self._cancel = False

    def cancel(self) -> None:
        self._cancel = True

    # ------------------------------------------------------------------
    def run(self) -> None:
        try:
            nets = self._resolve_subnets()
            if not nets:
                self.failed.emit("No IPv4 subnets found. Connect to a network first.")
                return
            for n in nets:
                # /32 networks have 1 address; bigger subnets have (size-2).
                host_count = n.num_addresses - 2 if n.prefixlen < 31 else n.num_addresses
                self.progress.emit(f"Scanning {n} ({host_count} host{'s' if host_count != 1 else ''})")

            seen: Set[Tuple[str, str]] = set()
            results: List[disc.DiscoveredCamera] = []

            def _emit(cam: disc.DiscoveredCamera) -> None:
                k = cam.key()
                if k in seen:
                    return
                seen.add(k)
                results.append(cam)
                self.found.emit(cam)

            # 1) ARP table — instant.
            arp = disc.arp_hosts()
            if arp:
                self.progress.emit(f"ARP table: {len(arp)} host(s) with a known MAC")
            for host in arp:
                if self._cancel:
                    return
                # Treat the host as an RTSP candidate, the real DESCRIBE
                # will confirm whether anything is there.
                cam = disc.rtsp_probe_paths(host, port=554,
                                            user=self.user, password=self.password)
                if cam is not None:
                    _emit(cam)

            # 2) mDNS.
            if not self._cancel:
                self.progress.emit("mDNS query (_rtsp / _onvif / _http)…")
                for c in disc.mdns_discover():
                    _emit(c)

            # 3) Parallel TCP sweep, all subnets, all ports.
            if not self._cancel:
                self._sweep_and_probe(nets, _emit)

            # 4) ONVIF WS-Discovery + enrichment.
            if not self._cancel:
                self._onvif_phase(_emit)

            self.progress.emit(f"Done. {len(results)} unique camera(s) found.")
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(f"Scan error: {exc}")
        finally:
            self.finished.emit()

    # ------------------------------------------------------------------
    def _resolve_subnets(self) -> List[ipaddress.IPv4Network]:
        if self.cidr:
            net = disc.parse_cidr_or_subnet(self.cidr)
            if net is not None:
                return [net]
        return disc.all_local_subnets()

    # ------------------------------------------------------------------
    def _sweep_and_probe(self,
                         nets: List[ipaddress.IPv4Network],
                         _emit) -> None:
        # All hosts, deduplicated.
        all_hosts: Set[str] = set()
        for n in nets:
            for h in disc.hosts_in(n):
                all_hosts.add(h)
        for h in disc.arp_hosts():
            all_hosts.add(h)
        if not all_hosts:
            return

        # Parallel TCP probe on every interesting port.
        open_map: dict = {}  # port -> set(hosts)
        for port in (*disc.RTSP_PORTS, *disc.HTTP_PORTS):
            if self._cancel:
                return
            self.progress.emit(f"  TCP/{port} sweep ({len(all_hosts)} hosts)…")
            hits = disc.parallel_tcp_open(
                all_hosts, port, timeout=0.6, workers=self.workers,
            )
            if hits:
                self.progress.emit(f"    {len(hits)} host(s) responded on TCP/{port}")
                open_map[port] = set(hits)

        # RTSP DESCRIBE on hosts that have any RTSP port open.
        rtsp_candidates: Set[str] = set()
        for p in disc.RTSP_PORTS:
            rtsp_candidates |= open_map.get(p, set())
        if rtsp_candidates and not self._cancel:
            self.progress.emit(f"  RTSP DESCRIBE on {len(rtsp_candidates)} host(s)…")
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(self.workers, 16)
            ) as ex:
                futs = {}
                for host in rtsp_candidates:
                    for port in disc.RTSP_PORTS:
                        if host in open_map.get(port, set()):
                            futs[ex.submit(
                                disc.rtsp_probe_paths, host, port,
                                self.user, self.password,
                            )] = host
                            break  # one probe per host; the first open port
                for fut in concurrent.futures.as_completed(futs):
                    if self._cancel:
                        return
                    cam = fut.result()
                    if cam is not None:
                        _emit(cam)

        # HTTP probe on hosts with any HTTP port open.
        http_candidates: Set[Tuple[str, int]] = set()
        for p in disc.HTTP_PORTS:
            for h in open_map.get(p, set()):
                http_candidates.add((h, p))
        if http_candidates and not self._cancel:
            self.progress.emit(f"  HTTP probe on {len(http_candidates)} host(s)…")
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(self.workers, 16)
            ) as ex:
                futs = {
                    ex.submit(disc.http_probe, h, p,
                              self.user, self.password): (h, p)
                    for h, p in http_candidates
                }
                for fut in concurrent.futures.as_completed(futs):
                    if self._cancel:
                        return
                    for cam in fut.result():
                        _emit(cam)

    # ------------------------------------------------------------------
    def _onvif_phase(self, _emit) -> None:
        self.progress.emit("ONVIF WS-Discovery multicast…")
        xaddrs = disc.onvif_ws_discovery()
        if not xaddrs:
            return
        self.progress.emit(f"  {len(xaddrs)} XAddr(s) responded")
        for xaddr in xaddrs:
            if self._cancel:
                return
            # WS-Discovery gives us the XAddr, not a stream URL. We
            # emit it as a candidate (method=onvif) AND, if creds work,
            # enrich it with GetDeviceInformation + GetProfiles +
            # GetStreamUri and emit those as proper RTSP URLs.
            _emit(disc.DiscoveredCamera(
                host="", url=xaddr, method="onvif", note="WS-Discovery XAddr",
            ))
            if not self.do_onvif_enrich:
                continue
            info = disc.onvif_getdeviceinformation(
                xaddr, user=self.user, password=self.password,
            )
            if not info:
                continue
            vendor = info.get("Manufacturer", "")
            model = info.get("Model", "")
            firmware = info.get("FirmwareVersion", "")
            self.progress.emit(
                f"  ONVIF {vendor} {model} {firmware} at {xaddr}"
            )
            profiles = disc.onvif_get_profiles(
                xaddr, user=self.user, password=self.password,
            )
            for prof in profiles:
                uri = disc.onvif_get_stream_uri(
                    xaddr, prof["token"],
                    user=self.user, password=self.password,
                )
                if not uri:
                    continue
                _emit(disc.DiscoveredCamera(
                    host="", url=uri, method="rtsp",
                    vendor=vendor, model=model, firmware=firmware,
                    note=f"ONVIF profile {prof.get('name', prof['token'])}",
                ))


def start_scan(parent,
               user: str = "",
               password: str = "",
               cidr: Optional[str] = None,
               on_found=None,
               on_progress=None,
               on_finished=None,
               on_failed=None) -> Tuple[QThread, "ScanWorker"]:
    """Convenience helper: start a scan on a new QThread."""
    thread = QThread(parent)
    worker = ScanWorker(user=user, password=password, cidr=cidr)
    worker.moveToThread(thread)
    thread.started.connect(worker.run)
    if on_found is not None:
        worker.found.connect(on_found)
    if on_progress is not None:
        worker.progress.connect(on_progress)
    if on_finished is not None:
        worker.finished.connect(on_finished)
    if on_failed is not None:
        worker.failed.connect(on_failed)
    worker.finished.connect(thread.quit)
    worker.finished.connect(worker.deleteLater)
    thread.finished.connect(thread.deleteLater)
    thread.start()
    return thread, worker
