/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.kirigami 2.12 as Kirigami

ModernCardDelegate {
    id: voiceDelegate

    property var modelData: null

    readonly property var vAppStorageIdRole: {
        if (typeof modelData !== "undefined" && modelData && modelData.ApplicationStorageIdRole) return modelData.ApplicationStorageIdRole;
        if (typeof model !== "undefined" && model && model.ApplicationStorageIdRole) return model.ApplicationStorageIdRole;
        if (typeof ApplicationStorageIdRole !== "undefined" && ApplicationStorageIdRole) return ApplicationStorageIdRole;
        return "";
    }

    iconSource: {
        if (typeof modelData !== "undefined" && modelData && modelData.ApplicationIconRole) return modelData.ApplicationIconRole;
        if (typeof model !== "undefined" && model && model.ApplicationIconRole) return model.ApplicationIconRole;
        if (typeof ApplicationIconRole !== "undefined" && ApplicationIconRole) return ApplicationIconRole;
        return "microphone";
    }

    title: {
        if (typeof modelData !== "undefined" && modelData && modelData.ApplicationNameRole) return modelData.ApplicationNameRole;
        if (typeof model !== "undefined" && model && model.ApplicationNameRole) return model.ApplicationNameRole;
        if (typeof ApplicationNameRole !== "undefined" && ApplicationNameRole) return ApplicationNameRole;
        return "";
    }

    subtitle: "Voice"

    comment: {
        if (typeof modelData !== "undefined" && modelData && modelData.ApplicationCommentRole) return modelData.ApplicationCommentRole;
        if (typeof model !== "undefined" && model && model.ApplicationCommentRole) return model.ApplicationCommentRole;
        if (typeof ApplicationCommentRole !== "undefined" && ApplicationCommentRole) return ApplicationCommentRole;
        return "";
    }

    onActiveFocusChanged: {
        if (activeFocus && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle, ["VOICE ASSISTANT", "MICROPHONE", "AI SKILL"]);
        }
    }
    onIsCurrentChanged: {
        if (isCurrent && typeof launcherHomeRoot !== "undefined" && launcherHomeRoot.updateSpotlight) {
            launcherHomeRoot.updateSpotlight(title, iconSource, comment, subtitle, ["VOICE ASSISTANT", "MICROPHONE", "AI SKILL"]);
        }
    }

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        if (vAppStorageIdRole && plasmoid && plasmoid.nativeInterface && plasmoid.nativeInterface.applicationListModel) {
            plasmoid.nativeInterface.applicationListModel.runApplication(vAppStorageIdRole);
        }
    }
}
