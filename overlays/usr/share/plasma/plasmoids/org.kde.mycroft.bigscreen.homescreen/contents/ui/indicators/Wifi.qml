/*
    SPDX-FileCopyrightText: 2019 Marco Martin <mart@kde.org>
    SPDX-FileCopyrightText: 2013-2017 Jan Grulich <jgrulich@redhat.com>
    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

import QtQuick 2.14
import QtQuick.Layouts 1.14
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 2.0 as PlasmaComponents
import org.kde.plasma.networkmanagement 0.2 as PlasmaNM
import org.kde.kirigami 2.12 as Kirigami
import org.kde.plasma.private.nanoshell 2.0 as NanoShell

AbstractIndicator {
    id: connectionIcon

    icon.name: (connectionIconProvider && connectionIconProvider.connectionIcon) ? connectionIconProvider.connectionIcon : "network-wireless-connected"

    PlasmaComponents.BusyIndicator {
        id: connectingIndicator
        anchors.fill: parent
        running: connectionIconProvider.connecting
        visible: running
    }

    PlasmaNM.NetworkStatus {
        id: networkStatus
    }

    PlasmaNM.NetworkModel {
        id: connectionModel
    }

    PlasmaNM.Handler {
        id: handler
    }

    PlasmaNM.ConnectionIcon {
        id: connectionIconProvider
    }

    onClicked: {
        try {
            NanoShell.StartupFeedback.open(
                connectionIconProvider.connectionIcon,
                i18n("Network"),
                connectionIcon.Kirigami.ScenePosition.x + connectionIcon.width/2,
                connectionIcon.Kirigami.ScenePosition.y + connectionIcon.height/2,
                Math.min(connectionIcon.width, connectionIcon.height)
            );
        } catch(e) {}
        if (plasmoid && plasmoid.nativeInterface && typeof plasmoid.nativeInterface.executeCommand === "function") {
            plasmoid.nativeInterface.executeCommand("tvpc gui wifi 2>/dev/null || tvpc-wifi 2>/dev/null || plasma-settings -s -m kcm_mediacenter_wifi 2>/dev/null || kcmshell5 kcm_networkmanagement 2>/dev/null || true");
        }
    }
}
