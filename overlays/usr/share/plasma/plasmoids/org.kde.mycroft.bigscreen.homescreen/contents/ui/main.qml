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
import org.kde.kquickcontrolsaddons 2.0
import org.kde.kirigami 2.12 as Kirigami

import "launcher"
import "indicators" as Indicators
import org.kde.mycroft.bigscreen 1.0 as BigScreen

Item {
    id: root
    Layout.minimumWidth: Screen.desktopAvailableWidth
    Layout.minimumHeight: Screen.desktopAvailableHeight * 0.6

    // Theme engine instance accessible throughout homescreen
    readonly property alias theme: theme
    Theme {
        id: theme
    }

    property bool mycroftIntegration: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface)
        ? (plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive() ? 1 : 0)
        : 0

    property Item wallpaper

    Connections {
        target: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface) ? plasmoid.nativeInterface.bigLauncherDbusAdapterInterface : null
        onEnableMycroftIntegrationChanged: {
            mycroftIntegration = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive()
            if (mycroftIntegration) {
                mycroftIndicatorLoader.active = true;
                mycroftWindowLoader.active = true;
            } else {
                if (mycroftIndicatorLoader.item) mycroftIndicatorLoader.item.disconnectclose();
                if (mycroftWindowLoader.item) mycroftWindowLoader.item.disconnectclose();
            }
        }
        onEnablePmInhibitionChanged: {
            var powerInhibition = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.pmInhibitionActive()
            pmInhibitItem.inhibit = !!powerInhibition;
        }
    }

    Containment.onAppletAdded: {
        addApplet(applet, x, y);
    }

    PowerManagementItem {
        id: pmInhibitItem
    }

    PlasmaCore.ColorScope.colorGroup: PlasmaCore.Theme.ComplementaryColorGroup
    Component.onCompleted: {
        if (plasmoid && plasmoid.applets) {
            for (var i in plasmoid.applets) {
                root.addApplet(plasmoid.applets[i], -1, -1)
            }
        }
        if (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface) {
            pmInhibitItem.inhibit = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.pmInhibitionActive();
        }
        updateDateTime();
    }

    function addApplet(applet, x, y) {
        var container = appletContainerComponent.createObject(appletsLayout);
        container.height = appletsLayout.height;
        applet.parent = container;
        container.applet = applet;
        applet.anchors.fill = container;
        applet.visible = true;
        applet.expanded = false;
    }

    Component {
        id: appletContainerComponent
        Item {
            property Item applet
            visible: applet && applet.status !== PlasmaCore.Types.HiddenStatus && applet.status !== PlasmaCore.Types.PassiveStatus
            Layout.fillHeight: true
            Layout.minimumWidth: Math.max(applet.implicitWidth, applet.Layout.preferredWidth, applet.Layout.minimumWidth) + Kirigami.Units.gridUnit
            Layout.maximumWidth: Layout.minimumWidth
        }
    }

    FeedbackWindow {
        id: feedbackWindow
    }

    Loader {
        id: mycroftWindowLoader
        source: mycroftIntegration && Qt.resolvedUrl("MycroftWindow.qml") ? Qt.resolvedUrl("MycroftWindow.qml") : null
    }

    ConfigWindow {
        id: plasmoidConfig
    }

    // Cinematic subtle backdrop vignette
    LinearGradient {
        anchors.fill: parent
        start: Qt.point(0, 0)
        end: Qt.point(0, height)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.03, 0.05, 0.70) }
            GradientStop { position: 0.25; color: Qt.rgba(0.02, 0.03, 0.05, 0.25) }
            GradientStop { position: 0.70; color: Qt.rgba(0.02, 0.03, 0.05, 0.35) }
            GradientStop { position: 1.0; color: Qt.rgba(0.01, 0.02, 0.03, 0.85) }
        }
    }

    // Top Status & Clock Bar
    PlasmaCore.ColorScope {
        id: topBar
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
        }
        z: launcher.z + 10
        colorGroup: PlasmaCore.Theme.NormalColorGroup
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        height: Kirigami.Units.iconSizes.large + Kirigami.Units.smallSpacing * 2
        opacity: root.Window.active ? 1.0 : 0.8

        Behavior on opacity {
            OpacityAnimator {
                duration: theme.animDurationNormal
                easing.type: Easing.InOutQuad
            }
        }

        // Top bar frosted glass container
        Rectangle {
            anchors.fill: parent
            color: root.theme.topBarBackground
            border.color: root.theme.topBarBorder
            border.width: 1

            // Bottom glow line
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: 1
                color: root.theme.borderColor
            }
        }

        // Left section: Brand Badge + Digital Clock & Date
        RowLayout {
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                leftMargin: Kirigami.Units.largeSpacing * 2
            }
            spacing: Kirigami.Units.largeSpacing * 1.5

            // tvpc Brand Badge Pill
            Rectangle {
                Layout.preferredHeight: topBar.height - Kirigami.Units.smallSpacing * 2
                Layout.preferredWidth: brandRow.implicitWidth + Kirigami.Units.largeSpacing * 2
                radius: root.theme.pillRadius
                color: root.theme.pillBackground
                border.color: root.theme.pillBorder
                border.width: 1

                RowLayout {
                    id: brandRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: root.theme.accentColor
                    }

                    Controls.Label {
                        text: "tvpc"
                        font.bold: true
                        font.capitalization: Font.AllLowercase
                        font.pixelSize: Kirigami.Units.gridUnit * 0.95
                        color: root.theme.textColor
                    }
                }
            }

            // Digital Clock & Date
            RowLayout {
                spacing: Kirigami.Units.smallSpacing * 1.5

                Controls.Label {
                    id: clockTime
                    text: "--:--"
                    font.bold: true
                    font.pixelSize: Kirigami.Units.gridUnit * 1.15
                    color: root.theme.textColor
                }

                Controls.Label {
                    text: "•"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                    color: root.theme.accentColor
                }

                Controls.Label {
                    id: clockDate
                    text: ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                    color: root.theme.textMutedColor
                }
            }

            RowLayout {
                id: appletsLayout
                Layout.fillHeight: true
            }
        }

        // Right section: Task Controls (Alt+Tab & Close) + Status Indicator Pills
        RowLayout {
            anchors {
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                rightMargin: Kirigami.Units.largeSpacing * 2
            }
            spacing: Kirigami.Units.largeSpacing

            // Task Controls Pill: App Switcher (Alt+Tab) and Close Active Window (✕)
            Rectangle {
                Layout.preferredHeight: topBar.height - Kirigami.Units.smallSpacing * 2
                Layout.preferredWidth: taskControlsRow.implicitWidth + Kirigami.Units.smallSpacing * 2
                radius: root.theme.pillRadius
                color: root.theme.pillBackground
                border.color: root.theme.pillBorder
                border.width: 1

                RowLayout {
                    id: taskControlsRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing / 2

                    // Switch Apps Button (Alt+Tab)
                    Rectangle {
                        id: switchAppsBtn
                        Layout.fillHeight: true
                        Layout.preferredWidth: switchRow.implicitWidth + Kirigami.Units.largeSpacing
                        radius: root.theme.pillRadius
                        color: switchAppsBtn.activeFocus ? root.theme.pillFocusedBackground : (switchMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.12) : "transparent")
                        border.color: switchAppsBtn.activeFocus ? root.theme.borderFocusColor : "transparent"
                        border.width: switchAppsBtn.activeFocus ? 2 : 0

                        RowLayout {
                            id: switchRow
                            anchors.centerIn: parent
                            spacing: Kirigami.Units.smallSpacing / 2

                            PlasmaCore.IconItem {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: width
                                source: "window-duplicate"
                            }

                            Controls.Label {
                                text: "Switch (Alt+Tab)"
                                font.bold: true
                                font.pixelSize: Kirigami.Units.gridUnit * 0.75
                                color: switchAppsBtn.activeFocus ? root.theme.textColor : root.theme.textMutedColor
                            }
                        }

                        MouseArea {
                            id: switchMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.triggerAltTab()
                        }

                        Keys.onReturnPressed: root.triggerAltTab()
                        Keys.onSelectPressed: root.triggerAltTab()
                        KeyNavigation.right: closeAppBtn
                        KeyNavigation.down: launcher
                    }

                    // Close Active App Button (✕)
                    Rectangle {
                        id: closeAppBtn
                        Layout.fillHeight: true
                        Layout.preferredWidth: closeRow.implicitWidth + Kirigami.Units.largeSpacing
                        radius: root.theme.pillRadius
                        color: closeAppBtn.activeFocus ? Qt.rgba(0.94, 0.25, 0.25, 0.40) : (closeMouse.containsMouse ? Qt.rgba(0.94, 0.25, 0.25, 0.22) : "transparent")
                        border.color: closeAppBtn.activeFocus ? "#ef4444" : "transparent"
                        border.width: closeAppBtn.activeFocus ? 2 : 0

                        RowLayout {
                            id: closeRow
                            anchors.centerIn: parent
                            spacing: Kirigami.Units.smallSpacing / 2

                            PlasmaCore.IconItem {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: width
                                source: "window-close"
                            }

                            Controls.Label {
                                text: "Close (✕)"
                                font.bold: true
                                font.pixelSize: Kirigami.Units.gridUnit * 0.75
                                color: closeAppBtn.activeFocus ? "#ffffff" : "#fca5a5"
                            }
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.triggerCloseApp()
                        }

                        Keys.onReturnPressed: root.triggerCloseApp()
                        Keys.onSelectPressed: root.triggerCloseApp()
                        KeyNavigation.left: switchAppsBtn
                        KeyNavigation.right: kdeconnectIndicator
                        KeyNavigation.down: launcher
                    }
                }
            }

            // Status Indicators Pill (KDE Connect, Volume, Wifi, Shutdown)
            Rectangle {
                Layout.preferredHeight: topBar.height - Kirigami.Units.smallSpacing * 2
                Layout.preferredWidth: indicatorsRow.implicitWidth + Kirigami.Units.smallSpacing * 2
                radius: root.theme.pillRadius
                color: root.theme.pillBackground
                border.color: root.theme.pillBorder
                border.width: 1

                RowLayout {
                    id: indicatorsRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing

                    Loader {
                        id: mycroftIndicatorLoader
                        Layout.fillHeight: true
                        source: mycroftIntegration && Qt.resolvedUrl("MycroftIndicator.qml") ? Qt.resolvedUrl("MycroftIndicator.qml") : null
                    }

                    Indicators.KdeConnect {
                        id: kdeconnectIndicator
                        Layout.fillHeight: true
                        implicitWidth: height
                        KeyNavigation.down: launcher
                        KeyNavigation.right: volumeIndicator
                        KeyNavigation.tab: volumeIndicator
                        KeyNavigation.backtab: launcher
                        KeyNavigation.left: kdeconnectIndicator
                    }

                    Indicators.Volume {
                        id: volumeIndicator
                        Layout.fillHeight: true
                        implicitWidth: height
                        KeyNavigation.down: launcher
                        KeyNavigation.right: wifiIndicator
                        KeyNavigation.tab: wifiIndicator
                        KeyNavigation.backtab: launcher
                        KeyNavigation.left: kdeconnectIndicator
                    }

                    Indicators.Wifi {
                        id: wifiIndicator
                        Layout.fillHeight: true
                        implicitWidth: height
                        KeyNavigation.down: launcher
                        KeyNavigation.right: shutdownIndicator
                        KeyNavigation.tab: shutdownIndicator
                        KeyNavigation.backtab: volumeIndicator
                        KeyNavigation.left: volumeIndicator
                    }

                    Indicators.Shutdown {
                        id: shutdownIndicator
                        Layout.fillHeight: true
                        implicitWidth: height
                        KeyNavigation.down: launcher
                        KeyNavigation.right: launcher
                        KeyNavigation.tab: launcher
                        KeyNavigation.backtab: wifiIndicator
                        KeyNavigation.left: wifiIndicator
                    }
                }
            }
        }
    }

    // Clock update timer
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: updateDateTime()
    }

    function updateDateTime() {
        var now = new Date();
        clockTime.text = Qt.formatTime(now, "hh:mm AP");
        clockDate.text = Qt.formatDate(now, "dddd, MMM d");
    }

    function triggerAltTab() {
        BigScreen.NavigationSoundEffects.playClickedSound();
        if (plasmoid && plasmoid.nativeInterface && typeof plasmoid.nativeInterface.executeCommand === "function") {
            plasmoid.nativeInterface.executeCommand("qdbus org.kde.kglobalaccel /component/kwin invokeShortcut 'Walk Through Windows'");
        }
    }

    function triggerCloseApp() {
        BigScreen.NavigationSoundEffects.playClickedSound();
        if (plasmoid && plasmoid.nativeInterface && typeof plasmoid.nativeInterface.executeCommand === "function") {
            plasmoid.nativeInterface.executeCommand("qdbus org.kde.kglobalaccel /component/kwin invokeShortcut 'Window Close'");
        }
    }

    // Launcher Content
    LauncherMenu {
        id: launcher
        anchors {
            left: parent.left
            right: parent.right
            top: topBar.bottom
            bottom: parent.bottom
        }
        focus: true
    }
}
