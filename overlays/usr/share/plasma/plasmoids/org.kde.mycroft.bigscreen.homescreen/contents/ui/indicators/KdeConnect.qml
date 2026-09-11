/*
    SPDX-FileCopyrightText: 2019 Marco Martin <mart@kde.org>
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import QtQuick.Window 2.14
import QtQuick.Layouts 1.14
import QtQml.Models 2.14
import org.kde.plasma.plasmoid 2.0
import QtQuick.Controls 2.14 as Controls
import org.kde.kirigami 2.12 as Kirigami
import org.kde.kdeconnect 1.0 as KDEConnect
import org.kde.plasma.private.nanoshell 2.0 as NanoShell

AbstractIndicator {
    id: connectionIcon
    icon.name: "kdeconnect"
    property var window
    property bool mycroftIntegration: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface)
        ? (plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive() ? 1 : 0)
        : 0

    Connections {
        target: (plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.bigLauncherDbusAdapterInterface) ? plasmoid.nativeInterface.bigLauncherDbusAdapterInterface : null
        onEnableMycroftIntegrationChanged: {
            mycroftIntegration = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive();
        }
    }

    KDEConnect.DevicesModel {
        id: allDevicesModel
    }

    onClicked: {
        try {
            NanoShell.StartupFeedback.open(
                "kdeconnect",
                i18n("KDE Connect"),
                connectionIcon.Kirigami.ScenePosition.x + connectionIcon.width/2,
                connectionIcon.Kirigami.ScenePosition.y + connectionIcon.height/2,
                Math.min(connectionIcon.width, connectionIcon.height)
            );
        } catch(e) {}
        if (plasmoid && plasmoid.nativeInterface) {
            plasmoid.nativeInterface.executeCommand("plasma-settings -s -m kcm_mediacenter_kdeconnect");
        }
    }
}
