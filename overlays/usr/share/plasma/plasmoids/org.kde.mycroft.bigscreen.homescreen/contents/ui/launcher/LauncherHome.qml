/*
    SPDX-FileCopyrightText: 2026 tvpc developers
    SPDX-FileCopyrightText: 2019 Aditya Mehra <aix.m@outlook.com>
    SPDX-FileCopyrightText: 2015 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

import QtQuick 2.14
import QtQuick.Layouts 1.14
import QtQuick.Controls 2.14 as Controls
import QtQuick.Window 2.14
import QtGraphicalEffects 1.14
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.12 as Kirigami
import org.kde.kitemmodels 1.0 as KItemModels

import "delegates" as Delegates
import org.kde.mycroft.bigscreen 1.0 as BigScreen
import org.kde.private.biglauncher 1.0 
import org.kde.plasma.private.kicker 0.1 as Kicker
import "../.." as RootUI

FocusScope {
    id: launcherHomeRoot

    property var theme: (typeof root !== "undefined" && root.theme) ? root.theme : fallbackTheme
    RootUI.Theme { id: fallbackTheme }

    property bool mycroftIntegration: plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive() ? 1 : 0

    // Spotlight metadata properties
    property string currentTitle: "VacuumTube"
    property var currentIcon: "vacuumtube"
    property string currentComment: i18n("YouTube client with hardware video decode")
    property string currentCategory: "STREAMING VIDEO"
    property var currentTags: ["10-FOOT UI", "4K UHD", "HARDWARE DECODE", "HDMI-CEC"]

    function updateSpotlight(title, icon, comment, category, tags) {
        if (title && title.length > 0) currentTitle = title;
        if (icon) currentIcon = icon;
        currentComment = (comment && comment.length > 0) ? comment : i18n("Launch on TV");
        currentCategory = (category && category.length > 0) ? category : "APP";
        if (tags && tags.length > 0) {
            currentTags = tags;
        } else {
            currentTags = ["10-FOOT UI", "READY", "HDMI-CEC"];
        }
    }

    function getVisibleRows() {
        var all = [favoritesView, recentView, mediaView, gamesView, appsView, voiceAppsView, settingsView];
        var vis = [];
        for (var i = 0; i < all.length; i++) {
            if (all[i] && all[i].visible && (typeof all[i].count === "undefined" || all[i].count > 0)) {
                vis.push(all[i]);
            }
        }
        return vis;
    }

    function scrollRows(direction) {
        var rows = getVisibleRows();
        if (rows.length === 0) return;
        var curr = singleRowContainer.currentSection;
        var idx = -1;
        for (var i = 0; i < rows.length; i++) {
            if (rows[i] === curr) {
                idx = i;
                break;
            }
        }
        if (idx === -1) {
            for (var j = 0; j < rows.length; j++) {
                if (rows[j].activeFocus) {
                    idx = j;
                    break;
                }
            }
            if (idx === -1) idx = 0;
        }

        var nextIdx = idx + direction;
        if (nextIdx < 0) nextIdx = 0;
        if (nextIdx >= rows.length) nextIdx = rows.length - 1;

        var targetRow = rows[nextIdx];
        if (targetRow) {
            singleRowContainer.currentSection = targetRow;
            targetRow.forceActiveFocus();
        }
    }

    function scrollCurrentRowHorizontal(direction) {
        var curr = singleRowContainer.currentSection;
        if (!curr) {
            var rows = getVisibleRows();
            if (rows.length > 0) curr = rows[0];
        }
        if (!curr) return;

        if (typeof curr.currentIndex !== "undefined") {
            var count = typeof curr.count !== "undefined" ? curr.count : 0;
            var newIdx = curr.currentIndex + direction;
            if (newIdx >= 0 && (count === 0 || newIdx < count)) {
                curr.currentIndex = newIdx;
            }
        }
    }

    function resetToTop() {
        if (favoritesView.visible && favoritesView.count > 0) {
            favoritesView.currentIndex = 0;
            singleRowContainer.currentSection = favoritesView;
            favoritesView.forceActiveFocus();
            if (typeof root !== "undefined") root.currentSectionTitle = i18n("Favorites & Pinned");
        } else if (mediaView.visible && mediaView.count > 0) {
            mediaView.currentIndex = 0;
            singleRowContainer.currentSection = mediaView;
            mediaView.forceActiveFocus();
            if (typeof root !== "undefined") root.currentSectionTitle = i18n("Videos & Streaming");
        }
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Home) {
            resetToTop();
            event.accepted = true;
        }
    }

    MouseArea {
        id: homeWheelArea
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.NoButton
        onWheel: {
            if (wheel.angleDelta.y !== 0) {
                launcherHomeRoot.scrollRows(wheel.angleDelta.y < 0 ? 1 : -1);
                wheel.accepted = true;
            } else if (wheel.angleDelta.x !== 0) {
                launcherHomeRoot.scrollCurrentRowHorizontal(wheel.angleDelta.x < 0 ? 1 : -1);
                wheel.accepted = true;
            }
        }
    }

    onActiveFocusChanged: {
        if (activeFocus) {
            if (singleRowContainer && singleRowContainer.currentSection && singleRowContainer.currentSection.visible) {
                singleRowContainer.currentSection.forceActiveFocus();
            } else if (favoritesView.visible && favoritesView.count > 0) {
                favoritesView.forceActiveFocus();
            }
        }
    }

    property var runningAppIds: ["vacuumtube"]
    property bool nowPlayingActive: false
    property string nowPlayingTitle: ""
    property string nowPlayingArtist: ""
    property string nowPlayingStatus: "Playing"

    function toggleNowPlaying() {
        if (plasmoid && plasmoid.nativeInterface && typeof plasmoid.nativeInterface.executeCommand === "function") {
            plasmoid.nativeInterface.executeCommand("playerctl play-pause 2>/dev/null || true");
            updateMediaState();
        }
    }

    Timer {
        id: mediaPollTimer
        interval: 3000
        running: true
        repeat: true
        onTriggered: updateMediaState()
    }

    function updateMediaState() {
        var paths = ["/run/user/1000/tvpc-mpris.json", "/tmp/tvpc-mpris.json", "/run/tvpc-mpris.json"];
        function tryPath(idx) {
            if (idx >= paths.length) return;
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "file://" + paths[idx], true);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    if (xhr.status === 200 || xhr.status === 0) {
                        try {
                            var d = JSON.parse(xhr.responseText);
                            if (d) {
                                nowPlayingActive = !!d.active;
                                nowPlayingTitle = d.title || "";
                                nowPlayingArtist = d.artist || "";
                                nowPlayingStatus = d.status || "Playing";
                                if (d.running) runningAppIds = d.running;
                                return;
                            }
                        } catch (e) {}
                    }
                    tryPath(idx + 1);
                }
            };
            try { xhr.send(); } catch (e) { tryPath(idx + 1); }
        }
        tryPath(0);
    }

    function isFavoriteApp(cats, storageId) {
        var sid = storageId ? storageId.toString().toLowerCase() : "";
        if (sid.indexOf("vacuumtube") !== -1 || sid.indexOf("youtube") !== -1) return true;
        if (sid.indexOf("kodi") !== -1) return true;
        if (sid.indexOf("camera") !== -1 || sid.indexOf("nvr") !== -1) return true;
        if (sid.indexOf("chromium") !== -1) return true;
        if (sid.indexOf("retroarch") !== -1 || sid.indexOf("steam") !== -1) return true;
        return false;
    }

    function isMediaApp(cats, storageId) {
        var sid = storageId ? storageId.toString().toLowerCase() : "";
        if (sid.indexOf("foot") !== -1 || sid.indexOf("term") !== -1 || sid.indexOf("ghostty") !== -1 || sid.indexOf("konsole") !== -1) return false;
        if (cats && cats.indexOf("Game") !== -1) return false;
        if (cats && (cats.indexOf("AudioVideo") !== -1 || cats.indexOf("Video") !== -1 || cats.indexOf("Player") !== -1 || cats.indexOf("Audio") !== -1)) return true;
        if (sid.indexOf("vacuumtube") !== -1 || sid.indexOf("youtube") !== -1 || sid.indexOf("kodi") !== -1 || sid.indexOf("vlc") !== -1 || sid.indexOf("mpv") !== -1 || sid.indexOf("camera") !== -1 || sid.indexOf("nvr") !== -1) return true;
        return false;
    }

    Connections {
        target: plasmoid.nativeInterface.bigLauncherDbusAdapterInterface
        onEnableMycroftIntegrationChanged: {
            mycroftIntegration = plasmoid.nativeInterface.bigLauncherDbusAdapterInterface.mycroftIntegrationActive()
            if (mycroftIntegration) {
                voiceAppsView.visible = voiceAppsView.count > 0 ? 1 : 0
            } else {
                voiceAppsView.visible = false
            }
        }
    }

    anchors {
        fill: parent
        leftMargin: Kirigami.Units.largeSpacing * 3
        rightMargin: Kirigami.Units.largeSpacing * 3
        topMargin: Kirigami.Units.largeSpacing * 2
    }

    // Top Hero Spotlight Banner (Kodi / LibreELEC Estuary Showcase)
    Item {
        id: heroSpotlight
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: Kirigami.Units.gridUnit * 7.8
        z: 20

        Rectangle {
            anchors.fill: parent
            radius: launcherHomeRoot.theme.cardRadius
            color: Qt.rgba(launcherHomeRoot.theme.surfaceColor.r, launcherHomeRoot.theme.surfaceColor.g, launcherHomeRoot.theme.surfaceColor.b, 0.55)
            border.color: launcherHomeRoot.theme.borderColor
            border.width: 1

            // Kodi Estuary top cyan accent sheen
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: 2
                color: launcherHomeRoot.theme.accentColor
                opacity: 0.85
            }

            // Subtle gradient accent from left
            LinearGradient {
                anchors.fill: parent
                start: Qt.point(0, 0)
                end: Qt.point(width * 0.65, 0)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: launcherHomeRoot.theme.accentGlowColor }
                    GradientStop { position: 0.4; color: Qt.rgba(launcherHomeRoot.theme.accentColor.r, launcherHomeRoot.theme.accentColor.g, launcherHomeRoot.theme.accentColor.b, 0.05) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: 0.5
            }

            RowLayout {
                anchors {
                    fill: parent
                    margins: Kirigami.Units.largeSpacing * 1.5
                }
                spacing: Kirigami.Units.largeSpacing * 2

                // Spotlight Icon Container
                Item {
                    Layout.preferredWidth: heroSpotlight.height - Kirigami.Units.largeSpacing * 3
                    Layout.preferredHeight: width

                    Rectangle {
                        anchors.fill: parent
                        radius: launcherHomeRoot.theme.cardRadius
                        color: launcherHomeRoot.theme.surfaceFocusedColor
                        border.color: launcherHomeRoot.theme.borderFocusColor
                        border.width: 2

                        RectangularGlow {
                            anchors.fill: parent
                            glowRadius: 18
                            spread: 0.25
                            color: launcherHomeRoot.theme.accentGlowColor
                            cornerRadius: launcherHomeRoot.theme.cardRadius + 2
                        }

                        Image {
                            id: cameraLiveThumb
                            anchors.fill: parent
                            anchors.margins: 4
                            visible: (launcherHomeRoot.currentCategory === "Security NVR" || launcherHomeRoot.currentTitle.indexOf("Camera") !== -1 || launcherHomeRoot.currentTitle.indexOf("NVR") !== -1) && status === Image.Ready
                            source: "file:///run/tvpc-cameras/live_feed.jpg"
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                            onStatusChanged: {
                                if (status === Image.Error && source === "file:///run/tvpc-cameras/live_feed.jpg") {
                                    source = "file:///var/lib/tvpc-nvr/snapshots/cam0_latest.jpg";
                                }
                            }
                        }

                        PlasmaCore.IconItem {
                            anchors.centerIn: parent
                            width: parent.width * 0.72
                            height: width
                            source: launcherHomeRoot.currentIcon
                            visible: !cameraLiveThumb.visible
                        }
                    }
                }

                // Spotlight Info Details
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Kirigami.Units.smallSpacing

                    // Category Pill, Now Playing, Capability Badges & Remote Action Prompt
                    RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        // Glowing Category Pill
                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.15
                            width: categoryLabel.implicitWidth + Kirigami.Units.largeSpacing * 1.6
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: launcherHomeRoot.theme.accentColor

                            Controls.Label {
                                id: categoryLabel
                                anchors.centerIn: parent
                                text: launcherHomeRoot.currentCategory
                                font.bold: true
                                font.capitalization: Font.AllUppercase
                                font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                color: "#000000"
                            }
                        }

                        // Now Playing Media Pill (when media is active)
                        Rectangle {
                            visible: launcherHomeRoot.nowPlayingActive
                            height: Kirigami.Units.gridUnit * 1.15
                            width: nowPlayingPillRow.implicitWidth + Kirigami.Units.largeSpacing * 1.4
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: Qt.rgba(0.13, 0.77, 0.36, 0.35)
                            border.color: "#22c55e"
                            border.width: 1

                            RowLayout {
                                id: nowPlayingPillRow
                                anchors.centerIn: parent
                                spacing: 4

                                PlasmaCore.IconItem {
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                    Layout.preferredHeight: width
                                    source: launcherHomeRoot.nowPlayingStatus === "Playing" ? "media-playback-start" : "media-playback-pause"
                                }

                                Controls.Label {
                                    text: "NOW PLAYING: " + (launcherHomeRoot.nowPlayingTitle.length > 0 ? launcherHomeRoot.nowPlayingTitle : "Media")
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                    color: "#86efac"
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: launcherHomeRoot.toggleNowPlaying()
                            }
                        }

                        // Format / Capability Badges
                        Repeater {
                            model: launcherHomeRoot.currentTags
                            delegate: Rectangle {
                                height: Kirigami.Units.gridUnit * 1.15
                                width: tagLabel.implicitWidth + Kirigami.Units.largeSpacing * 1.2
                                radius: launcherHomeRoot.theme.badgeRadius
                                color: Qt.rgba(1.0, 1.0, 1.0, 0.09)
                                border.color: Qt.rgba(1.0, 1.0, 1.0, 0.16)
                                border.width: 1

                                Controls.Label {
                                    id: tagLabel
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.62
                                    color: launcherHomeRoot.theme.textColor
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Kodi-style primary action prompt pill
                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.15
                            width: hintRow.implicitWidth + Kirigami.Units.largeSpacing * 1.5
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: Qt.rgba(1.0, 1.0, 1.0, 0.09)
                            border.color: launcherHomeRoot.theme.borderFocusColor
                            border.width: 1

                            RowLayout {
                                id: hintRow
                                anchors.centerIn: parent
                                spacing: Kirigami.Units.smallSpacing / 2

                                PlasmaCore.IconItem {
                                    width: Kirigami.Units.iconSizes.small * 0.75
                                    height: width
                                    source: "media-playback-start"
                                }

                                Controls.Label {
                                    text: i18n("Press [OK] to Launch")
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                    color: launcherHomeRoot.theme.textColor
                                }
                            }
                        }
                    }

                    // Spotlight Title
                    Controls.Label {
                        Layout.fillWidth: true
                        text: launcherHomeRoot.currentTitle
                        font.bold: true
                        font.pixelSize: Kirigami.Units.gridUnit * 1.7
                        color: launcherHomeRoot.theme.textColor
                        elide: Text.ElideRight
                    }

                    // Spotlight Comment / Description
                    Controls.Label {
                        Layout.fillWidth: true
                        text: launcherHomeRoot.currentComment
                        font.pixelSize: Kirigami.Units.gridUnit * 0.88
                        color: launcherHomeRoot.theme.textMutedColor
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                    }

                    // Quick Action Chips Row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing * 1.5

                        // Action 1: Launch / Play
                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.15
                            width: chip1Row.implicitWidth + Kirigami.Units.largeSpacing * 1.4
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: launcherHomeRoot.theme.pillFocusedBackground
                            border.color: launcherHomeRoot.theme.borderFocusColor
                            border.width: 1

                            RowLayout {
                                id: chip1Row
                                anchors.centerIn: parent
                                spacing: Kirigami.Units.smallSpacing / 2

                                PlasmaCore.IconItem {
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                    Layout.preferredHeight: width
                                    source: "media-playback-start"
                                }

                                Controls.Label {
                                    text: i18n("Launch on TV")
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                    color: launcherHomeRoot.theme.textColor
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (singleRowContainer.currentSection && singleRowContainer.currentSection.currentItem) {
                                        singleRowContainer.currentSection.currentItem.clicked();
                                    }
                                }
                            }
                        }

                        // Action 2: Contextual action (PiP for camera, Subscriptions for YouTube, Media control)
                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.15
                            width: chip2Row.implicitWidth + Kirigami.Units.largeSpacing * 1.4
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: chip2Mouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(1.0, 1.0, 1.0, 0.08)
                            border.color: Qt.rgba(1.0, 1.0, 1.0, 0.18)
                            border.width: 1

                            RowLayout {
                                id: chip2Row
                                anchors.centerIn: parent
                                spacing: Kirigami.Units.smallSpacing / 2

                                PlasmaCore.IconItem {
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                    Layout.preferredHeight: width
                                    source: (launcherHomeRoot.currentTitle.indexOf("Camera") !== -1 || launcherHomeRoot.currentCategory === "Security NVR") ? "video-television" : (launcherHomeRoot.nowPlayingActive ? "media-playback-pause" : "view-media-playlist")
                                }

                                Controls.Label {
                                    text: (launcherHomeRoot.currentTitle.indexOf("Camera") !== -1 || launcherHomeRoot.currentCategory === "Security NVR") ? i18n("Toggle PiP (🔴)") : (launcherHomeRoot.nowPlayingActive ? i18n("Pause/Resume") : i18n("Explore"))
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                    color: launcherHomeRoot.theme.textColor
                                }
                            }

                            MouseArea {
                                id: chip2Mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (launcherHomeRoot.currentTitle.indexOf("Camera") !== -1 || launcherHomeRoot.currentCategory === "Security NVR") {
                                        if (typeof root !== "undefined") root.triggerCameraPip();
                                    } else if (launcherHomeRoot.nowPlayingActive) {
                                        launcherHomeRoot.toggleNowPlaying();
                                    }
                                }
                            }
                        }

                        // Action 3: 2x2 Grid for Cameras
                        Rectangle {
                            height: Kirigami.Units.gridUnit * 1.15
                            width: chip3Row.implicitWidth + Kirigami.Units.largeSpacing * 1.4
                            radius: launcherHomeRoot.theme.badgeRadius
                            color: chip3Mouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(1.0, 1.0, 1.0, 0.08)
                            border.color: Qt.rgba(1.0, 1.0, 1.0, 0.18)
                            border.width: 1
                            visible: (launcherHomeRoot.currentTitle.indexOf("Camera") !== -1 || launcherHomeRoot.currentCategory === "Security NVR")

                            RowLayout {
                                id: chip3Row
                                anchors.centerIn: parent
                                spacing: Kirigami.Units.smallSpacing / 2

                                PlasmaCore.IconItem {
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                    Layout.preferredHeight: width
                                    source: "view-split-left-right"
                                }

                                Controls.Label {
                                    text: i18n("2x2 Grid (🔵)")
                                    font.bold: true
                                    font.pixelSize: Kirigami.Units.gridUnit * 0.65
                                    color: launcherHomeRoot.theme.textColor
                                }
                            }

                            MouseArea {
                                id: chip3Mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof root !== "undefined") root.triggerCameraGrid();
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Content rows
    ColumnLayout {
        id: singleRowContainer
        property alias launcherHomeColumn: singleRowContainer
        anchors {
            left: parent.left
            right: parent.right
        }

        property Item currentSection
        readonly property real baseTop: heroSpotlight.y + heroSpotlight.height + Kirigami.Units.largeSpacing * 2
        y: currentSection ? Math.min(baseTop, baseTop - currentSection.y) : baseTop

        Behavior on y {
            YAnimator {
                duration: launcherHomeRoot.theme.animDurationSlow
                easing.type: Easing.OutCubic
            }
        }
        spacing: Kirigami.Units.largeSpacing * 2.5

        // 0. PINNED & FAVORITES ROW (Top Curated TV Apps)
        BigScreen.TileRepeater {
            id: favoritesView
            title: i18n("⭐ Pinned & Favorites")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    var cats = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole);
                    var storageId = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationStorageIdRole);
                    return isFavoriteApp(cats, storageId);
                }
            }

            currentIndex: 0
            focus: visible
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = favoritesView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Favorites & Pinned");
            }
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
                isFavorite: true
            }

            navigationUp: typeof audioPill !== "undefined" ? audioPill : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null)
            navigationDown: recentView.visible ? recentView : (mediaView.visible ? mediaView : (appsView.visible ? appsView : settingsView))
        }

        // 1. RECENT ROW
        BigScreen.TileRepeater {
            id: recentView
            title: i18n("Recently Used")
            compactMode: plasmoid.configuration.expandingTiles
            model: Kicker.RecentUsageModel {
                shownItems: Kicker.RecentUsageModel.OnlyApps
            }

            visible: plasmoid.configuration.expandingTiles && count > 0
            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = recentView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Recently Used");
            }
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }

            navigationUp: favoritesView.visible ? favoritesView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null)
            navigationDown: mediaView.visible ? mediaView : (appsView.visible ? appsView : (gamesView.visible ? gamesView : settingsView))
        }

        // 2. VIDEOS & STREAMING MEDIA SHELF (Kodi Estuary Prime Media Shelf)
        BigScreen.TileRepeater {
            id: mediaView
            title: i18n("Videos & Streaming Channels")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    var cats = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole);
                    var storageId = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationStorageIdRole);
                    return isMediaApp(cats, storageId);
                }
            }

            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = mediaView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Videos & Streaming");
            }
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
                isWideCard: true
            }

            navigationUp: recentView.visible ? recentView : (favoritesView.visible ? favoritesView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null))
            navigationDown: gamesView.visible ? gamesView : (appsView.visible ? appsView : settingsView)
        }

        // 3. GAMES & ENTERTAINMENT SHELF
        BigScreen.TileRepeater {
            id: gamesView
            title: i18n("Games & Entertainment")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    var cats = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole);
                    if (cats && cats.indexOf("Game") !== -1) return true;
                    var storageId = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationStorageIdRole);
                    if (storageId) {
                        var sid = storageId.toString().toLowerCase();
                        if (sid.indexOf("retroarch") !== -1 || sid.indexOf("steam") !== -1 || sid.indexOf("lutris") !== -1 || sid.indexOf("heroic") !== -1) {
                            return true;
                        }
                    }
                    return false;
                }
            }

            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = gamesView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Games & Entertainment");
            }
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }
            
            navigationUp: mediaView.visible ? mediaView : (recentView.visible ? recentView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null))
            navigationDown: appsView.visible ? appsView : settingsView
        }

        // 4. MAIN APPLICATIONS & ADD-ONS SHELF
        BigScreen.TileRepeater {
            id: appsView
            title: i18n("Applications & Tools")
            compactMode: plasmoid.configuration.expandingTiles
            visible: count > 0
            enabled: count > 0
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    var cats = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole);
                    if (cats && (cats.indexOf("Game") !== -1 || cats.indexOf("VoiceApp") !== -1)) return false;
                    var storageId = sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationStorageIdRole);
                    if (storageId) {
                        var sid = storageId.toString().toLowerCase();
                        if (sid.indexOf("foot") !== -1 || sid.indexOf("term") !== -1 || sid.indexOf("ghostty") !== -1 || sid.indexOf("konsole") !== -1) {
                            return false;
                        }
                    }
                    if (mediaView.count > 0 && isMediaApp(cats, storageId)) return false;
                    return true;
                }
            }

            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = appsView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Applications & Tools");
            }
            delegate: Delegates.AppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }
            
            navigationUp: gamesView.visible ? gamesView : (mediaView.visible ? mediaView : (recentView.visible ? recentView : (typeof shutdownIndicator !== "undefined" ? shutdownIndicator : null)))
            navigationDown: voiceAppsView.visible ? voiceAppsView : settingsView
        }

        // 5. VOICE APPS ROW
        BigScreen.TileRepeater {
            id: voiceAppsView
            title: i18n("Voice & Assistant")
            compactMode: plasmoid.configuration.expandingTiles
            model: KItemModels.KSortFilterProxyModel {
                sourceModel: plasmoid.nativeInterface.applicationListModel
                filterRole: "ApplicationCategoriesRole"
                filterRowCallback: function(source_row, source_parent) {
                    return sourceModel.data(sourceModel.index(source_row, 0, source_parent), ApplicationListModel.ApplicationCategoriesRole).indexOf("VoiceApp") !== -1;
                }
            }

            visible: mycroftIntegration && count > 0
            currentIndex: 0
            focus: false
            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = voiceAppsView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Voice Apps");
            }
            delegate: Delegates.VoiceAppDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
            }

            navigationUp: appsView.visible ? appsView : (gamesView.visible ? gamesView : (mediaView.visible ? mediaView : (recentView.visible ? recentView : null)))
            navigationDown: settingsView
        }

        SettingActions {
            id: settingActions
        }
        
        // 6. SETTINGS ROW
        BigScreen.TileRepeater {
            id: settingsView
            title: i18n("Settings & System Preferences")
            model: plasmoid.nativeInterface.kcmsListModel
            compactMode: plasmoid.configuration.expandingTiles

            onActiveFocusChanged: if (activeFocus) {
                launcherHomeColumn.currentSection = settingsView;
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Settings & System");
            }
            delegate: Delegates.SettingDelegate {
                property var modelData: typeof model !== "undefined" ? model : null
                visible: model.active
                enabled: model.active
            }
            
            navigationUp: voiceAppsView.visible ? voiceAppsView : (appsView.visible ? appsView : (gamesView.visible ? gamesView : (mediaView.visible ? mediaView : null)))
            navigationDown: null
        }

        Component.onCompleted: {
            if (favoritesView.visible && favoritesView.count > 0) {
                favoritesView.forceActiveFocus();
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Favorites & Pinned");
            } else if (mediaView.visible && mediaView.count > 0) {
                mediaView.forceActiveFocus();
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Videos & Streaming");
            } else if (recentView.visible && recentView.count > 0) {
                recentView.forceActiveFocus();
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Recently Used");
            } else if (appsView.visible && appsView.count > 0) {
                appsView.forceActiveFocus();
                if (typeof root !== "undefined") root.currentSectionTitle = i18n("Applications & Tools");
            }
        }

        Connections {
            target: root
            onActivateAppView: {
                if (favoritesView.visible && favoritesView.count > 0) {
                    favoritesView.forceActiveFocus();
                    if (typeof root !== "undefined") root.currentSectionTitle = i18n("Favorites & Pinned");
                } else if (mediaView.visible && mediaView.count > 0) {
                    mediaView.forceActiveFocus();
                    if (typeof root !== "undefined") root.currentSectionTitle = i18n("Videos & Streaming");
                } else if (recentView.visible && recentView.count > 0) {
                    recentView.forceActiveFocus();
                    if (typeof root !== "undefined") root.currentSectionTitle = i18n("Recently Used");
                } else {
                    appsView.forceActiveFocus();
                    if (typeof root !== "undefined") root.currentSectionTitle = i18n("Applications & Tools");
                }
            }
        }
    }
}
