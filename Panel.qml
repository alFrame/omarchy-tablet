import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Wacom Bamboo Pen & Touch settings. Every control sends a patch to
// bin/tablet-ctl, which rewrites ~/.config/hypr/tablet.lua and reloads
// Hyprland, so changes take effect immediately and survive a reboot.
// Button mappings are picked up by the tablet-buttons user service
// (bin/tablet-buttons), which watches the same settings file.
Panel {
  id: root
  moduleName: "io.github.mug.tablet"
  ipcTarget: "tablet"

  property var settings_: ({})
  property var monitors: []
  property var area: ({ w: 147.2, h: 92, x: 0, y: 0 })
  property var tabletMm: ({ w: 147.2, h: 92 })
  property bool penPresent: false
  property bool fingerPresent: false
  property bool buttonsService: true
  property bool setupDone: true
  property bool evdevOk: true
  property bool wacomDriver: true
  property string error: ""
  property var pendingPatch: null
  property string tab: "pen"
  property bool editing: false
  property string flashButton: ""

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string uiFont: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool connected: penPresent || fingerPresent
  readonly property string home: Quickshell.env("HOME")

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return url.replace(/\/$/, "")
  }
  readonly property string helper: pluginDir + "/bin/tablet-ctl"

  readonly property var penActions: [
    { value: "default", label: "App default" },
    { value: "left", label: "Left click" },
    { value: "right", label: "Right click" },
    { value: "middle", label: "Middle click" },
    { value: "key", label: "Shortcut" },
    { value: "command", label: "Command" },
    { value: "none", label: "Disabled" }
  ]
  readonly property var padActions: penActions.slice(1)

  function s(key, fallback) {
    var v = settings_[key]
    return v === undefined ? fallback : v
  }

  function buttonSpec(key) {
    var b = settings_.buttons || {}
    return b[key] || { action: "none", value: "" }
  }

  function monitorOptions() {
    var opts = [{ value: "", label: "All" }]
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      var brand = String(m.description || "").split(" ")[0]
      opts.push({ value: m.name, label: brand || m.name, tooltip: m.name + " · " + m.description })
    }
    return opts
  }

  function applyStatus(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { return }
    if (!data) return
    // Keep optimistic values while a newer patch is still queued.
    if (!pendingPatch) settings_ = data.settings || {}
    monitors = data.monitors || []
    area = data.area || area
    tabletMm = data.tabletMm || tabletMm
    penPresent = !!data.pen
    fingerPresent = !!data.finger
    buttonsService = data.buttonsService !== false
    setupDone = data.setupDone !== false
    evdevOk = data.evdev !== false
    wacomDriver = data.wacomDriver !== false
    error = data.error || ""
  }

  function refresh() {
    if (setProc.running || statusProc.running) return
    statusProc.running = true
  }

  function mergePatch(base, patch) {
    var out = Object.assign({}, base || {})
    for (var k in patch) {
      if (k === "buttons") {
        var b = Object.assign({}, out.buttons || {})
        for (var bk in patch.buttons) b[bk] = Object.assign({}, b[bk] || {}, patch.buttons[bk])
        out.buttons = b
      } else {
        out[k] = patch[k]
      }
    }
    return out
  }

  // Optimistic update, then hand the patch to the helper. Patches that
  // arrive while one is being written are merged and sent as one.
  function send(patch) {
    settings_ = mergePatch(settings_, patch)
    pendingPatch = mergePatch(pendingPatch, patch)
    if (!setProc.running) flush()
  }

  function set(key, value) {
    var patch = {}
    patch[key] = value
    send(patch)
  }

  function setButton(key, spec) {
    var buttons = {}
    buttons[key] = spec
    send({ buttons: buttons })
  }

  function flush() {
    if (!pendingPatch) return
    setProc.command = [root.helper, "set", JSON.stringify(pendingPatch)]
    pendingPatch = null
    setProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      editing = false
      if (identifying) stopIdentify()
    }
  }
  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: root.flush()
  }

  Process {
    id: setupProc
    command: [root.helper, "setup"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: resetProc
    command: [root.helper, "reset"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  // tablet-buttons writes "<button> <time>" on every press; light up its row.
  // Polled only while the Buttons tab is showing.
  property string lastPress: ""

  function onPressLine(raw) {
    var line = String(raw || "").trim()
    if (line === "" || line === lastPress) return
    var first = lastPress === ""
    lastPress = line
    if (first) return
    var name = line.split(" ")[0]
    flashButton = name
    flashTimer.restart()
    if (identifying && name.indexOf("pad") === 0 && identifyOrder.indexOf(name) < 0) {
      var next = identifyOrder.concat([name])
      identifyOrder = next
      if (next.length === 4) {
        set("padOrder", next)
        stopIdentify()
      }
    }
  }

  // ---- "Identify keys": press the four keys top to bottom to learn their order.
  readonly property var positionNames: ["Top key", "Second key", "Third key", "Bottom key"]
  property bool identifying: false
  property var identifyOrder: []
  readonly property var padOrder: {
    var o = settings_.padOrder
    return (o && o.length === 4) ? o : ["pad1", "pad2", "pad3", "pad4"]
  }

  function startIdentify() {
    identifyOrder = []
    identifying = true
    flagProc.command = ["sh", "-c", "mkdir -p \"$HOME/.cache/omarchy-tablet\" && touch \"$HOME/.cache/omarchy-tablet/identify\""]
    flagProc.running = true
  }

  function stopIdentify() {
    identifying = false
    flagProc.running = false
    flagProc.command = ["rm", "-f", root.home + "/.cache/omarchy-tablet/identify"]
    flagProc.running = true
  }

  // Position (0 = top) of a pad key; while identifying, keys not pressed yet have none.
  function padPosition(key) {
    if (identifying) return identifyOrder.indexOf(key)
    return padOrder.indexOf(key)
  }

  Process { id: flagProc }

  Process {
    id: pressProc
    command: ["cat", root.home + "/.cache/omarchy-tablet/last-button"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.onPressLine(text) }
  }

  Timer {
    interval: 250
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.tab === "buttons"
    onTriggered: if (!pressProc.running) pressProc.running = true
  }

  Timer { id: flashTimer; interval: 900; onTriggered: root.flashButton = "" }

  // Plugging or unplugging the tablet is noticed on the next tick.
  Timer { interval: root.opened ? 3000 : 15000; running: true; repeat: true; onTriggered: root.refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    opacity: root.connected ? 1 : 0.45
    tooltipText: root.connected ? "Tablet" : "Tablet not connected"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Scrolls when the panel is taller than the display (Buttons tab).
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

      Column {
        id: column
        width: scroller.width
        spacing: Style.space(14)

        PanelHero {
          foreground: root.fg
          fontFamily: root.uiFont
          title: "Tablet"
          meta: root.connected ? "Bamboo CTH-460 · connected" : "Not connected"
          detail: root.penPresent ? "PEN" + (root.fingerPresent ? " + TOUCH" : "") : ""
          iconOpacity: root.connected ? 1 : 0.45
          iconComponent: Text {
            textFormat: Text.PlainText
            text: ""
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.font.display
          }
        }

        // First run / missing pieces.
        Column {
          visible: !root.setupDone || !root.evdevOk || !root.wacomDriver
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: !root.wacomDriver
              ? "The kernel wacom driver isn't loaded, so the tablet can't be seen. OpenTabletDriver blocks it; see the plugin README."
              : !root.evdevOk
                ? "Button remapping needs python-evdev. Install it with: omarchy pkg add python-evdev"
                : "One-time setup: adds hypr/tablet.lua to your Hyprland config and starts the tablet-buttons service."
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.setupDone && root.evdevOk
            anchors.right: parent.right
            text: setupProc.running ? "Setting up…" : "Finish setup"
            iconText: "\uf0ad"
            bordered: true
            foreground: root.fg
            fontFamily: root.uiFont
            fontSize: Style.font.bodySmall
            onClicked: if (!setupProc.running) setupProc.running = true
          }
        }

        Text {
          visible: root.error !== ""
          width: parent.width
          text: root.error
          color: Color.urgent
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ButtonGroup {
          id: tabs
          width: parent.width
          spacing: Style.space(6)
          focusable: false
          options: [
            { value: "pen", label: "Pen", icon: "" },
            { value: "touch", label: "Touch", icon: "" },
            { value: "buttons", label: "Buttons", icon: "" }
          ]
          value: root.tab
          foreground: root.fg
          fontFamily: root.uiFont
          fontSize: Style.font.bodySmall
          onChanged: function(v) { root.tab = v; root.editing = false; scroller.contentY = 0; keyCatcher.forceActiveFocus() }
        }

        PanelSeparator { foreground: root.fg }

        // ================= Pen =================
        Column {
          visible: root.tab === "pen"
          width: parent.width
          spacing: Style.space(14)

          Header { text: "TARGET DISPLAY" }
          ButtonGroup {
            width: parent.width
            spacing: Style.space(6)
            focusable: false
            options: root.monitorOptions()
            value: String(root.s("output", ""))
            foreground: root.fg
            fontFamily: root.uiFont
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.set("output", v) }
          }

          Header { text: "ROTATION" }
          ButtonGroup {
            width: parent.width
            spacing: Style.space(6)
            focusable: false
            options: [
              { value: "0", label: "0°", tooltip: "Normal" },
              { value: "90", label: "90°" },
              { value: "180", label: "180°", tooltip: "Upside down (left-handed)" },
              { value: "270", label: "270°" }
            ]
            value: String(root.s("rotation", 0))
            foreground: root.fg
            fontFamily: root.uiFont
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.set("rotation", parseInt(v)) }
          }

          SliderRow {
            title: "ACTIVE AREA"
            minimum: 30
            maximum: 100
            step: 5
            integer: true
            value: root.s("areaPercent", 100)
            valueText: Math.round(liveValue) + "% · " + root.area.w + "×" + root.area.h + " mm"
            onCommit: function(v) { root.set("areaPercent", Math.round(v)) }
          }

          // Scale drawing of the tablet surface with the active area inside.
          Item {
            width: parent.width
            height: Style.space(84)

            Rectangle {
              id: surface
              readonly property real k: Math.min(parent.width / root.tabletMm.w, parent.height / root.tabletMm.h)
              width: root.tabletMm.w * k
              height: root.tabletMm.h * k
              anchors.centerIn: parent
              color: "transparent"
              radius: Style.cornerRadius
              border.width: 1
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)

              Rectangle {
                x: root.area.x * surface.k
                y: root.area.y * surface.k
                width: root.area.w * surface.k
                height: root.area.h * surface.k
                radius: Style.cornerRadius
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
                border.width: 1
                border.color: root.fg
                Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              }
            }
          }

          SwitchRow {
            label: "Match display aspect ratio"
            description: "Circles stay round instead of stretched"
            checked: root.s("matchAspect", true) === true
            onToggled: root.set("matchAspect", !checked)
          }

          SliderRow {
            title: "PRESSURE SENSITIVITY"
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.s("pressure", 0)
            valueText: liveValue <= 0 ? "Normal" : "+" + Math.round(liveValue) + "%"
            onCommit: function(v) { root.set("pressure", Math.round(v)) }
          }
        }

        // ================= Touch =================
        Column {
          visible: root.tab === "touch"
          width: parent.width
          spacing: Style.space(14)

          SwitchRow {
            label: "Finger touch"
            description: "Turn off to rest your hand while drawing"
            checked: root.s("fingerEnabled", true) === true
            onToggled: root.set("fingerEnabled", !checked)
          }

          Column {
            width: parent.width
            spacing: Style.space(14)
            enabled: root.s("fingerEnabled", true) === true
            opacity: enabled ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: 140 } }

            SliderRow {
              title: "POINTER SPEED"
              minimum: -1
              maximum: 1
              step: 0.1
              value: root.s("fingerSpeed", 0)
              valueText: (liveValue > 0 ? "+" : "") + Number(liveValue).toFixed(1)
              onCommit: function(v) { root.set("fingerSpeed", Math.round(v * 10) / 10) }
            }

            SwitchRow {
              label: "Tap to click"
              checked: root.s("tapToClick", true) === true
              onToggled: root.set("tapToClick", !checked)
            }

            SwitchRow {
              label: "Natural scrolling"
              description: "Two-finger scroll moves the content, like a phone"
              checked: root.s("naturalScroll", true) === true
              onToggled: root.set("naturalScroll", !checked)
            }
          }
        }

        // ================= Buttons =================
        Column {
          visible: root.tab === "buttons"
          width: parent.width
          spacing: Style.space(12)

          Text {
            width: parent.width
            text: root.buttonsService
              ? "Press any pen or tablet button: its picture and row light up."
              : "The tablet-buttons service is not running, so mappings won't apply. Start it with: systemctl --user start tablet-buttons"
            color: root.buttonsService ? root.dim : Color.urgent
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Header { text: "PEN SIDE BUTTONS" }
          PenDiagram { width: parent.width }
          ButtonRow { key: "pen1"; label: "Lower button"; hint: "near the tip"; options: root.penActions }
          ButtonRow { key: "pen2"; label: "Upper button"; hint: "further from the tip"; options: root.penActions }

          PanelSeparator { foreground: root.fg }

          Item {
            width: parent.width
            implicitHeight: identifyButton.implicitHeight

            Header {
              text: "TABLET EXPRESSKEYS"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: identifyButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.identifying ? "Cancel" : "Identify keys"
              iconText: root.identifying ? "" : ""
              bordered: true
              foreground: root.fg
              fontFamily: root.uiFont
              fontSize: Style.font.caption
              onClicked: root.identifying ? root.stopIdentify() : root.startIdentify()
            }
          }

          TabletDiagram { width: parent.width }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.identifying
              ? "Press the " + root.positionNames[root.identifyOrder.length].toUpperCase()
                + " on the tablet  (" + (root.identifyOrder.length + 1) + "/4)\nKey actions are paused until you finish."
              : "Hold the tablet with its keys on the left. Wrong order? Use Identify keys."
            color: root.identifying ? root.fg : root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
            font.bold: root.identifying
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.padOrder
            ButtonRow {
              required property var modelData
              required property int index
              key: modelData
              label: root.positionNames[index]
              options: root.padActions
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        Button {
          anchors.right: parent.right
          text: "Reset to defaults"
          iconText: ""
          bordered: true
          foreground: root.fg
          fontFamily: root.uiFont
          fontSize: Style.font.bodySmall
          onClicked: if (!resetProc.running) resetProc.running = true
        }
      }
      }
    }
  }

  component Header: PanelSectionHeader {
    foreground: root.fg
    fontFamily: root.uiFont
  }

  component SliderRow: Column {
    id: sliderRow
    property string title: ""
    property string valueText: ""
    property alias value: slider.value
    property alias minimum: slider.minimum
    property alias maximum: slider.maximum
    property alias step: slider.step
    property alias integer: slider.integer
    readonly property real liveValue: slider.dragging ? slider.liveValue : slider.value
    signal commit(real value)

    width: parent.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(sliderTitle.implicitHeight, sliderValue.implicitHeight)

      Header {
        id: sliderTitle
        text: sliderRow.title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: sliderValue
        textFormat: Text.PlainText
        text: sliderRow.valueText
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      onReleased: function(v) { sliderRow.commit(v) }
    }
  }

  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string description: ""
    property bool checked: false
    signal toggled()

    width: parent.width
    implicitHeight: Math.max(labels.implicitHeight, sw.implicitHeight)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: sw.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: switchRow.label
        width: parent.width
        color: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: switchRow.description !== ""
        text: switchRow.description
        width: parent.width
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: sw
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      trackHeight: Style.space(18)
      foreground: root.fg
      checked: switchRow.checked
      onToggled: switchRow.toggled()
    }

    MouseArea {
      anchors.left: parent.left
      anchors.right: sw.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      cursorShape: Qt.PointingHandCursor
      onClicked: switchRow.toggled()
    }
  }

  // One remappable button: name, action picker, and a text field for the
  // shortcut or command when the action needs one. Flashes on press.
  component ButtonRow: Item {
    id: buttonRow
    property string key: ""
    property string label: ""
    property string hint: ""
    property var options: []
    readonly property var spec: root.buttonSpec(key)
    readonly property bool needsValue: spec.action === "key" || spec.action === "command"
    readonly property bool flashing: root.flashButton === key

    width: parent.width
    implicitHeight: rowContent.implicitHeight + Style.space(8)

    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, buttonRow.flashing ? 0.16 : 0)
      Behavior on color { ColorAnimation { duration: buttonRow.flashing ? 60 : 400 } }
    }

    Column {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: picker.implicitHeight

        Column {
          anchors.left: parent.left
          anchors.right: picker.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            text: buttonRow.label
            width: parent.width
            elide: Text.ElideRight
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            font.bold: buttonRow.flashing
          }

          Text {
            textFormat: Text.PlainText
            visible: buttonRow.hint !== ""
            text: buttonRow.hint
            width: parent.width
            elide: Text.ElideRight
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
          }
        }

        Dropdown {
          id: picker
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(170)
          showLabel: false
          options: buttonRow.options
          value: String(buttonRow.spec.action)
          foreground: root.fg
          fontFamily: root.uiFont
          onChanged: function(v) {
            var next = { action: v }
            if (v === "key" && buttonRow.spec.action !== "key") next.value = "ctrl+z"
            if (v === "command" && buttonRow.spec.action !== "command") next.value = ""
            root.setButton(buttonRow.key, next)
          }
        }
      }

      TextField {
        visible: buttonRow.needsValue
        width: parent.width
        text: String(buttonRow.spec.value || "")
        placeholderText: buttonRow.spec.action === "key" ? "e.g. ctrl+z, ctrl+shift+s, super+w" : "e.g. omarchy launch browser"
        foreground: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.bodySmall
        onActiveFocusChanged: root.editing = activeFocus
        onEditingFinished: if (text !== String(buttonRow.spec.value || "")) root.setButton(buttonRow.key, { value: text })
        Keys.onEscapePressed: keyCatcher.forceActiveFocus()
      }
    }
  }

  // Pen seen from the side, tip on the left; side buttons light up on press.
  component PenDiagram: Item {
    id: penDiagram
    implicitHeight: Style.space(54)

    readonly property real bodyW: Math.min(width, Style.space(300))
    readonly property real tipW: Style.space(34)
    readonly property real bodyH: Style.space(14)

    Item {
      id: pen
      width: penDiagram.bodyW
      height: penDiagram.bodyH
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.space(8)

      Canvas {
        id: tip
        width: penDiagram.tipW
        height: parent.height
        property color c: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
        onCChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.fillStyle = c
          ctx.beginPath()
          ctx.moveTo(0, height / 2)
          ctx.lineTo(width, 0)
          ctx.lineTo(width, height)
          ctx.closePath()
          ctx.fill()
        }
      }

      Rectangle {
        id: barrel
        x: tip.width
        width: parent.width - tip.width
        height: parent.height
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
        border.width: 1
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
      }

      Repeater {
        model: [{ key: "pen1", x: 0.16 }, { key: "pen2", x: 0.40 }]
        Rectangle {
          required property var modelData
          readonly property bool lit: root.flashButton === modelData.key
          x: barrel.x + barrel.width * modelData.x
          y: -height / 2 + 1
          width: Style.space(24)
          height: Style.space(9)
          radius: height / 2
          color: lit ? root.fg : Color.background
          border.width: 1
          border.color: root.fg
          Behavior on color { ColorAnimation { duration: lit ? 60 : 400 } }
        }
      }
    }

    Repeater {
      model: [{ key: "pen1", x: 0.16, label: "Lower" }, { key: "pen2", x: 0.40, label: "Upper" }]
      Text {
        required property var modelData
        textFormat: Text.PlainText
        text: modelData.label
        x: pen.x + barrel.x + barrel.width * modelData.x + Style.space(12) - width / 2
        y: pen.y + pen.height + Style.space(8)
        color: root.flashButton === modelData.key ? root.fg : root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        font.bold: root.flashButton === modelData.key
      }
    }

    Text {
      textFormat: Text.PlainText
      text: "tip"
      x: pen.x
      y: pen.y + pen.height + Style.space(8)
      color: root.dim
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
    }
  }

  // Tablet seen from above, ExpressKeys down the left edge around the LED.
  // Key numbers are positions (1 = top); a key lights up when pressed and the
  // one "Identify keys" is waiting for is outlined in the accent colour.
  component TabletDiagram: Item {
    id: tabletDiagram
    implicitHeight: body.height + Style.space(4)

    Rectangle {
      id: body
      width: Math.min(tabletDiagram.width, Style.space(250))
      height: width * 0.56
      anchors.horizontalCenter: parent.horizontalCenter
      radius: Style.space(12)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
      border.width: 1
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)

      readonly property real keyW: width * 0.10
      readonly property real keyH: height * 0.14
      readonly property real keyGap: height * 0.04
      readonly property real ledGap: height * 0.12
      readonly property real stackH: keyH * 4 + keyGap * 2 + ledGap * 2
      readonly property real stackTop: (height - stackH) / 2

      function keyY(p) {
        var y = stackTop + p * keyH
        if (p >= 1) y += keyGap
        if (p >= 2) y += ledGap * 2
        if (p >= 3) y += keyGap
        return y
      }

      // Status LED between the two key pairs.
      Rectangle {
        width: body.keyW * 0.3
        height: width
        radius: width / 2
        x: body.width * 0.06 + (body.keyW - width) / 2
        y: body.keyY(2) - body.ledGap - height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4)
      }

      Repeater {
        model: 4
        Rectangle {
          required property int index
          readonly property string code: root.identifying ? (root.identifyOrder[index] || "") : root.padOrder[index]
          readonly property bool lit: code !== "" && root.flashButton === code
          readonly property bool waiting: root.identifying && index === root.identifyOrder.length
          readonly property bool done: root.identifying && index < root.identifyOrder.length

          x: body.width * 0.06
          y: body.keyY(index)
          width: body.keyW
          height: body.keyH
          radius: Style.space(4)
          color: lit ? root.fg : (done ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3) : Color.background)
          border.width: waiting ? 2 : 1
          border.color: waiting ? Color.accent : root.fg
          Behavior on color { ColorAnimation { duration: lit ? 60 : 400 } }

          SequentialAnimation on opacity {
            running: waiting
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: String(index + 1)
            color: parent.lit ? Color.background : root.fg
            font.family: root.uiFont
            font.pixelSize: Math.max(8, parent.height * 0.62)
            font.bold: true
          }
        }
      }

      // Drawing surface.
      Rectangle {
        x: body.width * 0.24
        y: body.height * 0.12
        width: body.width * 0.70
        height: body.height * 0.76
        radius: Style.space(6)
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "drawing area"
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
