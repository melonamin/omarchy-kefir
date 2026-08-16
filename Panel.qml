import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "melonamin.kef"
  ipcTarget: "melonamin.kef"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so popout coordination has to identify as that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Speaker state ----
  readonly property string host: String(setting("host", "")).trim()
  readonly property bool configured: host !== ""
  property bool reachable: false
  property int volume: 0
  property bool mutedFlag: false
  property string source: ""
  property string status: ""
  property string deviceName: ""
  property string playbackState: ""
  property string trackTitle: ""
  property string trackArtist: ""

  readonly property bool powered: status === "powerOn"
  readonly property bool muted: mutedFlag || (reachable && powered && volume === 0)
  // Restored on unmute; mute-by-zero-volume is how Kefir/SwiftKEF mute too.
  property int lastAudibleVolume: 20
  property int pendingVolume: -1

  readonly property string barIcon: Model.speakerIcon(configured, reachable, powered, muted)
  readonly property string statusText: Model.statusLine(configured, reachable, powered, source, playbackState)
  readonly property string barTooltip: Model.tooltip(deviceName, statusText)

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.pollNow()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.pollNow()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Speaker I/O ----

  function pollNow() {
    if (!configured || pollProc.running) return
    pollProc.command = Model.pollCommand(host)
    pollProc.running = true
  }

  function applyPoll(raw) {
    var state = Model.parsePoll(raw)
    if (!state) {
      reachable = false
      return
    }
    reachable = true
    // Leave the volume alone while a local change is still settling; the
    // speaker echoes stale values for a beat after a set.
    if (state.volume !== null && !volumeSettleTimer.running && !volumeSlider.dragging)
      volume = state.volume
    if (volume > 0) lastAudibleVolume = volume
    mutedFlag = state.muted
    source = state.source
    status = state.status
    playbackState = state.playbackState
    trackTitle = state.trackTitle
    trackArtist = state.trackArtist
    if (state.deviceName !== "") deviceName = state.deviceName
  }

  function sendSet(path, roles, payload) {
    if (!configured) return
    Quickshell.execDetached(Model.setCommand(host, path, roles, payload))
  }

  function sendVolume(v) {
    sendSet("player:volume", "value", Model.volumePayload(v))
  }

  // Leading-edge throttle: the first move sends immediately, later moves
  // within the window coalesce into one trailing send.
  function setVolume(v) {
    var next = Model.clampVolume(v)
    volume = next
    if (next > 0) lastAudibleVolume = next
    volumeSettleTimer.restart()
    if (volumeThrottle.running) {
      pendingVolume = next
    } else {
      sendVolume(next)
      volumeThrottle.restart()
    }
  }

  function adjustVolume(delta) {
    if (!reachable || !powered) return
    setVolume(volume + delta)
  }

  function toggleMute() {
    if (!reachable || !powered) return
    if (muted) setVolume(lastAudibleVolume > 0 ? lastAudibleVolume : 20)
    else setVolume(0)
  }

  function setSource(key) {
    if (!reachable) return
    source = key
    status = "powerOn"  // selecting a source wakes the speaker
    sendSet("settings:/kef/play/physicalSource", "value", Model.sourcePayload(key))
    quickPollTimer.restart()
  }

  function setPower(on) {
    if (!reachable) return
    status = on ? "powerOn" : "standby"
    sendSet("settings:/kef/play/physicalSource", "value", Model.sourcePayload(on ? "powerOn" : "standby"))
    quickPollTimer.restart()
  }

  function transport(command) {
    if (!reachable || !powered) return
    sendSet("player:player/control", "activate", Model.controlPayload(command))
    quickPollTimer.restart()
  }

  function playPause() {
    transport("pause")
  }

  function showVolumeOsd() {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: root.barIcon,
      value: root.volume
    }))
  }

  Process {
    id: pollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reachable = false
    }
  }

  // Slow heartbeat keeps the bar icon honest; the panel being open tightens it.
  Timer {
    interval: root.opened ? 2000 : 20000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollNow()
  }

  // Confirm state shortly after a set; power/source changes take a moment.
  Timer {
    id: quickPollTimer
    interval: 900
    onTriggered: root.pollNow()
  }

  Timer {
    id: volumeThrottle
    interval: 150
    onTriggered: {
      if (root.pendingVolume >= 0) {
        root.sendVolume(root.pendingVolume)
        root.pendingVolume = -1
        volumeThrottle.restart()
      }
    }
  }

  Timer {
    id: volumeSettleTimer
    interval: 1500
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function volumeUp(): void { root.adjustVolume(5) }
    function volumeDown(): void { root.adjustVolume(-5) }
    function mute(): void { root.toggleMute() }
    function playPause(): void { root.playPause() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.adjustVolume(dx * 5)
      }
      onActivateRequested: root.playPause()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") root.toggleMute()
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---- Hero: speaker · name/status · power switch ----
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            text: root.barIcon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.powered ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.powered
            busy: !root.reachable
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setPower(!root.powered)

            PanelToolTip {
              visible: powerSwitch.containsMouse && root.reachable
              text: root.powered ? "Standby" : "Power on"
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.deviceName || "KEF Speaker"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---- Unconfigured hint ----
        Text {
          visible: !root.configured
          width: parent.width
          text: "Set the speaker IP to get started:\n\nomarchy bar set melonamin.kef host <ip>"
          color: Qt.darker(root.bar.foreground, 1.2)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        // ---- Volume ----
        PanelSeparator {
          visible: root.configured
          foreground: root.bar.foreground
        }

        Column {
          visible: root.configured
          width: parent.width
          spacing: Style.space(6)
          opacity: root.reachable && root.powered ? 1.0 : 0.5

          Item {
            width: parent.width
            implicitHeight: Math.max(volumeHeader.implicitHeight, volumePercent.implicitHeight)

            PanelSectionHeader {
              id: volumeHeader
              text: "VOLUME"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: volumePercent
              text: Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.volume) + "%"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              opacity: root.muted ? 0.5 : 1.0
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              iconText: root.muted ? "󰝟" : "󰕾"
              tooltipText: root.muted ? "Unmute" : "Mute"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: root.reachable && root.powered
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.toggleMute()
            }

            PanelSlider {
              id: volumeSlider
              bar: root.bar
              width: parent.width - Style.space(22) - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.volume
              opacity: root.muted ? 0.5 : 1.0
              enabled: root.reachable && root.powered

              onMoved: function(v) { root.setVolume(v) }
              onRightClicked: root.toggleMute()
            }
          }
        }

        // ---- Source ----
        PanelSeparator {
          visible: root.configured
          foreground: root.bar.foreground
        }

        Column {
          visible: root.configured
          width: parent.width
          spacing: Style.space(10)
          opacity: root.reachable ? 1.0 : 0.5

          PanelSectionHeader {
            text: "SOURCE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: Model.SOURCES

              CursorSurface {
                id: sourcePill
                required property var modelData

                readonly property bool isActive: root.powered && root.source === modelData.key
                current: isActive
                bordered: true
                foreground: root.bar.foreground
                implicitWidth: sourceLabel.implicitWidth + Style.space(24)
                implicitHeight: sourceLabel.implicitHeight + Style.space(12)

                Text {
                  id: sourceLabel
                  anchors.centerIn: parent
                  text: sourcePill.modelData.label
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: sourcePill.isActive
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.reachable ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onContainsMouseChanged: sourcePill.hasCursor = containsMouse
                  onClicked: root.setSource(sourcePill.modelData.key)
                }
              }
            }
          }
        }

        // ---- Now playing ----
        PanelSeparator {
          visible: root.configured && root.powered && Model.supportsPlayback(root.source)
          foreground: root.bar.foreground
        }

        Column {
          visible: root.configured && root.powered && Model.supportsPlayback(root.source)
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "NOW PLAYING"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: root.trackTitle !== ""
            width: parent.width
            text: root.trackTitle
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: root.trackArtist !== ""
            width: parent.width
            text: root.trackArtist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(16)

            PanelActionButton {
              iconText: "󰒮"
              tooltipText: "Previous"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.transport("previous")
            }

            PanelActionButton {
              iconText: root.playbackState === "playing" ? "󰏤" : "󰐊"
              tooltipText: root.playbackState === "playing" ? "Pause" : "Play"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.playPause()
            }

            PanelActionButton {
              iconText: "󰒭"
              tooltipText: "Next"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.transport("next")
            }
          }
        }
      }
    }
  }
}
