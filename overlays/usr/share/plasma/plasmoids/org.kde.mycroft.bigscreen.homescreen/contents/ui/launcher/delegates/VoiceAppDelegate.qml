/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-FileCopyrightText: 2019 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import org.kde.mycroft.bigscreen 1.0 as BigScreen

BigScreen.IconDelegate {
    id: delegate
    readonly property var vAppStorageIdRole: (typeof modelData !== "undefined" && modelData && modelData.ApplicationStorageIdRole)
        ? modelData.ApplicationStorageIdRole
        : ((typeof model !== "undefined" && model && model.ApplicationStorageIdRole) ? model.ApplicationStorageIdRole : "")

    icon.name: (typeof modelData !== "undefined" && modelData && modelData.ApplicationIconRole)
        ? modelData.ApplicationIconRole
        : ((typeof model !== "undefined" && model && model.ApplicationIconRole) ? model.ApplicationIconRole : "")

    text: (typeof modelData !== "undefined" && modelData && modelData.ApplicationNameRole)
        ? modelData.ApplicationNameRole
        : ((typeof model !== "undefined" && model && model.ApplicationNameRole) ? model.ApplicationNameRole : "")

    useIconColors: plasmoid.configuration ? plasmoid.configuration.coloredTiles : true
    compactMode: plasmoid.configuration ? plasmoid.configuration.expandingTiles : false

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        if (vAppStorageIdRole && plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.applicationListModel) {
            plasmoid.nativeInterface.applicationListModel.runApplication(vAppStorageIdRole);
        }
        if (typeof recentView !== "undefined" && recentView.visible && recentView.count > 0) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
