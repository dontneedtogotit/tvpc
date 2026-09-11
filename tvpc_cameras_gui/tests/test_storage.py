"""Unit tests for StorageManager and retention enforcement."""
from __future__ import annotations

import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from tvpc_cameras_gui.storage import StorageManager, format_bytes


class TestStorageManager(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.record_dir = Path(self.temp_dir.name)
        self.mgr = StorageManager(record_dir=self.record_dir)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_format_bytes(self) -> None:
        self.assertEqual(format_bytes(500), "500.0 B")
        self.assertEqual(format_bytes(1024), "1.0 KB")
        self.assertEqual(format_bytes(1024 * 1024), "1.0 MB")
        self.assertEqual(format_bytes(1024 * 1024 * 1024), "1.0 GB")

    def test_get_storage_info_empty(self) -> None:
        info = self.mgr.get_storage_info()
        self.assertEqual(info["recording_count"], 0)
        self.assertEqual(info["recordings_bytes"], 0)
        self.assertIn("disk_free_bytes", info)

    def test_enforce_retention_days(self) -> None:
        now = time.time()
        # Create an old file (20 days ago) and a fresh file (1 day ago)
        old_file = self.record_dir / "old_cam_20260801.mkv"
        old_file.write_bytes(b"X" * 1024)
        mtime_old = now - (20 * 86400)
        import os
        os.utime(old_file, (mtime_old, mtime_old))

        fresh_file = self.record_dir / "fresh_cam_20260910.mp4"
        fresh_file.write_bytes(b"Y" * 2048)
        mtime_fresh = now - (1 * 86400)
        os.utime(fresh_file, (mtime_fresh, mtime_fresh))

        deleted, freed = self.mgr.enforce_retention(
            max_storage_gb=100.0,
            max_retention_days=14,
            min_free_space_gb=0.1,
        )
        self.assertEqual(len(deleted), 1)
        self.assertEqual(deleted[0].name, "old_cam_20260801.mkv")
        self.assertEqual(freed, 1024)
        self.assertFalse(old_file.exists())
        self.assertTrue(fresh_file.exists())

    def test_enforce_storage_quota(self) -> None:
        now = time.time()
        # Create 3 files: 1MB each
        f1 = self.record_dir / "cam1.mkv"
        f1.write_bytes(b"A" * 10000)
        os.utime(f1, (now - 300, now - 300))

        f2 = self.record_dir / "cam2.mkv"
        f2.write_bytes(b"B" * 10000)
        os.utime(f2, (now - 200, now - 200))

        f3 = self.record_dir / "cam3.mkv"
        f3.write_bytes(b"C" * 10000)
        os.utime(f3, (now - 100, now - 100))

        # Max storage is set so that 30,000 bytes exceeds it (e.g. 0.000015 GB ~ 16,106 bytes)
        # Purging should delete f1 (oldest) then stop once <= max_storage_gb
        quota_gb = 15000.0 / (1024 ** 3)
        deleted, freed = self.mgr.enforce_retention(
            max_storage_gb=quota_gb,
            max_retention_days=999,
            min_free_space_gb=0.0,
        )
        # Should delete f1 and f2 until <= 15,000 bytes
        self.assertIn(f1, deleted)
        self.assertIn(f2, deleted)
        self.assertFalse(f1.exists())
        self.assertFalse(f2.exists())
        self.assertTrue(f3.exists())


if __name__ == "__main__":
    unittest.main()
