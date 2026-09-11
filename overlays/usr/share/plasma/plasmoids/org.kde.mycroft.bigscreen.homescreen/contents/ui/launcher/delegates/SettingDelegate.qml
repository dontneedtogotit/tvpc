/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.kirigami 2.12 as Kirigami
import org.kde.plasma.private.nanoshell 2.0 as NanoShell

ModernCardDelegate {
    id: settingDelegate

    iconSource: modelData ? modelData.kcmIconName : "preferences-system"
    title: modelData ? modelData.kcmName : ""
    subtitle: "Settings"
    comment: modelData && modelData.kcmComment ? modelData.kcmComment : i18n("Configure system and display settings")

    onActiveFocusChanged: {
        if (activeFocus && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle);
        }
    }

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        try {
            NanoShell.StartupFeedback.open(
                settingDelegate.iconSource,
                settingDelegate.title,
                settingDelegate.Kirigami.ScenePosition.x + settingDelegate.width/2,
                settingDelegate.Kirigami.ScenePosition.y + settingDelegate.height/2,
                Math.min(settingDelegate.width, settingDelegate.height),
                settingDelegate.theme.accentColor
            );
        } catch (e) {
            // Non-fatal
        }

        if (typeof settingActions !== "undefined" && settingActions.launchSettings && modelData && modelData.kcmId) {
            settingActions.launchSettings(modelData.kcmId);
        }

        if (typeof recentView !== "undefined" && recentView.visible) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
