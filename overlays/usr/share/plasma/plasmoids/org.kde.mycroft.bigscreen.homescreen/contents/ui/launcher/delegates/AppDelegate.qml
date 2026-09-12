/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-FileCopyrightText: 2019 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.kirigami 2.12 as Kirigami
import org.kde.plasma.private.nanoshell 2.0 as NanoShell

BigScreen.IconDelegate {
    id: delegate
    readonly property var appStorageIdRole: (typeof modelData !== "undefined" && modelData && modelData.ApplicationStorageIdRole)
        ? modelData.ApplicationStorageIdRole
        : ((typeof model !== "undefined" && model && model.ApplicationStorageIdRole) ? model.ApplicationStorageIdRole : "")

    icon.name: (typeof modelData !== "undefined" && modelData && modelData.ApplicationIconRole)
        ? modelData.ApplicationIconRole
        : ((typeof model !== "undefined" && model && model.ApplicationIconRole) ? model.ApplicationIconRole : (typeof iconImage !== "undefined" ? iconImage : "application-x-executable"))

    text: (typeof modelData !== "undefined" && modelData && modelData.ApplicationNameRole)
        ? modelData.ApplicationNameRole
        : ((typeof model !== "undefined" && model && model.ApplicationNameRole) ? model.ApplicationNameRole : ((typeof model !== "undefined" && model && model.display) ? model.display : ""))

    comment: (typeof modelData !== "undefined" && modelData && modelData.ApplicationCommentRole)
        ? modelData.ApplicationCommentRole
        : ((typeof model !== "undefined" && model && model.ApplicationCommentRole) ? model.ApplicationCommentRole : ((typeof model !== "undefined" && model && model.description) ? model.description : ""))

    useIconColors: plasmoid.configuration ? plasmoid.configuration.coloredTiles : true
    compactMode: plasmoid.configuration ? plasmoid.configuration.expandingTiles : false

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        try {
            NanoShell.StartupFeedback.open(
                delegate.icon.name.length > 0 ? delegate.icon.name : "application-x-executable",
                delegate.text,
                delegate.Kirigami.ScenePosition.x + delegate.width / 2,
                delegate.Kirigami.ScenePosition.y + delegate.height / 2,
                Math.min(delegate.width, delegate.height),
                delegate.Kirigami.Theme.backgroundColor
            );
        } catch (e) {
            // Non-fatal if startup feedback is unsupported
        }

        if (typeof recentView !== "undefined" && recentView.model && typeof recentView.model.trigger === "function" && delegate.parent && delegate.parent.parent === recentView.view) {
            recentView.model.trigger(index, "", null);
        } else if (appStorageIdRole && plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.applicationListModel) {
            plasmoid.nativeInterface.applicationListModel.runApplication(appStorageIdRole);
        }

        if (typeof recentView !== "undefined" && recentView.visible && recentView.count > 0) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
