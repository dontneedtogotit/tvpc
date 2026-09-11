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

import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kquickcontrolsaddons 2.0
import org.kde.mycroft.bigscreen 1.0 as Launcher
import org.kde.private.biglauncher 1.0
import org.kde.kirigami 2.12 as Kirigami

FocusScope {
    id: root

    readonly property int reservedSpaceForLabel: metrics.height
    signal activateAppView
    signal activateTopNavBar
    signal activateSettingsView

    property Item wallpaper: {
        for (var i in plasmoid.children) {
            if (plasmoid.children[i].toString().indexOf("WallpaperInterface") === 0) {
                return plasmoid.children[i];
            }
        }
        return null;
    }

    Component.onCompleted: {
        root.forceActiveFocus();
        if (plasmoid && plasmoid.nativeInterface) {
            if (plasmoid.nativeInterface.kcmsListModel) {
                plasmoid.nativeInterface.kcmsListModel.loadKcms();
            }
            if (plasmoid.nativeInterface.applicationListModel) {
                plasmoid.nativeInterface.applicationListModel.loadApplications();
            }
            if (plasmoid.configuration) {
                if (typeof plasmoid.nativeInterface.setUseColoredTiles === "function") {
                    plasmoid.nativeInterface.setUseColoredTiles(plasmoid.configuration.coloredTiles);
                }
                if (typeof plasmoid.nativeInterface.setUseExpandableTiles === "function") {
                    plasmoid.nativeInterface.setUseExpandableTiles(plasmoid.configuration.expandingTiles);
                }
            }
        }
        root.activateAppView();
    }

    Connections {
        target: (plasmoid && plasmoid.applicationListModel) ? plasmoid.applicationListModel : null
        onAppOrderChanged: {
            root.activateAppView();
        }
    }

    Connections {
        target: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface) ? plasmoid.nativeInterface.bigLauncherDbusAdapterInterface : null
        onUseColoredTilesChanged: {
            if (plasmoid && plasmoid.configuration) {
                plasmoid.configuration.coloredTiles = msgUseColoredTiles;
                if (typeof plasmoid.nativeInterface.setUseColoredTiles === "function") {
                    plasmoid.nativeInterface.setUseColoredTiles(plasmoid.configuration.coloredTiles);
                }
            }
        }
        onUseExpandableTilesChanged: {
            if (plasmoid && plasmoid.configuration) {
                plasmoid.configuration.expandingTiles = msgUseExpandableTiles;
                if (typeof plasmoid.nativeInterface.setUseExpandableTiles === "function") {
                    plasmoid.nativeInterface.setUseExpandableTiles(plasmoid.configuration.expandingTiles);
                }
            }
        }
    }

    Controls.Label {
        id: metrics
        text: "M\nM"
        visible: false
    }

    LauncherHome {
        id: launcherHome
        anchors.fill: parent
    }
}
