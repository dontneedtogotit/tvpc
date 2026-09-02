"""First-run wizard for the camera GUI.

A QWizard that walks a new user through:
  1. Welcome
  2. Dependency check (with one-click install)
  3. Default credentials (optional)
  4. Finish
"""
from __future__ import annotations

from typing import List, Optional

from PySide6.QtCore import Qt, QTimer, QProcess, Signal, Slot
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (
    QWizard, QWizardPage, QLabel, QVBoxLayout, QHBoxLayout, QProgressBar,
    QPushButton, QLineEdit, QCheckBox, QTextEdit, QMessageBox, QGridLayout,
    QGroupBox, QStyle,
)

from . import deps as deps_mod


class WelcomePage(QWizardPage):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setTitle("Welcome")
        self.setSubTitle("Let's get your security cameras set up.")

        text = QLabel(
            "This app lets you discover, configure, and view IP security "
            "cameras on your network as picture-in-picture windows.\n\n"
            "Before we start, let's make sure everything is installed."
        )
        text.setWordWrap(True)

        layout = QVBoxLayout()
        layout.addWidget(text)
        layout.addStretch(1)
        self.setLayout(layout)


class DependenciesPage(QWizardPage):
    """Checks for required software and offers to install what's missing."""

    install_finished = Signal(bool, str)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setTitle("Checking dependencies")
        self.setSubTitle("Making sure the required software is installed.")

        self._report = deps_mod.check_dependencies()
        self._installing = False
        self._process: Optional[QProcess] = None

        self._grid = QGridLayout()
        self._status_labels: List[QLabel] = []
        self._check_rows()

        self._detail = QTextEdit()
        self._detail.setReadOnly(True)
        self._detail.setFixedHeight(100)
        self._detail.setVisible(False)

        self._install_btn = QPushButton("Install missing dependencies")
        self._install_btn.clicked.connect(self._start_install)
        self._install_btn.setVisible(not self._report.all_found)

        self._progress = QProgressBar()
        self._progress.setVisible(False)

        layout = QVBoxLayout()
        layout.addLayout(self._grid)
        layout.addWidget(self._install_btn)
        layout.addWidget(self._progress)
        layout.addWidget(self._detail)
        layout.addStretch(1)
        self.setLayout(layout)

        self.install_finished.connect(self._on_install_finished)

    def _check_rows(self) -> None:
        header_name = QLabel("<b>Component</b>")
        header_status = QLabel("<b>Status</b>")
        self._grid.addWidget(header_name, 0, 0)
        self._grid.addWidget(header_status, 0, 1)

        for i, dep in enumerate(self._report.dependencies):
            row = i + 1
            name_lbl = QLabel(f"{dep.name}\n<span style='color:#888'>{dep.purpose}</span>")
            name_lbl.setWordWrap(True)

            icon = "✅" if dep.found else "❌"
            status_lbl = QLabel(f"{icon} {'Found' if dep.found else 'Not found'}")
            if dep.found and dep.path:
                status_lbl.setToolTip(dep.path)

            self._grid.addWidget(name_lbl, row, 0)
            self._grid.addWidget(status_lbl, row, 1)
            self._status_labels.append(status_lbl)

    def isComplete(self) -> bool:  # noqa: N802
        return self._report.all_found and not self._installing

    def _start_install(self) -> None:
        if self._installing:
            return
        missing = self._report.missing
        if not missing:
            return

        base_cmd = deps_mod.build_install_command(missing)
        if not base_cmd:
            QMessageBox.warning(
                self, "Cannot install",
                "No supported package manager found on this system.\n"
                "Please install ffmpeg, mpv, and PySide6 manually.",
            )
            return

        # Wrap in pkexec / sudo if we're not root.
        if os_geteuid() != 0:
            cmd = deps_mod.build_privileged_command(base_cmd)
            if cmd is None:
                QMessageBox.warning(
                    self, "Cannot install",
                    "This tool needs administrator access to install packages.\n"
                    "Please run this installer as root, or install manually:\n\n"
                    f"  sudo {base_cmd}",
                )
                return
        else:
            cmd = base_cmd

        self._installing = True
        self._install_btn.setEnabled(False)
        self._progress.setVisible(True)
        self._progress.setRange(0, 0)  # indeterminate
        self._detail.setVisible(True)
        self._detail.clear()
        self._detail.append(f"$ {cmd}\n")
        self._update_complete()

        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.MergedChannels)
        self._process.readyRead.connect(self._on_ready_read)
        self._process.finished.connect(self._on_process_finished)
        self._process.start("bash", ["-c", cmd])

    def _on_ready_read(self) -> None:
        if self._process is None:
            return
        data = bytes(self._process.readAll()).decode("utf-8", "replace")
        self._detail.append(data)
        # Auto-scroll to bottom.
        bar = self._detail.verticalScrollBar()
        if bar is not None:
            bar.setValue(bar.maximum())

    def _on_process_finished(self, exit_code: int, exit_status) -> None:  # noqa: ANN001
        ok = exit_code == 0 and exit_status == QProcess.NormalExit
        msg = "Installation complete." if ok else f"Installation failed (exit code {exit_code})."
        self._detail.append(f"\n{msg}")
        self.install_finished.emit(ok, msg)

    @Slot(bool, str)
    def _on_install_finished(self, ok: bool, msg: str) -> None:
        self._installing = False
        self._progress.setVisible(False)
        self._install_btn.setEnabled(True)

        # Re-check dependencies.
        self._report = deps_mod.check_dependencies()
        for i, dep in enumerate(self._report.dependencies):
            if i < len(self._status_labels):
                icon = "✅" if dep.found else "❌"
                text = f"{icon} {'Found' if dep.found else 'Not found'}"
                self._status_labels[i].setText(text)
                if dep.found and dep.path:
                    self._status_labels[i].setToolTip(dep.path)

        if self._report.all_found:
            self._install_btn.setVisible(False)
            self._detail.append("\nAll dependencies are installed. Click Next to continue.")
        else:
            self._detail.append(
                "\nSome dependencies are still missing. You can try again "
                "or install them manually."
            )
        self._update_complete()

    def _update_complete(self) -> None:
        self.completeChanged.emit()


# Import here to avoid pulling in os at module level for the type checker.
import os as _os
os_geteuid = _os.geteuid


class CredentialsPage(QWizardPage):
    """Optional: set default credentials for cameras."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setTitle("Default credentials (optional)")
        self.setSubTitle(
            "If your cameras all use the same username and password, "
            "enter them here. You can change them per-camera later."
        )

        self._user = QLineEdit()
        self._user.setPlaceholderText("Username (e.g. admin)")
        self._pass = QLineEdit()
        self._pass.setEchoMode(QLineEdit.Password)
        self._pass.setPlaceholderText("Password")
        self._show_pass = QCheckBox("Show password")
        self._show_pass.toggled.connect(
            lambda on: self._pass.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password)
        )

        note = QLabel(
            "Leave blank if your cameras don't use credentials, or if "
            "they each have different ones."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")

        layout = QVBoxLayout()
        layout.addWidget(QLabel("Username:"))
        layout.addWidget(self._user)
        layout.addWidget(QLabel("Password:"))
        layout.addWidget(self._pass)
        layout.addWidget(self._show_pass)
        layout.addSpacing(12)
        layout.addWidget(note)
        layout.addStretch(1)
        self.setLayout(layout)

    def get_credentials(self) -> tuple[str, str]:
        return self._user.text().strip(), self._pass.text()


class FinishPage(QWizardPage):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setTitle("You're ready!")
        self.setSubTitle("Click Finish to open the camera manager.")

        text = QLabel(
            "All set. You can now:\n\n"
            "  • Scan your network for cameras\n"
            "  • Add cameras manually if you know their URL\n"
            "  • Open picture-in-picture windows for live viewing\n\n"
            "If you get stuck, the README in the tvpc repository has "
            "detailed documentation."
        )
        text.setWordWrap(True)

        layout = QVBoxLayout()
        layout.addWidget(text)
        layout.addStretch(1)
        self.setLayout(layout)


def run_first_run_wizard(parent=None) -> tuple[bool, tuple[str, str]]:
    """Run the first-run wizard.

    Returns (accepted, (username, password)). If the user cancels,
    returns (False, ("", "")).
    """
    wizard = QWizard(parent)
    wizard.setWindowTitle("tvpc Cameras — Setup")
    wizard.setWizardStyle(QWizard.ModernStyle)
    wizard.setMinimumSize(560, 420)

    wizard.addPage(WelcomePage())
    deps_page = DependenciesPage()
    wizard.addPage(deps_page)
    creds_page = CredentialsPage()
    wizard.addPage(creds_page)
    wizard.addPage(FinishPage())

    result = wizard.exec()
    if result == QWizard.Accepted:
        return True, creds_page.get_credentials()
    return False, ("", "")
