"""Tests for the venv_mgr module."""
from __future__ import annotations

import os
import shutil
import sys
import unittest
from pathlib import Path


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tvpc_cameras_gui import venv_mgr


class TestVenvMgrPaths(unittest.TestCase):
    """Test venv path functions."""

    def test_get_venv_path(self) -> None:
        path = venv_mgr.get_venv_path()
        self.assertIsInstance(path, Path)
        self.assertIn("tvpc-cameras-gui-venv", str(path))

    def test_get_venv_python(self) -> None:
        python_path = venv_mgr.get_venv_python()
        self.assertIsInstance(python_path, Path)
        if sys.platform == "win32":
            self.assertTrue(str(python_path).endswith("Scripts\\python.exe"))
        else:
            self.assertTrue(str(python_path).endswith("bin/python"))

    def test_get_venv_pip(self) -> None:
        pip_path = venv_mgr.get_venv_pip()
        self.assertIsInstance(pip_path, Path)
        if sys.platform == "win32":
            self.assertTrue(str(pip_path).endswith("Scripts\\pip.exe"))
        else:
            self.assertTrue(str(pip_path).endswith("bin/pip"))


class TestVenvMgrCreation(unittest.TestCase):
    """Test venv creation functions."""

    def setUp(self) -> None:
        self.test_venv_path = venv_mgr.get_venv_path()
        if self.test_venv_path.exists():
            shutil.rmtree(self.test_venv_path)

    def tearDown(self) -> None:
        if self.test_venv_path.exists():
            shutil.rmtree(self.test_venv_path)

    def test_venv_exists_false_when_not_created(self) -> None:
        self.assertFalse(venv_mgr.venv_exists())

    def test_create_venv(self) -> None:
        messages = []

        def capture(msg: str) -> None:
            messages.append(msg)

        success = venv_mgr.create_venv(progress=capture)
        self.assertTrue(success)
        self.assertTrue(venv_mgr.venv_exists())
        self.assertTrue(venv_mgr.get_venv_python().exists())
        self.assertTrue(venv_mgr.get_venv_pip().exists())
        self.assertTrue(any("Creating virtual environment" in m for m in messages))

    def test_ensure_venv_returns_true_after_create(self) -> None:
        success = venv_mgr.ensure_venv()
        self.assertTrue(success)
        self.assertTrue(venv_mgr.venv_exists())


class TestVenvMgrInstallation(unittest.TestCase):
    """Test package installation in venv."""

    def setUp(self) -> None:
        self.test_venv_path = venv_mgr.get_venv_path()
        if self.test_venv_path.exists():
            shutil.rmtree(self.test_venv_path)
        venv_mgr.create_venv()

    def tearDown(self) -> None:
        if self.test_venv_path.exists():
            shutil.rmtree(self.test_venv_path)

    def test_install_package(self) -> None:
        messages = []

        def capture(msg: str) -> None:
            messages.append(msg)

        success = venv_mgr.install_in_venv(["requests"], progress=capture)
        self.assertTrue(success)
        self.assertTrue(any("Installing packages" in m for m in messages))

    def test_install_multiple_packages(self) -> None:
        messages = []

        def capture(msg: str) -> None:
            messages.append(msg)

        success = venv_mgr.install_in_venv(["requests", "urllib3"], progress=capture)
        self.assertTrue(success)


class TestVenvMgrInfo(unittest.TestCase):
    """Test venv info functions."""

    def test_is_running_in_venv(self) -> None:
        result = venv_mgr.is_running_in_venv()
        self.assertIsInstance(result, bool)

    def test_get_venv_info(self) -> None:
        info = venv_mgr.get_venv_info()
        self.assertIsInstance(info, dict)
        self.assertIn("path", info)
        self.assertIn("python", info)
        self.assertIn("pip", info)
        self.assertIn("exists", info)
        self.assertIn("running_in_venv", info)


if __name__ == "__main__":
    unittest.main(verbosity=2)
