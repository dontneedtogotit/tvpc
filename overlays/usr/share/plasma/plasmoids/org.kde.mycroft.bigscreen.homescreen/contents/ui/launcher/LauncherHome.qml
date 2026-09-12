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
import org.kde.plasma.components 2.0 as PlasmaComponents
import org.kde.kquickcontrolsaddons 2.0
import org.kde.kirigami 2.12 as Kirigami
import org.kde.kitemmodels 1.0 as KItemModels

import "delegates" as Delegates
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.private.biglauncher 1.0
import org.kde.plasma.private.kicker 0.1 as Kicker
FocusScope {
    id: launcherHomeRoot

    property var theme: (typeof root !== "undefined" && root.theme) ? root.theme : null

    property bool mycroftIntegration: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface)
        ? (plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive() ? 1 : 0)
        : 0

    Connections {
        target: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface)
            ? plasmoid.nativeInterface.bigLauncherDbusAdapterInterface
            : null

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
        leftMargin: Kirigami.Units.largeSpacing * 4
        rightMargin: Kirigami.Units.largeSpacing * 4
    }

    Item {
        id: singleRowContainer
        anchors {
            left: parent.left
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        height: appsView.implicitHeight > 0 ? appsView.implicitHeight : (Kirigami.Units.gridUnit * 12)

        BigScreen.TileRepeater {
            id: appsView
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            title: ""
            compactMode: plasmoid.configuration ? plasmoid.configuration.expandingTiles : false
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: (plasmoid && plasmoid.nativeInterface) ? plasmoid.nativeInterface.applicationListModel : null
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    if (!sourceModel) return true;
                    var idx = sourceModel.index(source_row, 0, source_parent);
                    var cats = sourceModel.data(idx, ApplicationListModel.ApplicationCategoriesRole);
                    if (cats && cats.indexOf("VoiceApp") !== -1) return false;
                    return true;
                }
            }

            currentIndex: 0
            focus: true
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
                comment: (typeof model !== "undefined" && model && model.ApplicationCommentRole) ? model.ApplicationCommentRole : ""
            }

            navigationUp: (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null)
            navigationDown: null
        }
    }

    SettingActions {
        id: settingActions
    }

    Component.onCompleted: {
        appsView.forceActiveFocus();
    }

    Connections {
        target: root
        onActivateAppView: {
            appsView.forceActiveFocus();
        }
    }
}
