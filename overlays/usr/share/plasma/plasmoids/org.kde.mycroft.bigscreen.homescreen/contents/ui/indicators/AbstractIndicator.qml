/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

import QtQuick 2.14
import QtQuick.Layouts 1.14
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.kirigami 2.12 as Kirigami

PlasmaComponents.Button {
    id: button

    Layout.fillHeight: true
    Layout.preferredWidth: height

    leftPadding: 0
    topPadding: 0
    rightPadding: 0
    bottomPadding: 0

    background: Rectangle {
        anchors {
            fill: parent
            margins: Kirigami.Units.smallSpacing / 2
        }
        radius: height / 2
        color: button.activeFocus ? Qt.rgba(1.0, 1.0, 1.0, 0.22) : (button.hovered ? Qt.rgba(1.0, 1.0, 1.0, 0.10) : "transparent")
        border.color: button.activeFocus ? (typeof root !== "undefined" && root.theme ? root.theme.borderFocusColor : "#38bdf8") : "transparent"
        border.width: button.activeFocus ? 2 : 0

        Behavior on color {
            ColorAnimation { duration: 150 }
        }
    }

    contentItem: PlasmaCore.IconItem {
        id: icon
        source: button.icon.name
        colorGroup: PlasmaCore.ColorScope.colorGroup
    }

    Keys.onReturnPressed: {
        clicked();
    }
    Keys.onSelectPressed: {
        clicked();
    }

    onClicked: BigScreen.NavigationSoundEffects.playClickedSound()

    Keys.onPressed: {
        switch (event.key) {
            case Qt.Key_Down:
            case Qt.Key_Right:
            case Qt.Key_Left:
            case Qt.Key_Tab:
            case Qt.Key_Backtab:
                BigScreen.NavigationSoundEffects.playMovingSound();
                break;
            default:
                break;
        }
    }
}
