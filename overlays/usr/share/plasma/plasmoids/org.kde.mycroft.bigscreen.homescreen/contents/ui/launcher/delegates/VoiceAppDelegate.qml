/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.kirigami 2.12 as Kirigami

ModernCardDelegate {
    id: voiceDelegate

    iconSource: modelData ? modelData.ApplicationIconRole : "microphone"
    title: modelData ? modelData.ApplicationNameRole : ""
    subtitle: "Voice"
    comment: modelData ? modelData.ApplicationCommentRole : ""

    onClicked: {
        BigScreen.NavigationSoundEffects.playClickedSound();
        if (modelData && modelData.ApplicationStorageIdRole) {
            plasmoid.nativeInterface.applicationListModel.runApplication(modelData.ApplicationStorageIdRole);
        }
    }
}
