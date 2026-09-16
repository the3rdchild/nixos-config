pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Mobile hotspot settings. Reached from the "Hotspot settings" row on
// NetworkPage. Name and password are stored in NetworkManager's Hotspot
// profile via `hotspot set`; nothing is kept in the shell config.
PageBase {
    id: root

    property bool showPassword

    readonly property string staSummary: {
        if (!Hotspot.staInterface)
            return qsTr("No Wi-Fi interface");
        if (!Hotspot.staChannel)
            return qsTr("%1 · not connected").arg(Hotspot.staInterface);
        const ghz = Hotspot.staFreq >= 5000 ? "5 GHz" : "2.4 GHz";
        return qsTr("%1 · %2 · channel %3").arg(Hotspot.staProfile || Hotspot.staInterface).arg(ghz).arg(Hotspot.staChannel);
    }

    title: qsTr("Mobile hotspot")
    isSubPage: true

    Component.onCompleted: Hotspot.refresh()

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Timer {
            running: root.visible
            repeat: true
            interval: 3000
            onTriggered: Hotspot.refresh()
        }

        ToggleRow {
            first: true
            text: qsTr("Mobile hotspot")
            subtext: Hotspot.enabled ? qsTr("On · %1 connected").arg(Hotspot.clients) : (Hotspot.starting ? qsTr("Starting…") : (Hotspot.stopping ? qsTr("Stopping…") : qsTr("Off")))
            font: Tokens.font.body.medium
            checked: Hotspot.enabled || Hotspot.starting
            disabled: Hotspot.busy || !Nmcli.wifiEnabled
            onToggled: Hotspot.setEnabled(checked)
        }

        TextFieldRow {
            label: qsTr("Network name")
            subtext: qsTr("1–32 characters. Changing it restarts the hotspot.")
            value: Hotspot.ssid
            maximumLength: 32
            onEditingFinished: value => {
                const v = value.trim();
                if (v.length > 0 && v !== Hotspot.ssid)
                    Hotspot.setSsid(v);
            }
        }

        TextFieldRow {
            id: passwordRow

            label: qsTr("Password")
            subtext: qsTr("WPA2, 8–63 characters. Changing it restarts the hotspot.")
            value: Hotspot.password
            maximumLength: 63
            field.echoMode: root.showPassword ? TextInput.Normal : TextInput.Password
            onEditingFinished: value => {
                if (value.length >= 8 && value !== Hotspot.password)
                    Hotspot.setPassword(value);
            }
        }

        ToggleRow {
            last: true
            text: qsTr("Show password")
            checked: root.showPassword
            onToggled: root.showPassword = checked
        }

        SectionHeader {
            text: qsTr("Status")
        }

        InfoRow {
            first: true
            icon: "wifi_tethering"
            label: qsTr("Hotspot")
            value: Hotspot.enabled ? Hotspot.bandLabel : qsTr("Off")
        }

        InfoRow {
            icon: "lan"
            label: qsTr("Gateway")
            subtext: qsTr("Clients get 10.42.0.x from NetworkManager")
            value: Hotspot.enabled && Hotspot.address ? Hotspot.address : "—"
        }

        InfoRow {
            icon: "cell_tower"
            label: qsTr("Uplink Wi-Fi")
            subtext: Hotspot.pinned ? qsTr("Pinned to 2.4 GHz while the hotspot is on") : qsTr("The hotspot shares this connection's channel")
            value: root.staSummary
        }

        InfoRow {
            last: true
            icon: "devices"
            label: qsTr("Connected devices")
            value: Hotspot.enabled ? String(Hotspot.clients) : "—"
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.small
            Layout.leftMargin: Tokens.padding.small
            visible: !!Hotspot.error
            text: Hotspot.error
            color: Colours.palette.m3error
            font: Tokens.font.body.small
            wrapMode: Text.WordWrap
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.small
            Layout.leftMargin: Tokens.padding.small
            text: qsTr("One radio serves both the uplink and the hotspot, so they must share a channel and the bandwidth is split. If the uplink sits on a 5 GHz DFS channel the hotspot cannot start there; it will move the Wi-Fi to 2.4 GHz and restore it when switched off.")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            wrapMode: Text.WordWrap
        }
    }
}
