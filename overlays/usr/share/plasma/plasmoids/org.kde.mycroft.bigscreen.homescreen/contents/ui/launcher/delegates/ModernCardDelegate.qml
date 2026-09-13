/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import QtQuick.Layouts 1.14
import QtGraphicalEffects 1.14
import QtQuick.Controls 2.14 as Controls
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.kirigami 2.13 as Kirigami
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import "../.." as RootUI

Item {
    id: cardRoot

    // Public properties
    property var iconSource
    property string title: ""
    property string subtitle: ""
    property string category: ""
    property string comment: ""
    property bool isCurrent: {
        var parentFlickable = findFlickable(parent);
        if (parentFlickable) {
            return parentFlickable.currentIndex === index && activeFocus && !parentFlickable.moving;
        }
        return activeFocus;
    }

    signal clicked()

    function findFlickable(item) {
        var curr = item;
        while (curr) {
            if (curr instanceof Flickable) {
                return curr;
            }
            curr = curr.parent;
        }
        return null;
    }

    // Reference theme
    property var theme: (typeof root !== "undefined" && root.theme) ? root.theme : fallbackTheme
    RootUI.Theme { id: fallbackTheme }

    // Dimensions derived from parent cell or grid
    implicitWidth: {
        var fl = findFlickable(parent);
        return fl && fl.cellWidth ? fl.cellWidth : Kirigami.Units.gridUnit * 12;
    }
    implicitHeight: {
        var fl = findFlickable(parent);
        return fl && fl.cellHeight ? fl.cellHeight : Kirigami.Units.gridUnit * 9;
    }

    z: isCurrent ? 10 : 1
    scale: isCurrent ? theme.focusedCardScale : 1.0
    opacity: isCurrent ? 1.0 : 0.88

    Behavior on scale {
        NumberAnimation {
            duration: theme.animDurationFast
            easing.type: Easing.OutCubic
        }
    }
    Behavior on opacity {
        NumberAnimation {
            duration: theme.animDurationFast
            easing.type: Easing.OutQuad
        }
    }

    // Outer glow when focused
    RectangularGlow {
        id: focusGlow
        anchors.fill: cardBackground
        glowRadius: 18
        spread: 0.25
        color: cardRoot.theme.accentGlowColor
        cornerRadius: cardRoot.theme.cardRadius + 4
        visible: cardRoot.isCurrent
        opacity: cardRoot.isCurrent ? 1.0 : 0.0

        Behavior on opacity {
            NumberAnimation {
                duration: cardRoot.theme.animDurationFast
                easing.type: Easing.OutQuad
            }
        }
    }

    // Card background
    Rectangle {
        id: cardBackground
        anchors {
            fill: parent
            margins: Kirigami.Units.smallSpacing
        }
        radius: cardRoot.theme.cardRadius
        color: cardRoot.isCurrent ? cardRoot.theme.surfaceFocusedColor : cardRoot.theme.surfaceColor
        border.color: cardRoot.isCurrent ? cardRoot.theme.borderFocusColor : cardRoot.theme.borderColor
        border.width: cardRoot.isCurrent ? cardRoot.theme.focusBorderWidth : 1

        Behavior on color {
            ColorAnimation { duration: cardRoot.theme.animDurationFast }
        }
        Behavior on border.color {
            ColorAnimation { duration: cardRoot.theme.animDurationFast }
        }
        Behavior on border.width {
            NumberAnimation { duration: cardRoot.theme.animDurationFast }
        }

        // Subtle gradient sheen on cards
        LinearGradient {
            anchors.fill: parent
            start: Qt.point(0, 0)
            end: Qt.point(0, height)
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1.0, 1.0, 1.0, cardRoot.isCurrent ? 0.14 : 0.05) }
                GradientStop { position: 0.3; color: Qt.rgba(1.0, 1.0, 1.0, 0.0) }
                GradientStop { position: 1.0; color: Qt.rgba(0.0, 0.0, 0.0, cardRoot.isCurrent ? 0.15 : 0.30) }
            }
        }

        // Kodi Estuary Top Accent Glow Line on Focused Card
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                leftMargin: cardRoot.theme.cardRadius / 2
                rightMargin: cardRoot.theme.cardRadius / 2
            }
            height: 2
            radius: 1
            color: cardRoot.theme.accentColor
            visible: cardRoot.isCurrent
            opacity: cardRoot.isCurrent ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation { duration: cardRoot.theme.animDurationFast }
            }
        }

        // Card Content
        ColumnLayout {
            anchors {
                fill: parent
                margins: Kirigami.Units.largeSpacing
            }
            spacing: Kirigami.Units.smallSpacing

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Kodi-style subtle ambient glow behind the icon on focus
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(parent.width * 0.75, parent.height * 0.75)
                    height: width
                    radius: width / 2
                    color: cardRoot.isCurrent ? Qt.rgba(cardRoot.theme.accentColor.r, cardRoot.theme.accentColor.g, cardRoot.theme.accentColor.b, 0.16) : "transparent"
                    visible: cardRoot.isCurrent

                    Behavior on color {
                        ColorAnimation { duration: cardRoot.theme.animDurationFast }
                    }
                }

                PlasmaCore.IconItem {
                    id: iconItem
                    anchors.centerIn: parent
                    width: Math.min(parent.width * 0.72, parent.height * 0.75)
                    height: width
                    source: cardRoot.iconSource ? cardRoot.iconSource : "application-x-executable"
                    animated: false
                }

                // Mini play / launch glyph in bottom corner on focus
                Rectangle {
                    anchors {
                        right: parent.right
                        bottom: parent.bottom
                    }
                    width: Kirigami.Units.gridUnit * 1.1
                    height: width
                    radius: width / 2
                    color: cardRoot.theme.accentColor
                    visible: cardRoot.isCurrent
                    opacity: cardRoot.isCurrent ? 0.95 : 0.0

                    PlasmaCore.IconItem {
                        anchors.centerIn: parent
                        width: parent.width * 0.65
                        height: width
                        source: "media-playback-start"
                    }
                }
            }

            // Title Label
            Controls.Label {
                id: labelTitle
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                text: cardRoot.title
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.95
                color: cardRoot.isCurrent ? cardRoot.theme.textColor : cardRoot.theme.textMutedColor
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1

                Behavior on color {
                    ColorAnimation { duration: cardRoot.theme.animDurationFast }
                }
            }

            // Subtitle or Category Chip
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: cardRoot.subtitle.length > 0 ? Kirigami.Units.gridUnit * 1.0 : 0
                visible: cardRoot.subtitle.length > 0

                Rectangle {
                    anchors.centerIn: parent
                    height: parent.height
                    width: Math.min(parent.width, subtitleText.implicitWidth + Kirigami.Units.largeSpacing)
                    radius: cardRoot.theme.badgeRadius
                    color: cardRoot.isCurrent ? cardRoot.theme.pillFocusedBackground : Qt.rgba(1.0, 1.0, 1.0, 0.06)
                    border.color: cardRoot.isCurrent ? cardRoot.theme.borderFocusColor : Qt.rgba(1.0, 1.0, 1.0, 0.10)
                    border.width: 1

                    Controls.Label {
                        id: subtitleText
                        anchors.centerIn: parent
                        text: cardRoot.subtitle
                        font.pixelSize: Kirigami.Units.gridUnit * 0.65
                        font.capitalization: Font.AllUppercase
                        font.bold: true
                        color: cardRoot.isCurrent ? cardRoot.theme.textColor : cardRoot.theme.textDimmedColor
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    // Focus & remote activation
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            var fl = cardRoot.findFlickable(cardRoot.parent);
            if (fl) {
                fl.currentIndex = index;
                cardRoot.forceActiveFocus();
            }
            cardRoot.clicked();
        }
    }

    Keys.onReturnPressed: {
        cardRoot.clicked();
    }
    Keys.onSelectPressed: {
        cardRoot.clicked();
    }
}
