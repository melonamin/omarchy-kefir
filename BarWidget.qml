import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "melonamin.kef"

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.barIcon : "󰓄"
    slotSize: Style.bar.statusSlot
    opacity: panelLoader.item && panelLoader.item.powered ? 1.0 : 0.6
    tooltipText: panelLoader.item ? panelLoader.item.barTooltip : ""

    onPressed: function(b) {
      var panel = panelLoader.item
      if (!panel) return
      if (b === Qt.RightButton) panel.toggleMute()
      else if (b === Qt.MiddleButton) panel.playPause()
      else root.togglePanel()
    }

    onWheelMoved: function(delta) {
      var panel = panelLoader.item
      if (!panel || !panel.reachable || !panel.powered) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      panel.adjustVolume(wheel.steps * 5)
      panel.showVolumeOsd()
    }
  }
}
