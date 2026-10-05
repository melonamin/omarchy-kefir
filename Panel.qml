import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "melonamin.kefir"
  ipcTarget: "melonamin.kefir"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so popout coordination has to identify as that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Speaker state ----
  // hostOverride bridges the gap between adopting a discovered speaker and
  // `omarchy bar set` round-tripping the value through shell.json.
  property string hostOverride: ""
  readonly property string host: hostOverride !== "" ? hostOverride : String(setting("host", "")).trim()
  readonly property bool configured: host !== ""

  // ---- Discovery (mDNS/avahi) ----
  property var discoveredSpeakers: []
  property bool discovering: false
  property bool reachable: false
  property int volume: 0
  property bool mutedFlag: false
  property string source: ""
  property string status: ""
  property string deviceName: ""
  property string playbackState: ""
  property string trackTitle: ""
  property string trackArtist: ""
  property string trackAlbum: ""
  property string coverUrl: ""
  property bool canPrevious: false
  property bool canPause: false
  property bool canNext: false
  property real durationMs: 0

  // Song position is polled, then advanced locally between polls while
  // playing so the progress bar moves smoothly.
  property real polledPositionMs: -1
  property real polledAtWallMs: 0
  property real nowMs: 0
  readonly property real positionMs: {
    if (polledPositionMs < 0) return -1
    var advanced = polledPositionMs + (playbackState === "playing" ? Math.max(0, nowMs - polledAtWallMs) : 0)
    return durationMs > 0 ? Math.min(durationMs, advanced) : advanced
  }
  readonly property bool hasProgress: durationMs > 0 && positionMs >= 0

  readonly property bool powered: status === "powerOn"
  readonly property bool hasMedia: powered
    && (trackTitle !== "" || coverUrl !== "" || canPause || canPrevious || canNext)
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
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
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
    // Power-on takes the speaker a couple of seconds, during which it still
    // reports standby; syncing then would snap the toggle back before it
    // flips on again. Hold the optimistic power/source until the speaker
    // confirms it (or the settle window runs out).
    if (powerSettleTimer.running
        && state.status === status
        && (source === "" || state.source === source)) {
      powerSettleTimer.stop()
    }
    if (!powerSettleTimer.running) {
      source = state.source
      status = state.status
    }
    playbackState = state.playbackState
    trackTitle = state.trackTitle
    trackArtist = state.trackArtist
    trackAlbum = state.trackAlbum
    coverUrl = state.coverUrl
    canPrevious = state.canPrevious
    canPause = state.canPause
    canNext = state.canNext
    durationMs = state.durationMs
    polledPositionMs = state.positionMs
    polledAtWallMs = Date.now()
    nowMs = polledAtWallMs
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
    powerSettleTimer.restart()
    sendSet("settings:/kef/play/physicalSource", "value", Model.sourcePayload(key))
    quickPollTimer.restart()
  }

  function setPower(on) {
    if (!reachable) return
    status = on ? "powerOn" : "standby"
    powerSettleTimer.restart()
    sendSet("settings:/kef/play/physicalSource", "value", Model.sourcePayload(on ? "powerOn" : "standby"))
    quickPollTimer.restart()
  }

  function transport(command) {
    if (!reachable || !powered) return
    sendSet("player:player/control", "activate", Model.controlPayload(command))
    quickPollTimer.restart()
  }

  function playPause() {
    if (canPause) transport("pause")
  }

  function startDiscovery() {
    if (discovering || discoverProc.running) return
    discovering = true
    discoveredSpeakers = []
    discoverProc.running = true
  }

  function adoptSpeaker(address) {
    hostOverride = String(address)
    if (bar) bar.run("omarchy bar set melonamin.kefir host " + Util.shellQuote(hostOverride))
    pollNow()
  }

  onOpenedChanged: if (opened && !configured) startDiscovery()

  function showVolumeOsd() {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: root.barIcon,
      value: root.volume
    }))
  }

  Process {
    id: discoverProc
    command: Model.discoverCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.discoveredSpeakers = Model.parseDiscovery(text)
        root.discovering = false
      }
    }
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

  // Long enough to outlast the speaker's 1-2s power transition plus one
  // poll round-trip; a confirming poll releases it early.
  Timer {
    id: powerSettleTimer
    interval: 5000
  }

  // Advance the progress bar between polls; only worth the wakeups while the
  // panel is actually showing a moving track.
  Timer {
    interval: 1000
    running: root.opened && root.playbackState === "playing" && root.hasProgress
    repeat: true
    onTriggered: root.nowMs = Date.now()
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

        // ---- Unconfigured: discover speakers on the network ----
        Column {
          visible: !root.configured
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SPEAKERS ON THIS NETWORK"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: root.discovering
            width: parent.width
            text: "Scanning…"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.discoveredSpeakers

            CursorSurface {
              id: speakerRow
              required property var modelData

              width: panelColumn.width
              bordered: true
              foreground: root.bar.foreground
              implicitHeight: speakerRowInner.implicitHeight + Style.spacing.xl

              Column {
                id: speakerRowInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(2)

                Text {
                  text: speakerRow.modelData.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: [speakerRow.modelData.model, speakerRow.modelData.address]
                    .filter(function(part) { return part !== "" }).join(" · ")
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: speakerRow.hasCursor = containsMouse
                onClicked: root.adoptSpeaker(speakerRow.modelData.address)
              }
            }
          }

          Text {
            visible: !root.discovering && root.discoveredSpeakers.length === 0
            width: parent.width
            text: "No KEF speakers found.\nSet one manually:\nomarchy bar set melonamin.kefir host <ip>"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Button {
            visible: !root.discovering
            text: "Scan again"
            iconText: "󰑐"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.startDiscovery()
          }
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
          visible: root.configured && root.hasMedia
          foreground: root.bar.foreground
        }

        Column {
          visible: root.configured && root.hasMedia
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "NOW PLAYING"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            BorderSurface {
              width: Style.space(64)
              height: Style.space(64)
              radius: Style.spacing.labelGap
              color: Style.normalFillFor(root.bar.foreground, Color.accent)
              borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                source: root.coverUrl
                visible: root.coverUrl !== "" && status !== Image.Error
              }

              Text {
                anchors.centerIn: parent
                visible: root.coverUrl === ""
                text: "󰝚"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }

            Column {
              spacing: Style.space(4)
              width: parent.width - Style.space(74)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: root.trackTitle || "Nothing playing"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.trackArtist
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
              }

              Text {
                text: root.trackAlbum
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
              }
            }
          }

          Column {
            visible: root.hasProgress
            width: parent.width
            spacing: Style.space(4)

            Rectangle {
              width: parent.width
              height: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
              radius: height / 2
              color: Style.selectedFillFor(root.bar.foreground, Color.accent)

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: root.bar.foreground
                width: parent.width * (root.durationMs > 0
                  ? Math.max(0, Math.min(1, root.positionMs / root.durationMs)) : 0)
              }
            }

            Item {
              width: parent.width
              implicitHeight: elapsedLabel.implicitHeight

              Text {
                id: elapsedLabel
                text: Model.formatTime(root.positionMs)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
              }

              Text {
                text: Model.formatTime(root.durationMs)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Button {
              iconText: "󰒮"
              foreground: root.bar.foreground
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              enabled: root.canPrevious
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.transport("previous")
            }

            Button {
              iconText: root.playbackState === "playing" ? "󰏤" : "󰐊"
              foreground: root.bar.foreground
              horizontalPadding: Style.spacing.panelGap
              verticalPadding: Style.spacing.controlPaddingY
              iconSize: Style.font.iconLarge
              enabled: root.canPause
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.playPause()
            }

            Button {
              iconText: "󰒭"
              foreground: root.bar.foreground
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              enabled: root.canNext
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.transport("next")
            }
          }
        }
      }
    }
  }
}
