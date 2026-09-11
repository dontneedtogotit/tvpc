"""NVR Storage and Retention Manager for TVPC camera recordings.

Monitors recording directory disk usage and automatically purges oldest
recordings when disk usage exceeds configured quotas or retention age.
"""
from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .config import RECORD_DIR


def format_bytes(num_bytes: float) -> str:
    """Return human-readable byte size."""
    val = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if val < 1024.0:
            return f"{val:.1f} {unit}"
        val /= 1024.0
    return f"{val:.1f} PB"


class StorageManager:
    """Manages disk usage and retention for camera recordings."""

    def __init__(self, record_dir: Optional[Path] = None) -> None:
        self.record_dir = record_dir or RECORD_DIR

    def get_recordings(self) -> List[Path]:
        """Return all recording files sorted oldest to newest."""
        if not self.record_dir.exists():
            return []
        files = [
            f for f in self.record_dir.iterdir()
            if f.is_file() and f.suffix.lower() in (".mkv", ".mp4", ".ts", ".jpg", ".jpeg")
        ]
        return sorted(files, key=lambda p: p.stat().st_mtime)

    def get_storage_info(self) -> Dict[str, Any]:
        """Return usage stats for recordings and underlying filesystem."""
        self.record_dir.mkdir(parents=True, exist_ok=True)
        files = self.get_recordings()
        total_recordings_bytes = sum(f.stat().st_size for f in files)

        disk_total, disk_used, disk_free = shutil.disk_usage(self.record_dir)

        return {
            "record_dir": str(self.record_dir),
            "recording_count": len(files),
            "recordings_bytes": total_recordings_bytes,
            "recordings_display": format_bytes(total_recordings_bytes),
            "disk_total_bytes": disk_total,
            "disk_total_display": format_bytes(disk_total),
            "disk_used_bytes": disk_used,
            "disk_used_display": format_bytes(disk_used),
            "disk_free_bytes": disk_free,
            "disk_free_display": format_bytes(disk_free),
            "disk_free_percent": (disk_free / disk_total * 100.0) if disk_total else 0.0,
        }

    def enforce_retention(
        self,
        max_storage_gb: float = 20.0,
        max_retention_days: int = 14,
        min_free_space_gb: float = 5.0,
    ) -> Tuple[List[Path], int]:
        """Enforce retention limits by deleting the oldest recording files.

        Returns (deleted_paths, total_bytes_freed).
        """
        if not self.record_dir.exists():
            return ([], 0)

        now = time.time()
        files = self.get_recordings()
        if not files:
            return ([], 0)

        deleted: List[Path] = []
        bytes_freed = 0
        remaining_files = list(files)

        # 1. Purge recordings older than max_retention_days
        if max_retention_days > 0:
            cutoff = now - (max_retention_days * 86400.0)
            for f in list(remaining_files):
                try:
                    if f.stat().st_mtime < cutoff:
                        sz = f.stat().st_size
                        f.unlink()
                        deleted.append(f)
                        bytes_freed += sz
                        remaining_files.remove(f)
                except OSError:
                    pass

        # 2. Check total storage quota and disk free space
        max_bytes = max_storage_gb * (1024**3) if max_storage_gb > 0 else float("inf")
        min_free_bytes = min_free_space_gb * (1024**3) if min_free_space_gb > 0 else 0

        current_recordings_size = sum(f.stat().st_size for f in remaining_files)
        _, _, free_bytes = shutil.disk_usage(self.record_dir)

        # Purge oldest files until both size <= max_bytes AND free >= min_free_bytes
        for f in list(remaining_files):
            needs_purge = (current_recordings_size > max_bytes) or (free_bytes < min_free_bytes)
            if not needs_purge:
                break
            try:
                sz = f.stat().st_size
                f.unlink()
                deleted.append(f)
                bytes_freed += sz
                current_recordings_size -= sz
                free_bytes += sz
                remaining_files.remove(f)
            except OSError:
                pass

        return (deleted, bytes_freed)
