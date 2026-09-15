from __future__ import annotations

import io
import os
import tarfile
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from tvpc_cameras_gui import updater


def test_get_installed_version_from_file(tmp_path: Path):
    version_file = tmp_path / ".version"
    version_file.write_text("abcdef1234567890abcdef1234567890abcdef12\n")
    assert updater.get_installed_version(tmp_path) == "abcdef1234567890abcdef1234567890abcdef12"


def test_get_installed_version_missing(tmp_path: Path):
    assert updater.get_installed_version(tmp_path) is None


def test_get_remote_version_git_success():
    mock_res = MagicMock()
    mock_res.returncode = 0
    mock_res.stdout = "1234567890123456789012345678901234567890\trefs/heads/main\n"

    with patch("subprocess.run", return_value=mock_res):
        ver = updater.get_remote_version(timeout=1.0)
        assert ver == "1234567890123456789012345678901234567890"


def test_get_remote_version_fallback_api():
    mock_git = MagicMock()
    mock_git.returncode = 1
    mock_git.stdout = ""

    mock_resp = MagicMock()
    mock_resp.status = 200
    mock_resp.read.return_value = b'{"sha": "0987654321098765432109876543210987654321"}'
    mock_resp.__enter__.return_value = mock_resp

    with patch("subprocess.run", return_value=mock_git), \
         patch("urllib.request.urlopen", return_value=mock_resp):
        ver = updater.get_remote_version(timeout=1.0)
        assert ver == "0987654321098765432109876543210987654321"


def test_check_for_update_no_remote():
    with patch.object(updater, "get_remote_version", return_value=None):
        has_update, curr, remote = updater.check_for_update()
        assert has_update is False
        assert remote is None


def test_check_for_update_same_version():
    sha = "1111222233334444555566667777888899990000"
    with patch.object(updater, "get_installed_version", return_value=sha), \
         patch.object(updater, "get_remote_version", return_value=sha):
        has_update, curr, remote = updater.check_for_update()
        assert has_update is False
        assert curr == sha
        assert remote == sha


def test_check_for_update_newer_version():
    sha1 = "1111222233334444555566667777888899990000"
    sha2 = "9999888877776666555544443333222211110000"
    with patch.object(updater, "get_installed_version", return_value=sha1), \
         patch.object(updater, "get_remote_version", return_value=sha2):
        has_update, curr, remote = updater.check_for_update()
        assert has_update is True
        assert curr == sha1
        assert remote == sha2


def test_check_and_apply_update_disabled_by_env():
    with patch.dict(os.environ, {"TVPC_NO_UPDATE": "1"}), \
         patch.object(updater, "check_for_update") as mock_check:
        res = updater.check_and_apply_update()
        assert res is False
        mock_check.assert_not_called()


def test_ensure_wrapper_script(tmp_path: Path):
    bin_file = tmp_path / "bin" / "tvpc-cameras-gui"
    app_dir = tmp_path / "share" / "tvpc-cameras-gui"
    updater._ensure_wrapper_script(bin_file, app_dir)

    assert bin_file.is_file()
    assert os.access(bin_file, os.X_OK)
    content = bin_file.read_text()
    assert f'APP_DIR="{app_dir}"' in content
    assert 'export PYTHONPATH="${APP_DIR}:${PYTHONPATH:-}"' in content


def test_ensure_desktop_entry(tmp_path: Path):
    desktop_file = tmp_path / "applications" / "tvpc-cameras-gui.desktop"
    updater._ensure_desktop_entry(desktop_file)

    assert desktop_file.is_file()
    content = desktop_file.read_text()
    assert "Exec=tvpc-cameras-gui" in content
    assert "Icon=camera-web" in content


def test_apply_update_standalone_tarball(tmp_path: Path):
    install_dir = tmp_path / "install"
    install_dir.mkdir()
    new_sha = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

    # Create a fake archive tarball containing tvpc_cameras_gui/__init__.py
    tar_stream = io.BytesIO()
    with tarfile.open(fileobj=tar_stream, mode="w:gz") as tar:
        pkg_content = b'# Updated pkg\n'
        ti = tarfile.TarInfo(name="tvpc-main/tvpc_cameras_gui/__init__.py")
        ti.size = len(pkg_content)
        tar.addfile(ti, io.BytesIO(pkg_content))

    tar_bytes = tar_stream.getvalue()

    class FakeResp:
        def __init__(self, data):
            self.data = io.BytesIO(data)
        def read(self, *args):
            return self.data.read(*args)
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass

    with patch("urllib.request.urlopen", return_value=FakeResp(tar_bytes)):
        ok = updater.apply_update(new_sha, install_dir=install_dir)
        assert ok is True
        assert (install_dir / ".version").read_text().strip() == new_sha
        assert (install_dir / "tvpc_cameras_gui" / "__init__.py").read_bytes() == b'# Updated pkg\n'
