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

    property var modelData: null

    iconSource: {
        if (typeof modelData !== "undefined" && modelData && modelData.kcmIconName) return modelData.kcmIconName;
        if (typeof model !== "undefined" && model && model.kcmIconName) return model.kcmIconName;
        if (typeof kcmIconName !== "undefined" && kcmIconName) return kcmIconName;
        return "preferences-system";
    }

    title: {
        if (typeof modelData !== "undefined" && modelData && modelData.kcmName) return modelData.kcmName;
        if (typeof model !== "undefined" && model && model.kcmName) return model.kcmName;
        if (typeof kcmName !== "undefined" && kcmName) return kcmName;
        return "";
    }

    subtitle: "Settings"

    comment: {
        if (typeof modelData !== "undefined" && modelData && modelData.kcmComment) return modelData.kcmComment;
        if (typeof model !== "undefined" && model && model.kcmComment) return model.kcmComment;
        if (typeof kcmComment !== "undefined" && kcmComment) return kcmComment;
        return i18n("Configure system and display settings");
    }

    readonly property var targetKcmId: {
        if (typeof modelData !== "undefined" && modelData && modelData.kcmId) return modelData.kcmId;
        if (typeof model !== "undefined" && model && model.kcmId) return model.kcmId;
        if (typeof kcmId !== "undefined" && kcmId) return kcmId;
        return "";
    }

    onActiveFocusChanged: {
        if (activeFocus && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle, ["SYSTEM PREFERENCE", "10-FOOT UI", "INSTANT APPLY"]);
        }
    }
    onIsCurrentChanged: {
        if (isCurrent && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle, ["SYSTEM PREFERENCE", "10-FOOT UI", "INSTANT APPLY"]);
        }
    }

    // Safety timeout: dismiss startup feedback if KCM doesn't steal focus in 4s
    Timer {
        id: startupFeedbackTimeout
        interval: 4000
        repeat: false
        onTriggered: {
            try {
                if (typeof NanoShell !== "undefined" && NanoShell.StartupFeedback && NanoShell.StartupFeedback.state === "open") {
                    NanoShell.StartupFeedback.state = "closed";
                }
            } catch (e) {
                // Non-fatal
            }
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
            startupFeedbackTimeout.restart();
        } catch (e) {
            // Non-fatal
        }

        if (typeof settingActions !== "undefined" && settingActions.launchSettings && targetKcmId) {
            settingActions.launchSettings(targetKcmId);
        }

        if (typeof recentView !== "undefined" && recentView.visible && recentView.count > 0) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
