/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-FileCopyrightText: 2015 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import QtQuick.Layouts 1.14
import QtQuick.Controls 2.14 as Controls
import QtQuick.Window 2.14
import QtGraphicalEffects 1.14
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.12 as Kirigami
import org.kde.kitemmodels 1.0 as KItemModels

import "delegates" as Delegates
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.private.biglauncher 1.0 
import org.kde.plasma.private.kicker 0.1 as Kicker
import "../.." as RootUI

FocusScope {
    id: launcherHomeRoot

    property var theme: (typeof root !== "undefined" && root.theme) ? root.theme : fallbackTheme
    RootUI.Theme { id: fallbackTheme }

    property bool mycroftIntegration: plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive() ? 1 : 0

    // Spotlight metadata properties
    property string currentTitle: "VacuumTube"
    property var currentIcon: "vacuumtube"
    property string currentComment: i18n("YouTube client with hardware video decode")
    property string currentCategory: "MEDIA"

    function updateSpotlight(title, icon, comment, category) {
        if (title && title.length > 0) currentTitle = title;
        if (icon) currentIcon = icon;
        currentComment = (comment && comment.length > 0) ? comment : i18n("Launch on TV");
        currentCategory = (category && category.length > 0) ? category : "APP";
    }

    Connections {
        target: plasmoid.nativeInterface.bigLauncherDbusAdapterInterface
        onEnableMycroftIntegrationChanged: {
            mycroftIntegration = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive()
            if (mycroftIntegration) {
                voiceAppsView.visible = voiceAppsView.count > 0 ? 1 : 0
            } else {
                voiceAppsView.visible = false
            }
        }
    }

    anchors {
        fill: parent
        leftMargin: Kirigami.Units.largeSpacing * 3
        rightMargin: Kirigami.Units.largeSpacing * 3
        topMargin: Kirigami.Units.largeSpacing * 2
    }

    // Top Hero Spotlight Banner
    Item {
        id: heroSpotlight
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: Kirigami.Units.gridUnit * 7.5
        z: 20

        Rectangle {
            anchors.fill: parent
            radius: launcherHomeRoot.theme.cardRadius
            color: Qt.rgba(launcherHomeRoot.theme.surfaceColor.r, launcherHomeRoot.theme.surfaceColor.g, launcherHomeRoot.theme.surfaceColor.b, 0.45)
            border.color: launcherHomeRoot.theme.borderColor
            border.width: 1

            // Subtle gradient accent from left
            LinearGradient {
                anchors.fill: parent
                start: Qt.point(0, 0)
                end: Qt.point(width * 0.6, 0)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: launcherHomeRoot.theme.accentGlowColor }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: 0.35
            }

            RowLayout {
                anchors {
                    fill: parent
                    margins: Kirigami.Units.largeSpacing * 1.5
                }
                spacing: Kirigami.Units.largeSpacing * 2

                // Spotlight Icon Container
                Item {
                    Layout.preferredWidth: heroSpotlight.height - Kirigami.Units.largeSpacing * 3
                    Layout.preferredHeight: width

                    Rectangle {
                        anchors.fill: parent
                        radius: launcherHomeRoot.theme.cardRadius
                        color: launcherHomeRoot.theme.surfaceFocusedColor
                        border.color: launcherHomeRoot.theme.borderFocusColor
                        border.width: 2

                        RectangularGlow {
                            anchors.fill: parent
                            glowRadius: 14
                            spread: 0.2
                            color: launcherHomeRoot.theme.accentGlowColor
                            cornerRadius: launcherHomeRoot.theme.cardRadius + 2
                        }

                        PlasmaCore.IconItem {
                            anchors.centerIn: parent
                            width: parent.width * 0.70
                            height: width
                            source: launcherHomeRoot.currentIcon
                        }
                    }
                }

                // Spotlight Info Details
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Kirigami.Units.smallSpacing

                    // Category Pill & Remote Action Tag
                    RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.1
                            width: categoryLabel.implicitWidth + Kirigami.Units.largeSpacing * 1.5
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: launcherHomeRoot.theme.accentColor

                            Controls.Label {
                                id: categoryLabel
                                anchors.centerIn: parent
                                text: launcherHomeRoot.currentCategory
                                font.bold: true
                                font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                color: "#ffffff"
                            }
                        }

                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.1
                            width: hintLabel.implicitWidth + Kirigami.Units.largeSpacing * 1.5
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: Qt.rgba(1.0, 1.0, 1.0, 0.08)
                            border.color: Qt.rgba(1.0, 1.0, 1.0, 0.15)
                            border.width: 1

                            Controls.Label {
                                id: hintLabel
                                anchors.centerIn: parent
                                text: i18n("Press [OK] to launch")
                                font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                color: launcherHomeRoot.theme.textMutedColor
                            }
                        }
                    }

                    // Spotlight Title
                    Controls.Label {
                        Layout.fillWidth: true
                        text: launcherHomeRoot.currentTitle
                        font.bold: true
                        font.pixelSize: Kirigami.Units.gridUnit * 1.6
                        color: launcherHomeRoot.theme.textColor
                        elide: Text.ElideRight
                    }

                    // Spotlight Comment / Description
                    Controls.Label {
                        Layout.fillWidth: true
                        text: launcherHomeRoot.currentComment
                        font.pixelSize: Kirigami.Units.gridUnit * 0.85
                        color: launcherHomeRoot.theme.textMutedColor
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    // Content rows
    ColumnLayout {
        id: launcherHomeColumn
        anchors {
            left: parent.left
            right: parent.right
            top: heroSpotlight.bottom
            topMargin: Kirigami.Units.largeSpacing * 2
        }

        property Item currentSection
        y: currentSection ? -currentSection.y + (parent.height - heroSpotlight.height) / 3 : 0

        Behavior on y {
            YAnimator {
                duration: launcherHomeRoot.theme.animDurationSlow
                easing.type: Easing.OutCubic
            }
        }
        spacing: Kirigami.Units.largeSpacing * 2.5

        // 1. RECENT ROW
        BigScreen.TileRepeater {
            id: recentView
            title: i18n("Recently Used")
            compactMode: plasmoid.configuration.expandingTiles
            model: Kicker.RecentUsageModel {
                shownItems: Kicker.RecentUsageModel.OnlyApps
            }

            visible: count > 0
            currentIndex: 0
            focus: true
            onActiveFocusChanged: if (activeFocus) launcherHomeColumn.currentSection = recentView
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }

            navigationUp: typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null
            navigationDown: voiceAppsView.visible ? voiceAppsView : appsView
        }

        // 2. VOICE APPS ROW
        BigScreen.TileRepeater {
            id: voiceAppsView
            title: i18n("Voice Apps")
            compactMode: plasmoid.configuration.expandingTiles
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    return sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole).indexOf("VoiceApp") !== -1;
                }
            }

            visible: mycroftIntegration && count > 0
            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) launcherHomeColumn.currentSection = voiceAppsView
            delegate: Delegates.VoiceAppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }

            navigationUp: recentView.visible ? recentView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null)
            navigationDown: appsView.visible ? appsView : (gamesView.visible ? gamesView : settingsView)
        }

        // 3. MAIN APPLICATIONS ROW
        BigScreen.TileRepeater {
            id: appsView
            title: i18n("Applications & Channels")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    var cats = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole);
                    return cats.indexOf("Game") === -1 && cats.indexOf("VoiceApp") === -1;
                }
            }

            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) launcherHomeColumn.currentSection = appsView
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }
            
            navigationUp: voiceAppsView.visible ? voiceAppsView : (recentView.visible ? recentView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null))
            navigationDown: gamesView.visible ? gamesView : settingsView
        }
        
        // 4. GAMES ROW
        BigScreen.TileRepeater {
            id: gamesView
            title: i18n("Games & Entertainment")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    return sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole).indexOf("Game") !== -1;
                }
            }

            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) launcherHomeColumn.currentSection = gamesView
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }
            
            navigationUp: appsView.visible ? appsView : (voiceAppsView.visible ? voiceAppsView : (recentView.visible ? recentView : null))
            navigationDown: settingsView
        }

        SettingActions {
            id: settingActions
        }
        
        // 5. SETTINGS ROW
        BigScreen.TileRepeater {
            id: settingsView
            title: i18n("Settings & System")
            model: plasmoid.nativeInterface.kcmsListModel
            compactMode: plasmoid.configuration.expandingTiles

            onActiveFocusChanged: if (activeFocus) launcherHomeColumn.currentSection = settingsView
            delegate: Delegates.SettingDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
                visible: model.active
                enabled: model.active
            }
            
            navigationUp: gamesView.visible ? gamesView : (appsView.visible ? appsView : (voiceAppsView.visible ? voiceAppsView : null))
            navigationDown: null
        }

        Component.onCompleted: {
            if (recentView.visible && recentView.count > 0) {
                recentView.forceActiveFocus();
            } else if (voiceAppsView.visible && voiceAppsView.count > 0) {
                voiceAppsView.forceActiveFocus();
            } else {
                appsView.forceActiveFocus();
            }
        }

        Connections {
            target: root
            onActivateAppView: {
                if (recentView.visible && recentView.count > 0) {
                    recentView.forceActiveFocus();
                } else {
                    appsView.forceActiveFocus();
                }
            }
        }
    }
}
