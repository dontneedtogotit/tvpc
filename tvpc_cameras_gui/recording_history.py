"""Recording history dialog."""
from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QVBoxLayout, QListWidget, QListWidgetItem,
    QPushButton, QHBoxLayout, QLabel, QMessageBox, QFileIconProvider,
)

from .config import RECORD_DIR


def _human_size(size: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


class RecordingHistoryDialog(QDialog):
    """Shows saved recordings and lets the user play, open, or delete them."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Recording History")
        self.setMinimumSize(600, 420)

        self._list = QListWidget()
        self._list.itemDoubleClicked.connect(self._play_selected)
        self._list.itemSelectionChanged.connect(self._update_btn_states)

        self._play_btn = QPushButton("▶  Play")
        self._play_btn.clicked.connect(self._play_selected)
        self._play_btn.setEnabled(False)

        self._open_btn = QPushButton("📂  Open folder")
        self._open_btn.clicked.connect(self._open_folder)

        self._delete_btn = QPushButton("🗑  Delete")
        self._delete_btn.clicked.connect(self._delete_selected)
        self._delete_btn.setEnabled(False)

        self._refresh_btn = QPushButton("⟳  Refresh")
        self._refresh_btn.clicked.connect(self._populate)

        buttons = QHBoxLayout()
        buttons.addWidget(self._play_btn)
        buttons.addWidget(self._open_btn)
        buttons.addWidget(self._delete_btn)
        buttons.addWidget(self._refresh_btn)
        buttons.addStretch(1)

        self._info = QLabel("")
        self._info.setStyleSheet("color: #888;")

        dlg_buttons = QDialogButtonBox(QDialogButtonBox.Close, parent=self)
        dlg_buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("<b>Saved recordings</b> (double-click to play)"))
        layout.addWidget(self._list, 1)
        layout.addLayout(buttons)
        layout.addWidget(self._info)
        layout.addWidget(dlg_buttons)

        self._populate()

    def _populate(self) -> None:
        self._list.clear()
        files = sorted(RECORD_DIR.glob("*.mkv"), key=lambda p: p.stat().st_mtime, reverse=True)
        total_size = 0
        for f in files:
            size = f.stat().st_size
            total_size += size
            import datetime
            ts = datetime.datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            item = QListWidgetItem(f"{f.name}  ({_human_size(size)}, {ts})")
            item.setData(Qt.UserRole, f)
            self._list.addItem(item)
        self._info.setText(f"{len(files)} recording(s), {_human_size(total_size)} total")

    def _update_btn_states(self) -> None:
        has_sel = self._selected_file() is not None
        self._play_btn.setEnabled(has_sel)
        self._delete_btn.setEnabled(has_sel)

    def _selected_file(self) -> Optional[Path]:
        item = self._list.currentItem()
        if item is None:
            return None
        return item.data(Qt.UserRole)

    def _play_selected(self) -> None:
        path = self._selected_file()
        if path is None or not path.exists():
            return
        import subprocess, shutil
        if shutil.which("mpv"):
            subprocess.Popen(["mpv", str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["xdg-open", str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _open_selected(self) -> None:
        self._play_selected()

    def _open_folder(self) -> None:
        import subprocess
        subprocess.Popen(["xdg-open", str(RECORD_DIR)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _delete_selected(self) -> None:
        path = self._selected_file()
        if path is None:
            return
        ok = QMessageBox.question(
            self, "Delete recording",
            f"Delete '{path.name}'?",
        )
        if ok == QMessageBox.Yes:
            try:
                path.unlink()
            except OSError as e:
                QMessageBox.warning(self, "Error", f"Could not delete: {e}")
                return
            self._populate()
