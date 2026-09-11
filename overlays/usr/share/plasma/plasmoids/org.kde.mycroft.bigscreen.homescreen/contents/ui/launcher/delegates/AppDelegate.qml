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
    id: appDelegate

    readonly property var appStorageIdRole: modelData && modelData.ApplicationStorageIdRole ? modelData.ApplicationStorageIdRole : ""

    iconSource: {
        if (modelData) {
            if (modelData.ApplicationIconRole) return modelData.ApplicationIconRole;
            if (modelData.decoration) return modelData.decoration;
        }
        if (typeof model !== "undefined" && model) {
            if (model.decoration) return model.decoration;
        }
        return "application-x-executable";
    }

    title: {
        if (modelData) {
            if (modelData.ApplicationNameRole) return modelData.ApplicationNameRole;
            if (modelData.display) return modelData.display;
        }
        if (typeof model !== "undefined" && model && model.display) {
            return model.display;
        }
        return "";
    }

    comment: {
        if (modelData) {
            if (modelData.ApplicationCommentRole) return modelData.ApplicationCommentRole;
            if (modelData.description) return modelData.description;
        }
        if (typeof model !== "undefined" && model && model.description) {
            return model.description;
        }
        return "";
    }

    subtitle: {
        if (modelData && modelData.ApplicationCategoriesRole) {
            var cats = modelData.ApplicationCategoriesRole.toString();
            if (cats.indexOf("AudioVideo") !== -1 || cats.indexOf("Player") !== -1) return "Media";
            if (cats.indexOf("Game") !== -1) return "Game";
            if (cats.indexOf("Settings") !== -1) return "Settings";
            if (cats.indexOf("Network") !== -1) return "Network";
            if (cats.indexOf("Utility") !== -1) return "Utility";
            if (cats.indexOf("System") !== -1) return "System";
        }
        return "App";
    }

    // Update parent hero spotlight whenever this tile receives active focus
    onActiveFocusChanged: {
        if (activeFocus && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle);
        }
    }

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        try {
            NanoShell.StartupFeedback.open(
                iconSource.toString().length > 0 ? iconSource : "application-x-executable",
                title,
                appDelegate.Kirigami.ScenePosition.x + appDelegate.width/2,
                appDelegate.Kirigami.ScenePosition.y + appDelegate.height/2,
                Math.min(appDelegate.width, appDelegate.height),
                appDelegate.theme.accentColor
            );
        } catch (e) {
            // Non-fatal if startup feedback helper differs
        }

        if (typeof recentView !== "undefined" && recentView.model && typeof recentView.model.trigger === "function" && appDelegate.parent && appDelegate.parent.parent === recentView.view) {
            recentView.model.trigger(index, "", null);
        } else if (modelData && modelData.ApplicationStorageIdRole) {
            plasmoid.nativeInterface.applicationListModel.runApplication(modelData.ApplicationStorageIdRole);
        }

        if (typeof recentView !== "undefined" && recentView.visible) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
