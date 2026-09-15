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

    property var modelData: null

    readonly property var appStorageIdRole: {
        if (typeof modelData !== "undefined" && modelData) {
            if (modelData.ApplicationStorageIdRole) return modelData.ApplicationStorageIdRole;
            if (modelData.storageId) return modelData.storageId;
        }
        if (typeof model !== "undefined" && model) {
            if (model.ApplicationStorageIdRole) return model.ApplicationStorageIdRole;
            if (model.storageId) return model.storageId;
        }
        if (typeof ApplicationStorageIdRole !== "undefined" && ApplicationStorageIdRole) return ApplicationStorageIdRole;
        if (typeof storageId !== "undefined" && storageId) return storageId;
        return "";
    }

    readonly property var appEntryPathRole: {
        if (typeof modelData !== "undefined" && modelData) {
            if (modelData.ApplicationEntryPathRole) return modelData.ApplicationEntryPathRole;
            if (modelData.entryPath) return modelData.entryPath;
        }
        if (typeof model !== "undefined" && model) {
            if (model.ApplicationEntryPathRole) return model.ApplicationEntryPathRole;
            if (model.entryPath) return model.entryPath;
        }
        if (typeof ApplicationEntryPathRole !== "undefined" && ApplicationEntryPathRole) return ApplicationEntryPathRole;
        return "";
    }

    iconSource: {
        if (typeof modelData !== "undefined" && modelData) {
            if (modelData.ApplicationIconRole) return modelData.ApplicationIconRole;
            if (modelData.decoration) return modelData.decoration;
            if (modelData.icon) return modelData.icon;
        }
        if (typeof model !== "undefined" && model) {
            if (model.ApplicationIconRole) return model.ApplicationIconRole;
            if (model.decoration) return model.decoration;
            if (model.icon) return model.icon;
        }
        if (typeof ApplicationIconRole !== "undefined" && ApplicationIconRole) return ApplicationIconRole;
        if (typeof decoration !== "undefined" && decoration) return decoration;
        return "application-x-executable";
    }

    title: {
        if (typeof modelData !== "undefined" && modelData) {
            if (modelData.ApplicationNameRole) return modelData.ApplicationNameRole;
            if (modelData.display) return modelData.display;
            if (modelData.name) return modelData.name;
        }
        if (typeof model !== "undefined" && model) {
            if (model.ApplicationNameRole) return model.ApplicationNameRole;
            if (model.display) return model.display;
            if (model.name) return model.name;
        }
        if (typeof ApplicationNameRole !== "undefined" && ApplicationNameRole) return ApplicationNameRole;
        if (typeof display !== "undefined" && display) return display;
        return "";
    }

    comment: {
        if (typeof modelData !== "undefined" && modelData) {
            if (modelData.ApplicationCommentRole) return modelData.ApplicationCommentRole;
            if (modelData.description) return modelData.description;
            if (modelData.comment) return modelData.comment;
        }
        if (typeof model !== "undefined" && model) {
            if (model.ApplicationCommentRole) return model.ApplicationCommentRole;
            if (model.description) return model.description;
            if (model.comment) return model.comment;
        }
        if (typeof ApplicationCommentRole !== "undefined" && ApplicationCommentRole) return ApplicationCommentRole;
        if (typeof description !== "undefined" && description) return description;
        return "";
    }

    subtitle: {
        var sid = (appStorageIdRole ? appStorageIdRole.toString().toLowerCase() : "");
        var t = (title ? title.toString().toLowerCase() : "");
        if (sid.indexOf("vacuumtube") !== -1 || sid.indexOf("youtube") !== -1 || t.indexOf("youtube") !== -1) return "Streaming Video";
        if (sid.indexOf("kodi") !== -1 || t.indexOf("kodi") !== -1) return "Media Center";
        if (sid.indexOf("camera") !== -1 || sid.indexOf("nvr") !== -1 || t.indexOf("camera") !== -1) return "Security NVR";
        if (sid.indexOf("vlc") !== -1 || sid.indexOf("mpv") !== -1) return "Media Player";
        if (sid.indexOf("retroarch") !== -1 || sid.indexOf("steam") !== -1) return "Gaming";
        
        var appCats = "";
        if (typeof modelData !== "undefined" && modelData && modelData.ApplicationCategoriesRole) {
            appCats = modelData.ApplicationCategoriesRole.toString();
        } else if (typeof model !== "undefined" && model && model.ApplicationCategoriesRole) {
            appCats = model.ApplicationCategoriesRole.toString();
        } else if (typeof ApplicationCategoriesRole !== "undefined" && ApplicationCategoriesRole) {
            appCats = ApplicationCategoriesRole.toString();
        }

        if (appCats) {
            if (appCats.indexOf("AudioVideo") !== -1 || appCats.indexOf("Player") !== -1) return "Media";
            if (appCats.indexOf("Game") !== -1) return "Game";
            if (appCats.indexOf("Settings") !== -1) return "Settings";
            if (appCats.indexOf("Network") !== -1) return "Network";
            if (appCats.indexOf("Utility") !== -1) return "Utility";
            if (appCats.indexOf("System") !== -1) return "System";
        }
        return "App";
    }

    readonly property var capabilityTags: {
        var sid = (appStorageIdRole ? appStorageIdRole.toString().toLowerCase() : "");
        var t = (title ? title.toString().toLowerCase() : "");
        if (sid.indexOf("vacuumtube") !== -1 || sid.indexOf("youtube") !== -1 || t.indexOf("youtube") !== -1) {
            return ["10-FOOT UI", "4K UHD", "HARDWARE DECODE", "HDMI-CEC"];
        }
        if (sid.indexOf("kodi") !== -1 || t.indexOf("kodi") !== -1) {
            return ["10-FOOT UI", "MEDIA SUITE", "PASSTHROUGH AUDIO", "CEC COMPLIANT"];
        }
        if (sid.indexOf("camera") !== -1 || sid.indexOf("nvr") !== -1) {
            return ["LIVE RTSP", "HARDWARE ACCEL", "MOTION ALERT", "LOCAL NVR"];
        }
        if (subtitle === "Media" || subtitle === "Media Player") {
            return ["HD/4K PLAYBACK", "HARDWARE DECODE", "10-FOOT UI"];
        }
        if (subtitle === "Game" || subtitle === "Gaming") {
            return ["GAMEPAD READY", "FULLSCREEN", "LOW LATENCY"];
        }
        return ["10-FOOT UI", "READY", "HDMI-CEC"];
    }

    // Safety timeout: dismiss startup feedback if application window doesn't steal focus in 4s
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

    // Update parent hero spotlight whenever this tile receives active focus
    onActiveFocusChanged: {
        if (activeFocus && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle, capabilityTags);
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
            startupFeedbackTimeout.restart();
        } catch (e) {
            // Non-fatal if startup feedback helper differs
        }

        var isRecent = false;
        try {
            var fl = findFlickable(appDelegate);
            if (typeof recentView !== "undefined" && recentView && recentView.view && fl === recentView.view) {
                isRecent = true;
            }
        } catch (e) {
            isRecent = false;
        }

        var targetStorageId = (appStorageIdRole ? appStorageIdRole.toString() : "");
        var targetExec = (appEntryPathRole ? appEntryPathRole.toString() : "");

        if (isRecent && typeof recentView !== "undefined" && recentView.model && typeof recentView.model.trigger === "function") {
            recentView.model.trigger(index, "", null);
        } else if (targetStorageId.length > 0 && plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.applicationListModel) {
            plasmoid.nativeInterface.applicationListModel.runApplication(targetStorageId);
        } else if (targetExec.length > 0 && plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.applicationListModel && typeof plasmoid.nativeInterface.applicationListModel.executeCommand === "function") {
            plasmoid.nativeInterface.applicationListModel.executeCommand(targetExec);
        }

        if (typeof recentView !== "undefined" && recentView.visible && recentView.count > 0) {
            recentView.forceActiveFocus();
            recentView.currentIndex = 0;
        }
    }
}
