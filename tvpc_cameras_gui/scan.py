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
                 do_onvif_enrich: bool = True,
                 quick: bool = False,
                 mdns_timeout: float = 2.0,
                 mdns_retries: int = 1,
                 exclude_subnets: Optional[List[str]] = None,
                 include_subnets: Optional[List[str]] = None) -> None:
        super().__init__()
        self.user = user
        self.password = password
        self.cidr = cidr  # user-supplied CIDR; None = auto-detect
        self.workers = workers
        self.do_onvif_enrich = do_onvif_enrich
        self.quick = quick
        self.mdns_timeout = mdns_timeout
        self.mdns_retries = mdns_retries
        self.exclude_subnets = exclude_subnets or []
        self.include_subnets = include_subnets or []
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
                host_count = n.num_addresses - 2 if n.prefixlen < 31 else n.num_addresses
                self.progress.emit(f"Scanning {n} ({host_count} host{'s' if host_count != 1 else ''})")

            seen: Set[Tuple[str, str]] = set()
            results: List[disc.DiscoveredCamera] = []

            def _emit(cam: disc.DiscoveredCamera) -> None:
                # Ensure MAC is attached if known
                if not cam.mac and cam.host:
                    cam.mac = disc.get_mac_for_host(cam.host)
                # Ensure vendor is identified if MAC is known
                if cam.mac and (not cam.vendor or cam.vendor in ("ONVIF device", "HiSilicon (generic)", "generic")):
                    mac_v = disc.identify_vendor_from_mac(cam.mac)
                    if mac_v:
                        cam.vendor = mac_v
                # Ensure model is identified if available in ONVIF scopes or SSDP cache
                if not cam.model and cam.host:
                    scopes_info = disc.get_onvif_scopes_info(cam.host)
                    ssdp_info = disc.get_ssdp_info(cam.host)
                    cam.model = scopes_info.get("model", "") or ssdp_info.get("modelName", "") or ssdp_info.get("modelNumber", "")

                k = cam.key()
                if k in seen:
                    return
                seen.add(k)
                results.append(cam)
                self.found.emit(cam)

            # Check local video devices (USB webcams / capture cards)
            self.progress.emit("Checking local video devices (USB webcams / capture cards)...")
            try:
                for local_cam in disc.discover_local_devices():
                    _emit(local_cam)
            except Exception:
                pass

            if self.quick:
                self._quick_scan(nets, _emit)
            else:
                self._full_scan(nets, _emit)

            self.progress.emit(f"Done. {len(results)} unique camera(s) found.")
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(f"Scan error: {exc}")
        finally:
            self.finished.emit()

    # ------------------------------------------------------------------
    def _quick_scan(self, nets: List[ipaddress.IPv4Network], _emit) -> None:
        """Fast scan: ARP + SSDP/UPnP + mDNS + ONVIF only, no TCP sweep."""
        # 1) ARP table — filtered to target subnets.
        all_arp = disc.arp_hosts()
        arp = {
            h for h in all_arp
            if any(ipaddress.ip_address(h) in n for n in nets)
        }
        if arp:
            self.progress.emit(f"ARP table: {len(arp)} host(s) with a known MAC")
            # Probe known hosts in parallel on all camera ports (RTSP + HTTP)
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(self.workers, 16)
            ) as ex:
                futs = {
                    ex.submit(
                        disc.quick_probe_all_ports, host, self.user, self.password,
                    ): host
                    for host in arp
                }
                for fut in concurrent.futures.as_completed(futs):
                    if self._cancel:
                        return
                    for cam in fut.result():
                        _emit(cam)

        # 2) SSDP / UPnP multicast discovery
        if not self._cancel:
            self.progress.emit("SSDP/UPnP multicast discovery…")
            for c in disc.ssdp_discover(timeout=1.5):
                _emit(c)

        # 3) mDNS.
        mdns_ips: Set[str] = set()
        if not self._cancel:
            self.progress.emit("mDNS query (_rtsp / _onvif / _http)…")
            for c in disc.mdns_discover(
                timeout_per_service=self.mdns_timeout,
                retries=self.mdns_retries,
            ):
                _emit(c)
                if c.host:
                    mdns_ips.add(c.host)

            # Probe any resolved mDNS IPs that were not already in ARP
            new_hosts = mdns_ips - arp
            if new_hosts and not self._cancel:
                with concurrent.futures.ThreadPoolExecutor(
                    max_workers=min(self.workers, 16)
                ) as ex:
                    futs = {
                        ex.submit(
                            disc.quick_probe_all_ports, host, self.user, self.password,
                        ): host
                        for host in new_hosts
                    }
                    for fut in concurrent.futures.as_completed(futs):
                        if self._cancel:
                            return
                        for cam in fut.result():
                            _emit(cam)

        # 4) ONVIF WS-Discovery (fast multicast).
        if not self._cancel:
            self._onvif_phase(_emit)

    # ------------------------------------------------------------------
    def _full_scan(self, nets: List[ipaddress.IPv4Network], _emit) -> None:
        """Full scan: ARP + SSDP + mDNS + TCP sweep + ONVIF."""
        # 1) ARP table — filtered to target subnets.
        all_arp = disc.arp_hosts()
        arp = {
            h for h in all_arp
            if any(ipaddress.ip_address(h) in n for n in nets)
        }
        if arp:
            self.progress.emit(f"ARP table: {len(arp)} host(s) with a known MAC")
            # Probe known hosts immediately on all camera ports
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(self.workers, 16)
            ) as ex:
                futs = {
                    ex.submit(
                        disc.quick_probe_all_ports, host, self.user, self.password,
                    ): host
                    for host in arp
                }
                for fut in concurrent.futures.as_completed(futs):
                    if self._cancel:
                        return
                    for cam in fut.result():
                        _emit(cam)

        # 2) SSDP / UPnP multicast discovery
        if not self._cancel:
            self.progress.emit("SSDP/UPnP multicast discovery…")
            for c in disc.ssdp_discover(timeout=1.5):
                _emit(c)

        # 3) mDNS.
        mdns_ips: Set[str] = set()
        if not self._cancel:
            self.progress.emit("mDNS query (_rtsp / _onvif / _http)…")
            for c in disc.mdns_discover(
                timeout_per_service=self.mdns_timeout,
                retries=self.mdns_retries,
            ):
                _emit(c)
                if c.host:
                    mdns_ips.add(c.host)

        # 4) Parallel TCP sweep, all subnets, all ports.
        if not self._cancel:
            self._sweep_and_probe(nets, _emit, extra_hosts=mdns_ips)

        # 5) ONVIF WS-Discovery + enrichment.
        if not self._cancel:
            self._onvif_phase(_emit)

    # ------------------------------------------------------------------
    def _resolve_subnets(self) -> List[ipaddress.IPv4Network]:
        if self.cidr:
            net = disc.parse_cidr_or_subnet(self.cidr)
            if net is not None:
                return [net]
        nets = disc.all_local_subnets()
        # Apply whitelist/blacklist.
        if self.include_subnets:
            inc = set()
            for s in self.include_subnets:
                n = disc.parse_cidr_or_subnet(s)
                if n:
                    inc.add(n)
            nets = [n for n in nets if n in inc]
        filtered: List[ipaddress.IPv4Network] = []
        for n in nets:
            skip = False
            for ex in self.exclude_subnets:
                en = disc.parse_cidr_or_subnet(ex)
                if en and (n.subnet_of(en) or en.subnet_of(n)):
                    skip = True
                    break
            if not skip:
                filtered.append(n)
        return filtered

    # ------------------------------------------------------------------
    def _sweep_and_probe(self,
                         nets: List[ipaddress.IPv4Network],
                         _emit,
                         extra_hosts: Optional[Set[str]] = None) -> None:
        # All hosts, deduplicated.
        all_hosts: Set[str] = set()
        for n in nets:
            for h in disc.hosts_in(n):
                all_hosts.add(h)
        for h in disc.arp_hosts():
            try:
                if any(ipaddress.ip_address(h) in n for n in nets):
                    all_hosts.add(h)
            except ValueError:
                pass
        if extra_hosts:
            all_hosts.update(extra_hosts)
        if not all_hosts:
            return

        # Parallel TCP probe on every interesting port.
        open_map: dict = {}  # port -> set(hosts)
        for port in (*disc.RTSP_PORTS, *disc.HTTP_PORTS, *disc.TUYA_PORTS, *disc.DVR_PORTS):
            if self._cancel:
                return
            self.progress.emit(f"  TCP/{port} sweep ({len(all_hosts)} hosts)…")
            hits = disc.parallel_tcp_open(
                all_hosts, port, timeout=0.6, workers=self.workers,
            )
            if hits:
                self.progress.emit(f"    {len(hits)} host(s) responded on TCP/{port}")
                open_map[port] = set(hits)

        # Hosts that had ANY port open.
        any_open: Set[str] = set()
        for s in open_map.values():
            any_open |= s

        found_stream_hosts: Set[str] = set()

        # DVR / NVR probe: check hosts with DVR ports or RTSP ports open
        dvr_candidates: Set[str] = set()
        for p in (*disc.DVR_PORTS, *disc.RTSP_PORTS):
            dvr_candidates |= open_map.get(p, set())

        dvr_hosts: Set[str] = set()
        if dvr_candidates and not self._cancel:
            self.progress.emit(f"  DVR / NVR probe on {len(dvr_candidates)} host(s)…")
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(self.workers, 16)
            ) as ex:
                futs = {
                    ex.submit(
                        disc.detect_dvr_channels,
                        host,
                        user=self.user,
                        password=self.password,
                        open_ports={p for p in open_map if host in open_map[p]},
                    ): host
                    for host in dvr_candidates
                }
                for fut in concurrent.futures.as_completed(futs):
                    if self._cancel:
                        return
                    cams = fut.result()
                    if cams:
                        host = futs[fut]
                        dvr_hosts.add(host)
                        found_stream_hosts.add(host)
                        v_name = cams[0].vendor or cams[0].dvr_type or "DVR"
                        self.progress.emit(f"    Found {v_name} with {len(cams)} camera(s) at {host}")
                        for cam in cams:
                            _emit(cam)

        # RTSP DESCRIBE on hosts that have any RTSP port open and were not already handled as DVRs.
        rtsp_candidates: Set[str] = set()
        for p in disc.RTSP_PORTS:
            rtsp_candidates |= (open_map.get(p, set()) - dvr_hosts)
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
                        found_stream_hosts.add(cam.host)
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
                        found_stream_hosts.add(cam.host)
                        _emit(cam)

        # Cloud-only Tuya detection: report hosts where Tuya port (6668) is open
        # but no local RTSP/HTTP stream was found.
        # We do NOT report arbitrary ping-responsive hosts as cameras.
        tuya_candidates: Set[str] = set()
        for p in disc.TUYA_PORTS:
            tuya_candidates |= open_map.get(p, set())
        for host in tuya_candidates:
            if self._cancel:
                return
            mac = disc.get_mac_for_host(host)
            vendor = disc.identify_vendor_from_mac(mac) if mac else ""
            if not vendor:
                vendor = "Orion / Tuya / Grid Connect"
            _emit(disc.DiscoveredCamera(
                host=host,
                url="",            # no stream URL yet
                method="cloud",
                vendor=vendor,
                mac=mac,
                note=(
                    f"Cloud-only ({vendor}, port 6668 detected). "
                    "Enable ONVIF/PC View in vendor app and re-scan. Click '💡 Setup Guide' for help."
                ),
            ))

    # ------------------------------------------------------------------
    def _onvif_phase(self, _emit) -> None:
        from urllib.parse import urlparse
        self.progress.emit("ONVIF WS-Discovery multicast…")
        xaddrs = disc.onvif_ws_discovery()
        if not xaddrs:
            return
        self.progress.emit(f"  {len(xaddrs)} XAddr(s) responded")
        for xaddr in xaddrs:
            if self._cancel:
                return
            p = urlparse(xaddr)
            host = p.hostname or ""
            scopes_info = disc.get_onvif_scopes_info(xaddr)
            v_name = scopes_info.get("vendor", "")
            m_name = scopes_info.get("model", "")
            # WS-Discovery gives us the XAddr, not a stream URL. We
            # emit it as a candidate (method=onvif) AND, if creds work,
            # enrich it with GetDeviceInformation + GetProfiles +
            # GetStreamUri and emit those as proper RTSP URLs.
            _emit(disc.DiscoveredCamera(
                host=host, url=xaddr, method="onvif", vendor=v_name, model=m_name, note="WS-Discovery XAddr",
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
            video_sources = disc.onvif_get_video_sources(
                xaddr, user=self.user, password=self.password,
            )
            is_nvr = (
                len(video_sources) > 1 or
                any(k in (vendor + " " + model).upper() for k in ("NVR", "DVR", "RECORDER", "DS-7", "XVR", "HCVR"))
            )
            profiles = disc.onvif_get_profiles(
                xaddr, user=self.user, password=self.password,
            )
            ch_idx = 0
            for prof in profiles:
                uri = disc.onvif_get_stream_uri(
                    xaddr, prof["token"],
                    user=self.user, password=self.password,
                )
                if not uri:
                    continue
                ch_idx += 1
                uri_p = urlparse(uri)
                uri_host = uri_p.hostname or host
                is_dvr_stream = is_nvr or (len(profiles) > 2 and len(video_sources) > 1)
                method = "dvr" if is_dvr_stream else "rtsp"
                prof_name = prof.get('name', prof['token'])
                note_str = f"DVR Channel {ch_idx} ({prof_name})" if is_dvr_stream else f"ONVIF profile {prof_name}"
                _emit(disc.DiscoveredCamera(
                    host=uri_host, url=uri, method=method,
                    vendor=vendor, model=model, firmware=firmware,
                    note=note_str,
                    is_dvr=is_dvr_stream,
                    channel=ch_idx if is_dvr_stream else 0,
                    total_channels=len(profiles) if is_dvr_stream else 0,
                    dvr_type=f"{vendor} {len(profiles)}-Channel NVR" if is_dvr_stream else "",
                ))


def start_scan(parent,
                user: str = "",
                password: str = "",
                cidr: Optional[str] = None,
                on_found=None,
                on_progress=None,
                on_finished=None,
                on_failed=None,
                quick: bool = False,
                mdns_timeout: float = 2.0,
                mdns_retries: int = 1,
                exclude_subnets: Optional[List[str]] = None,
                include_subnets: Optional[List[str]] = None) -> Tuple[QThread, "ScanWorker"]:
    """Convenience helper: start a scan on a new QThread."""
    thread = QThread(parent)
    worker = ScanWorker(
        user=user, password=password, cidr=cidr, quick=quick,
        mdns_timeout=mdns_timeout, mdns_retries=mdns_retries,
        exclude_subnets=exclude_subnets, include_subnets=include_subnets,
    )
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
