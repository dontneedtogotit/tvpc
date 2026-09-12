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
    readonly property var kcmIdRole: (typeof modelData !== "undefined" && modelData && modelData.kcmId)
        ? modelData.kcmId
        : ((typeof model !== "undefined" && model && model.kcmId) ? model.kcmId : "")

    icon.name: (typeof modelData !== "undefined" && modelData && modelData.kcmIconName)
        ? modelData.kcmIconName
        : ((typeof model !== "undefined" && model && model.kcmIconName) ? model.kcmIconName : "preferences-system")

    text: (typeof modelData !== "undefined" && modelData && modelData.kcmName)
        ? modelData.kcmName
        : ((typeof model !== "undefined" && model && model.kcmName) ? model.kcmName : "")

    comment: (typeof modelData !== "undefined" && modelData && modelData.kcmComment)
        ? modelData.kcmComment
        : ((typeof model !== "undefined" && model && model.kcmComment) ? model.kcmComment : "")

    useIconColors: plasmoid.configuration ? plasmoid.configuration.coloredTiles : true
    compactMode: plasmoid.configuration ? plasmoid.configuration.expandingTiles : false

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        try {
            NanoShell.StartupFeedback.open(
                delegate.icon.name.length > 0 ? delegate.icon.name : "preferences-system",
                delegate.text,
                delegate.Kirigami.ScenePosition.x + delegate.width / 2,
                delegate.Kirigami.ScenePosition.y + delegate.height / 2,
                Math.min(delegate.width, delegate.height),
                delegate.Kirigami.Theme.backgroundColor
            );
        } catch (e) {
            // Non-fatal if startup feedback is unsupported
        }

        if (typeof settingActions !== "undefined" && settingActions.launchSettings && kcmIdRole) {
            settingActions.launchSettings(kcmIdRole);
        }

        if (typeof recentView !== "undefined" && recentView.visible && recentView.count > 0) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
