/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import QtQuick.Window 2.14
import org.kde.kirigami 2.12 as Kirigami

QtObject {
    id: themeRoot

    // Active theme name: "estuary" (default Kodi/LibreELEC), "midnight", "oled", "cyberpunk", "sunset", "emerald"
    property string activeThemeName: "estuary"

    // Core color tokens
    property color backgroundColor: currentPalette.background
    property color backgroundEndColor: currentPalette.backgroundEnd
    property color surfaceColor: currentPalette.surface
    property color surfaceHoverColor: currentPalette.surfaceHover
    property color surfaceFocusedColor: currentPalette.surfaceFocused
    
    property color borderColor: currentPalette.border
    property color borderFocusColor: currentPalette.borderFocus
    
    property color accentColor: currentPalette.accent
    property color accentSecondaryColor: currentPalette.accentSecondary
    property color accentGlowColor: currentPalette.accentGlow
    
    property color textColor: currentPalette.text
    property color textMutedColor: currentPalette.textMuted
    property color textDimmedColor: currentPalette.textDimmed
    
    property color topBarBackground: currentPalette.topBarBg
    property color topBarBorder: currentPalette.topBarBorder
    property color pillBackground: currentPalette.pillBg
    property color pillBorder: currentPalette.pillBorder
    property color pillFocusedBackground: currentPalette.pillFocusedBg

    // Dimensions and metrics for 10-foot TV viewing
    property int cardRadius: 16
    property int pillRadius: 24
    property int badgeRadius: 6
    property int focusBorderWidth: 3
    property real focusedCardScale: 1.07
    property int animDurationFast: 120
    property int animDurationNormal: 220
    property int animDurationSlow: 350

    // Theme definitions
    readonly property var palettes: ({
        "estuary": {
            name: "Estuary (LibreELEC)",
            background: "#0c131d",
            backgroundEnd: "#070a10",
            surface: Qt.rgba(0.07, 0.13, 0.22, 0.75),
            surfaceHover: Qt.rgba(0.11, 0.20, 0.32, 0.88),
            surfaceFocused: Qt.rgba(0.14, 0.24, 0.38, 0.98),
            border: Qt.rgba(0.0, 0.82, 1.0, 0.16),
            borderFocus: "#00d2ff", // Electric Kodi / LibreELEC Cyan
            accent: "#00d2ff",
            accentSecondary: "#00b4d8",
            accentGlow: Qt.rgba(0.0, 0.82, 1.0, 0.45),
            text: "#f1f5f9",
            textMuted: "#94a3b8",
            textDimmed: "#64748b",
            topBarBg: Qt.rgba(0.05, 0.09, 0.15, 0.85),
            topBarBorder: Qt.rgba(0.0, 0.82, 1.0, 0.12),
            pillBg: Qt.rgba(0.0, 0.82, 1.0, 0.09),
            pillBorder: Qt.rgba(0.0, 0.82, 1.0, 0.18),
            pillFocusedBg: Qt.rgba(0.0, 0.82, 1.0, 0.28)
        },
        "midnight": {
            name: "Midnight Glass",
            background: "#0a0e17",
            backgroundEnd: "#111827",
            surface: Qt.rgba(0.09, 0.13, 0.22, 0.65),
            surfaceHover: Qt.rgba(0.14, 0.20, 0.32, 0.85),
            surfaceFocused: Qt.rgba(0.16, 0.24, 0.38, 0.95),
            border: Qt.rgba(1.0, 1.0, 1.0, 0.12),
            borderFocus: "#38bdf8", // Sky / Cyan
            accent: "#0ea5e9",
            accentSecondary: "#38bdf8",
            accentGlow: Qt.rgba(0.22, 0.74, 0.97, 0.40),
            text: "#f8fafc",
            textMuted: "#94a3b8",
            textDimmed: "#64748b",
            topBarBg: Qt.rgba(0.04, 0.06, 0.10, 0.75),
            topBarBorder: Qt.rgba(1.0, 1.0, 1.0, 0.08),
            pillBg: Qt.rgba(1.0, 1.0, 1.0, 0.08),
            pillBorder: Qt.rgba(1.0, 1.0, 1.0, 0.12),
            pillFocusedBg: Qt.rgba(0.22, 0.74, 0.97, 0.25)
        },
        "oled": {
            name: "OLED Stealth",
            background: "#000000",
            backgroundEnd: "#080808",
            surface: Qt.rgba(0.08, 0.08, 0.08, 0.85),
            surfaceHover: Qt.rgba(0.14, 0.14, 0.14, 0.95),
            surfaceFocused: Qt.rgba(0.18, 0.18, 0.18, 1.0),
            border: Qt.rgba(1.0, 1.0, 1.0, 0.16),
            borderFocus: "#ffffff",
            accent: "#f3f4f6",
            accentSecondary: "#d1d5db",
            accentGlow: Qt.rgba(1.0, 1.0, 1.0, 0.35),
            text: "#ffffff",
            textMuted: "#a1a1aa",
            textDimmed: "#71717a",
            topBarBg: Qt.rgba(0.0, 0.0, 0.0, 0.88),
            topBarBorder: Qt.rgba(1.0, 1.0, 1.0, 0.10),
            pillBg: Qt.rgba(1.0, 1.0, 1.0, 0.09),
            pillBorder: Qt.rgba(1.0, 1.0, 1.0, 0.18),
            pillFocusedBg: Qt.rgba(1.0, 1.0, 1.0, 0.25)
        },
        "cyberpunk": {
            name: "Cyberpunk Neon",
            background: "#090514",
            backgroundEnd: "#160b29",
            surface: Qt.rgba(0.13, 0.07, 0.24, 0.72),
            surfaceHover: Qt.rgba(0.20, 0.11, 0.36, 0.88),
            surfaceFocused: Qt.rgba(0.25, 0.13, 0.44, 0.98),
            border: Qt.rgba(0.96, 0.25, 0.58, 0.28),
            borderFocus: "#f43f5e", // Hot magenta
            accent: "#f43f5e",
            accentSecondary: "#06b6d4", // Electric cyan
            accentGlow: Qt.rgba(0.96, 0.25, 0.58, 0.50),
            text: "#fdf4ff",
            textMuted: "#c084fc",
            textDimmed: "#9333ea",
            topBarBg: Qt.rgba(0.04, 0.02, 0.09, 0.82),
            topBarBorder: Qt.rgba(0.96, 0.25, 0.58, 0.20),
            pillBg: Qt.rgba(0.96, 0.25, 0.58, 0.10),
            pillBorder: Qt.rgba(0.96, 0.25, 0.58, 0.24),
            pillFocusedBg: Qt.rgba(0.96, 0.25, 0.58, 0.30)
        },
        "sunset": {
            name: "Sunset Amber",
            background: "#140c0a",
            backgroundEnd: "#23130e",
            surface: Qt.rgba(0.18, 0.10, 0.08, 0.72),
            surfaceHover: Qt.rgba(0.26, 0.14, 0.11, 0.88),
            surfaceFocused: Qt.rgba(0.32, 0.17, 0.13, 0.98),
            border: Qt.rgba(0.98, 0.57, 0.23, 0.22),
            borderFocus: "#f59e0b", // Warm amber
            accent: "#f97316",
            accentSecondary: "#f59e0b",
            accentGlow: Qt.rgba(0.96, 0.62, 0.04, 0.45),
            text: "#fff7ed",
            textMuted: "#fdba74",
            textDimmed: "#fb923c",
            topBarBg: Qt.rgba(0.08, 0.04, 0.03, 0.82),
            topBarBorder: Qt.rgba(0.98, 0.57, 0.23, 0.18),
            pillBg: Qt.rgba(0.98, 0.57, 0.23, 0.10),
            pillBorder: Qt.rgba(0.98, 0.57, 0.23, 0.22),
            pillFocusedBg: Qt.rgba(0.96, 0.62, 0.04, 0.28)
        },
        "emerald": {
            name: "Emerald Pine",
            background: "#06140f",
            backgroundEnd: "#0a2119",
            surface: Qt.rgba(0.06, 0.18, 0.13, 0.72),
            surfaceHover: Qt.rgba(0.09, 0.26, 0.19, 0.88),
            surfaceFocused: Qt.rgba(0.12, 0.33, 0.24, 0.98),
            border: Qt.rgba(0.20, 0.83, 0.60, 0.20),
            borderFocus: "#10b981", // Emerald
            accent: "#34d399",
            accentSecondary: "#10b981",
            accentGlow: Qt.rgba(0.06, 0.73, 0.51, 0.45),
            text: "#ecfdf5",
            textMuted: "#6ee7b7",
            textDimmed: "#34d399",
            topBarBg: Qt.rgba(0.02, 0.08, 0.06, 0.82),
            topBarBorder: Qt.rgba(0.20, 0.83, 0.60, 0.18),
            pillBg: Qt.rgba(0.20, 0.83, 0.60, 0.09),
            pillBorder: Qt.rgba(0.20, 0.83, 0.60, 0.22),
            pillFocusedBg: Qt.rgba(0.06, 0.73, 0.51, 0.28)
        }
    })

    readonly property var currentPalette: palettes[activeThemeName] || palettes["estuary"] || palettes["midnight"]

    Component.onCompleted: {
        loadConfig()
    }

    function loadConfig() {
        var paths = [
            "/etc/tvpc/bigscreen-theme.json"
        ];
        
        for (var i = 0; i < paths.length; i++) {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "file://" + paths[i], false);
            try {
                xhr.send();
                if (xhr.status === 200 || xhr.status === 0) {
                    var data = JSON.parse(xhr.responseText);
                    if (data && data.theme && palettes[data.theme]) {
                        activeThemeName = data.theme;
                        return;
                    }
                }
            } catch (e) {
                // Ignore file read error and continue with default
            }
        }
    }
}
