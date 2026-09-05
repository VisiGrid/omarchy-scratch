import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Grid.js" as Grid

// VisiGrid Scratch — a persistent drop-down spreadsheet for the Omarchy shell.
//
// The shell summons this overlay (`omarchy-shell shell toggle visigrid.scratch`).
// A headless VisiGrid engine (`vgrid serve`) owns the sheet; this file is only
// the view. Every edit is one JSONL op piped to `vgrid apply`, every refresh is
// one `vgrid inspect --json` of the visible range. The engine autosaves and is
// asked to save again whenever the overlay closes.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property bool opened: false

  // ---- settings (user-owned, survives plugin updates) --------------------
  readonly property string home: Quickshell.env("HOME")
  property string settingsPath: home + "/.config/visigrid/scratch.json"
  property string sheetPath: home + "/.local/state/visigrid/scratch.sheet"
  property string themeName: "phosphor"   // "phosphor" | "system"
  property int rows: 15
  property int colsSetting: 0             // 0 = fill the screen width
  readonly property int cols: colsSetting > 0 ? colsSetting : Math.max(3, Math.floor((panel.width - headW) / baseCellW))
  property string fontOverride: ""

  // ---- engine -------------------------------------------------------------
  readonly property string token: Grid.randomToken()
  property string sessionId: ""
  property string engineState: "starting"  // starting | ready | retrying | missing | paused
  property string engineError: ""
  property int restartDelay: 1000
  property bool suspended: false           // true while the real VisiGrid owns the file
  property bool launchAfterStop: false
  property int revision: -1

  // ---- viewport + cursor ---------------------------------------------------
  property int topRow: 0
  property int leftCol: 0
  property int activeRow: 0
  property int activeCol: 0
  property var grid: Grid.emptyGrid(rows, cols)
  property int gridVersion: 0
  property bool editing: false
  property string queuedOps: ""
  property string inflightOps: ""
  property bool inspectDirty: false
  readonly property int maxRows: 65536
  readonly property int maxCols: 256

  // ---- theme -----------------------------------------------------------------
  // Phosphor is VisiGrid's VisiCalc theme. System follows the Omarchy menu tokens.
  readonly property bool phosphor: themeName !== "system"
  readonly property color bg:          phosphor ? "#061206" : Color.menu.background
  readonly property color fg:          phosphor ? "#4af626" : Color.menu.text
  readonly property color fgDim:       phosphor ? "#2e9e2e" : Util.alpha(Color.menu.text, 0.55)
  readonly property color fgBright:    phosphor ? "#7cfc00" : Color.accent
  readonly property color headerBg:    phosphor ? "#0e260e" : Util.alpha(Color.menu.text, 0.06)
  readonly property color gridLine:    phosphor ? "#1d4d1d" : Util.alpha(Color.menu.border, 0.22)
  readonly property color selBg:       phosphor ? "#4af626" : Color.accent
  readonly property color selFg:       phosphor ? "#000000" : Color.menu.background
  readonly property color barBg:       phosphor ? "#0a1f0a" : Util.alpha(Color.menu.text, 0.04)
  readonly property color editorBg:    phosphor ? "#0a1a0a" : Color.menu.background
  readonly property color errFg:       phosphor ? "#ff5555" : Color.urgent
  readonly property color borderColor: phosphor ? "#2e9e2e" : Color.menu.border
  readonly property color scrim:       phosphor ? Qt.rgba(0, 0, 0, 0.55) : Color.menu.scrim
  readonly property string fontFamily: fontOverride || Style.font.menuFamily
  // Flush drop-down: no card border or padding, just a hairline under the sheet.
  readonly property int borderW: 0
  readonly property var borderSpec: Border.none()

  readonly property int baseCellW: Style.space(128)
  readonly property int cellW: Math.floor((panel.width - headW) / cols)
  readonly property int cellH: Style.space(32)
  readonly property int headW: Style.space(56)
  readonly property int pad: 0
  readonly property int gap: 0
  readonly property int barH: cellH + Style.space(6)
  readonly property int cellFont: Style.font.title
  readonly property int headFont: Style.font.body
  readonly property int edgePad: Style.space(10)
  readonly property int cardW: panel.width
  readonly property int cardH: Math.min(barH + gap + cellH * (rows + 1) + gap + cellH + pad * 2 + borderW * 2, panel.height - Style.gapsOut * 2)

  // ---- shell contract ---------------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    if (root.suspended) {
      root.suspended = false
      root.startEngine()
    } else {
      root.refresh()
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (root.editing) root.cancelEdit()
    root.opened = false
    if (root.sessionId && !root.suspended && root.engineState === "ready") saveProc.running = true
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ---- settings -------------------------------------------------------------------
  function loadSettings(raw) {
    var s = {}
    try { s = JSON.parse(raw) || {} } catch (e) { s = {} }
    root.themeName = s.theme === "system" ? "system" : "phosphor"
    root.fontOverride = typeof s.font === "string" ? s.font : ""
    var r = parseInt(s.rows), c = parseInt(s.cols)
    root.rows = isFinite(r) ? Math.max(5, Math.min(60, r)) : 15
    root.colsSetting = isFinite(c) && c > 0 ? Math.max(3, Math.min(26, c)) : 0
  }

  onRowsChanged: root.resizeGrid()
  onColsChanged: root.resizeGrid()

  function resizeGrid() {
    root.grid = Grid.emptyGrid(root.rows, root.cols)
    root.gridVersion++
    root.refresh()
  }

  // ---- engine lifecycle -----------------------------------------------------------
  // An empty or unreadable sheet (interrupted save) is moved aside, never fatal.
  readonly property string engineScript:
    'mkdir -p "$(dirname "$1")"\n' +
    'command -v vgrid >/dev/null 2>&1 || { echo "MISSING vgrid"; exit 127; }\n' +
    'if [ -s "$1" ]; then\n' +
    '  vgrid serve "$1" --autosave 5 --title Scratch; rc=$?\n' +
    '  [ "$rc" -eq 3 ] || exit "$rc"\n' +
    '  mv -f "$1" "$1.unreadable-$(date +%s)"\n' +
    '  echo "RECOVER moved unreadable sheet aside"\n' +
    'fi\n' +
    'rm -f "$1"\n' +
    'exec vgrid serve --new --save-as "$1" --autosave 5 --title Scratch\n'

  function startEngine() {
    if (engineProc.running) return
    root.sessionId = ""
    root.engineState = "starting"
    root.engineError = ""
    engineProc.running = true
  }

  function onEngineLine(line) {
    var m = /READY session_id=([0-9a-f-]+)/.exec(line)
    if (m) {
      root.sessionId = m[1]
      root.engineState = "ready"
      root.restartDelay = 1000
      root.flushOps()
      root.refresh()
      saveProc.running = true   // materialize the file right away
      return
    }
    if (/^MISSING/.test(line)) {
      root.engineState = "missing"
      return
    }
    if (/^error/i.test(line)) root.engineError = line
  }

  function onEngineExited(code) {
    root.sessionId = ""
    if (root.launchAfterStop) {
      root.launchAfterStop = false
      root.engineState = "paused"
      Quickshell.execDetached(["vgrid", "open", root.sheetPath])
      root.close()
      return
    }
    if (root.suspended) { root.engineState = "paused"; return }
    if (code === 127 || root.engineState === "missing") { root.engineState = "missing"; return }
    root.engineState = "retrying"
    restartTimer.interval = root.restartDelay
    root.restartDelay = Math.min(root.restartDelay * 2, 30000)
    restartTimer.restart()
  }

  function openInVisiGrid() {
    if (root.editing) root.commitEdit(0, 0)
    root.suspended = true
    root.launchAfterStop = true
    if (root.sessionId && root.engineState === "ready") {
      saveProc.running = true            // save -> stop engine -> launch GUI
    } else {
      engineProc.running = false
      if (!engineProc.running) root.onEngineExited(0)
    }
  }

  // ---- reads ---------------------------------------------------------------------------
  function refresh() {
    if (!root.sessionId || !root.opened) return
    if (inspectProc.running) { root.inspectDirty = true; return }
    inspectProc.running = true
  }

  function onInspect(text) {
    var parsed = Grid.parseRange(text, root.rows, root.cols)
    if (!parsed.ok) return
    root.grid = parsed.grid
    root.revision = parsed.revision
    root.gridVersion++
  }

  function cellAt(r, c) {
    var v = root.gridVersion
    var row = root.grid[r]
    return (row && row[c]) ? row[c] : { raw: "", display: "", formula: "" }
  }

  function activeCell() {
    return root.cellAt(root.activeRow - root.topRow, root.activeCol - root.leftCol)
  }

  // ---- writes --------------------------------------------------------------------------
  function queueOp(line) {
    root.queuedOps += line + "\n"
    root.flushOps()
  }

  function flushOps() {
    if (!root.sessionId || applyProc.running || root.queuedOps === "") return
    root.inflightOps = root.queuedOps
    root.queuedOps = ""
    applyProc.stdinEnabled = true
    applyProc.running = true
  }

  function setLocal(r, c, text) {
    var rr = r - root.topRow, cc = c - root.leftCol
    if (rr < 0 || cc < 0 || rr >= root.rows || cc >= root.cols) return
    var g = root.grid
    g[rr][cc] = { raw: text, display: text, formula: text.charAt(0) === "=" ? text : "" }
    root.grid = g
    root.gridVersion++
  }

  function writeCell(r, c, text) {
    root.setLocal(r, c, text)
    root.queueOp(Grid.opFor(r, c, text))
  }

  function clearCell() {
    root.writeCell(root.activeRow, root.activeCol, "")
  }

  // ---- editing ---------------------------------------------------------------------------
  function beginEdit(initial, selectAll) {
    root.editing = true
    editor.text = initial
    if (selectAll) editor.selectAll()
    else editor.cursorPosition = editor.text.length
    Qt.callLater(function() { editor.forceActiveFocus() })
  }

  function cancelEdit() {
    root.editing = false
    editor.text = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitEdit(dr, dc) {
    var text = editor.text
    root.editing = false
    editor.text = ""
    root.writeCell(root.activeRow, root.activeCol, text)
    root.move(dr, dc)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- navigation -------------------------------------------------------------------
  function move(dr, dc) {
    root.select(root.activeRow + dr, root.activeCol + dc)
  }

  function select(r, c) {
    r = Math.max(0, Math.min(root.maxRows - 1, r))
    c = Math.max(0, Math.min(root.maxCols - 1, c))
    root.activeRow = r
    root.activeCol = c
    var t = root.topRow, l = root.leftCol
    if (r < t) t = r
    if (r >= t + root.rows) t = r - root.rows + 1
    if (c < l) l = c
    if (c >= l + root.cols) l = c - root.cols + 1
    root.scrollTo(t, l)
  }

  function scrollTo(t, l) {
    t = Math.max(0, Math.min(root.maxRows - root.rows, t))
    l = Math.max(0, Math.min(root.maxCols - root.cols, l))
    if (t === root.topRow && l === root.leftCol) return
    root.topRow = t
    root.leftCol = l
    root.refresh()
  }

  function copyActive(raw) {
    var cell = root.activeCell()
    var text = raw ? (cell.raw || cell.display) : cell.display
    if (text === "") return
    Quickshell.execDetached(["wl-copy", "--", text])
  }

  function engineStatusText() {
    switch (root.engineState) {
    case "ready": return ""
    case "starting": return "starting vgrid…"
    case "retrying": return "engine stopped, retrying…"
    case "missing": return "vgrid not found — install visigrid-bin (AUR) or see visigrid.app"
    case "paused": return "paused — sheet is open in VisiGrid"
    }
    return root.engineState
  }

  function handleKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    switch (event.key) {
    case Qt.Key_Escape: root.close(); return true
    case Qt.Key_Left: root.move(0, -1); return true
    case Qt.Key_Right: root.move(0, 1); return true
    case Qt.Key_Up: root.move(-1, 0); return true
    case Qt.Key_Down: root.move(1, 0); return true
    case Qt.Key_Tab: root.move(0, 1); return true
    case Qt.Key_Backtab: root.move(0, -1); return true
    case Qt.Key_Return:
    case Qt.Key_Enter: root.move(shift ? -1 : 1, 0); return true
    case Qt.Key_PageDown: root.move(root.rows - 1, 0); return true
    case Qt.Key_PageUp: root.move(-(root.rows - 1), 0); return true
    case Qt.Key_Home:
      if (ctrl) root.select(0, 0); else root.select(root.activeRow, 0)
      return true
    case Qt.Key_F2: root.beginEdit(root.activeCell().raw, false); return true
    case Qt.Key_Delete:
    case Qt.Key_Backspace: root.clearCell(); return true
    }
    if (ctrl) {
      switch (event.key) {
      case Qt.Key_C: root.copyActive(shift); return true
      case Qt.Key_O: root.openInVisiGrid(); return true
      case Qt.Key_R: root.refresh(); return true
      }
      return false
    }
    if (event.text && event.text.length === 1) {
      var code = event.text.charCodeAt(0)
      if (code >= 32 && code !== 127) {
        root.beginEdit(event.text, false)
        return true
      }
    }
    return false
  }

  Component.onCompleted: initProc.running = true

  // ---- files ---------------------------------------------------------------------------------
  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("{}")
    onFileChanged: reload()
  }

  // ---- processes --------------------------------------------------------------------------
  // Reap an engine left behind by a previous shell instance before starting ours.
  Process {
    id: initProc
    command: ["pkill", "-f", "vgrid serve .*/visigrid/scratch\\.sheet"]
    onExited: root.startEngine()
  }

  Process {
    id: engineProc
    command: ["setpriv", "--pdeathsig", "TERM", "sh", "-c", root.engineScript, "sh", root.sheetPath]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdout: SplitParser { onRead: function(line) { root.onEngineLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.onEngineLine(line) } }
    onExited: function(code, status) { root.onEngineExited(code) }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: if (!root.suspended) root.startEngine()
  }

  Process {
    id: applyProc
    command: ["vgrid", "apply", "--session", root.sessionId, "-"]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdinEnabled: true
    onStarted: {
      applyProc.write(root.inflightOps)
      applyProc.stdinEnabled = false
    }
    property string lastStderr: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: applyProc.lastStderr = text.trim()
    }
    onExited: function(code, status) {
      root.inflightOps = ""
      root.engineError = code === 0 ? "" : (applyProc.lastStderr.split("\n").pop() || ("apply failed (" + code + ")"))
      root.flushOps()
      root.refresh()
    }
  }

  Process {
    id: inspectProc
    command: ["vgrid", "inspect", "--session", root.sessionId, "--json", Grid.rangeRef(root.topRow, root.leftCol, root.rows, root.cols)]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onInspect(text)
    }
    onExited: function(code, status) {
      if (root.inspectDirty) { root.inspectDirty = false; root.refresh() }
    }
  }

  Process {
    id: saveProc
    command: ["vgrid", "save", "--session", root.sessionId]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    onExited: function(code, status) {
      if (root.launchAfterStop) {
        if (engineProc.running) engineProc.running = false
        else root.onEngineExited(0)
      }
    }
  }

  // ---- window -----------------------------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "visigrid-scratch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: root.cardW
      height: root.cardH
      radius: Style.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 0
      color: root.bg
      borderSpec: root.borderSpec
      padding: root.pad

      // Hairline along the bottom edge so the sheet reads as a surface.
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.borderColor; z: 6 }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.editing) return
          if (root.handleKey(event)) event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.gap

        // Formula bar: cell reference + raw contents (or the live edit buffer).
        Rectangle {
          width: parent.width
          height: root.barH
          color: root.barBg
          Row {
            anchors.fill: parent
            anchors.leftMargin: root.edgePad
            anchors.rightMargin: root.edgePad
            spacing: Style.space(10)
            Text {
              width: root.headW + Style.space(16)
              height: parent.height
              text: Grid.cellRef(root.activeRow, root.activeCol)
              color: root.fgBright
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              verticalAlignment: Text.AlignVCenter
            }
            Rectangle { width: 1; height: parent.height - Style.space(8); anchors.verticalCenter: parent.verticalCenter; color: root.gridLine }
            Text {
              width: parent.width - root.headW - Style.space(30)
              height: parent.height
              text: root.editing ? editor.text : root.activeCell().raw
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
          }
        }

        // The grid.
        Item {
          id: gridArea
          width: parent.width
          height: root.cellH * (root.rows + 1)
          clip: true

          MouseArea {
            anchors.fill: parent
            z: -1
            onWheel: function(wheel) {
              var dy = wheel.angleDelta.y, dx = wheel.angleDelta.x
              if (dy !== 0) root.scrollTo(root.topRow + (dy < 0 ? 3 : -3), root.leftCol)
              if (dx !== 0) root.scrollTo(root.topRow, root.leftCol + (dx < 0 ? 1 : -1))
            }
          }

          Column {
            // Column headers.
            Row {
              Rectangle { width: root.headW; height: root.cellH; color: root.headerBg }
              Repeater {
                model: root.cols
                Rectangle {
                  required property int index
                  readonly property bool active: root.leftCol + index === root.activeCol
                  width: root.cellW
                  height: root.cellH
                  color: active ? root.selBg : root.headerBg
                  Text {
                    anchors.centerIn: parent
                    text: Grid.colName(root.leftCol + index)
                    color: parent.active ? root.selFg : root.fgDim
                    font.family: root.fontFamily
                    font.pixelSize: root.headFont
                  }
                  Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: root.gridLine }
                }
              }
            }

            // Rows.
            Repeater {
              model: root.rows
              Row {
                id: rowItem
                required property int index
                readonly property bool activeRow: root.topRow + index === root.activeRow

                Rectangle {
                  width: root.headW
                  height: root.cellH
                  color: rowItem.activeRow ? root.selBg : root.headerBg
                  Text {
                    anchors.centerIn: parent
                    text: String(root.topRow + rowItem.index + 1)
                    color: rowItem.activeRow ? root.selFg : root.fgDim
                    font.family: root.fontFamily
                    font.pixelSize: root.headFont
                  }
                  Rectangle { anchors.bottom: parent.bottom; height: 1; width: parent.width; color: root.gridLine }
                }

                Repeater {
                  model: root.cols
                  Rectangle {
                    id: cellItem
                    required property int index
                    readonly property var cell: root.cellAt(rowItem.index, index)
                    readonly property bool active: rowItem.activeRow && root.leftCol + index === root.activeCol
                    readonly property bool numeric: Grid.isNumeric(cell.display)
                    readonly property bool error: Grid.isError(cell.display)
                    width: root.cellW
                    height: root.cellH
                    color: active ? root.selBg : "transparent"

                    Text {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      visible: !(cellItem.active && root.editing)
                      text: cellItem.cell.display
                      color: cellItem.active ? root.selFg : (cellItem.error ? root.errFg : (cellItem.cell.formula ? root.fgBright : root.fg))
                      font.family: root.fontFamily
                      font.pixelSize: root.cellFont
                      horizontalAlignment: cellItem.numeric ? Text.AlignRight : Text.AlignLeft
                      verticalAlignment: Text.AlignVCenter
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                    }
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: root.gridLine }
                    Rectangle { anchors.bottom: parent.bottom; height: 1; width: parent.width; color: root.gridLine }

                    MouseArea {
                      anchors.fill: parent
                      onClicked: {
                        if (root.editing) root.commitEdit(0, 0)
                        root.select(root.topRow + rowItem.index, root.leftCol + cellItem.index)
                        keyCatcher.forceActiveFocus()
                      }
                      onDoubleClicked: {
                        root.select(root.topRow + rowItem.index, root.leftCol + cellItem.index)
                        root.beginEdit(root.activeCell().raw, false)
                      }
                    }
                  }
                }
              }
            }
          }

          // In-cell editor, floated over the active cell.
          Rectangle {
            id: editorBox
            visible: root.editing
            x: root.headW + (root.activeCol - root.leftCol) * root.cellW
            y: root.cellH + (root.activeRow - root.topRow) * root.cellH
            width: Math.min(root.cellW * 2, gridArea.width - x)
            height: root.cellH
            color: root.editorBg
            border.color: root.fgBright
            border.width: 1
            z: 5

            TextInput {
              id: editor
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              verticalAlignment: TextInput.AlignVCenter
              color: root.fgBright
              selectionColor: root.selBg
              selectedTextColor: root.selFg
              font.family: root.fontFamily
              font.pixelSize: root.cellFont
              selectByMouse: true
              clip: true
              Keys.onPressed: function(event) {
                var shift = event.modifiers & Qt.ShiftModifier
                switch (event.key) {
                case Qt.Key_Escape: root.cancelEdit(); event.accepted = true; return
                case Qt.Key_Return:
                case Qt.Key_Enter: root.commitEdit(shift ? -1 : 1, 0); event.accepted = true; return
                case Qt.Key_Tab: root.commitEdit(0, 1); event.accepted = true; return
                case Qt.Key_Backtab: root.commitEdit(0, -1); event.accepted = true; return
                case Qt.Key_Up: root.commitEdit(-1, 0); event.accepted = true; return
                case Qt.Key_Down: root.commitEdit(1, 0); event.accepted = true; return
                }
              }
            }
          }
        }

        // Status line.
        Item {
          width: parent.width
          height: root.cellH
          Text {
            anchors.left: parent.left
            anchors.leftMargin: root.edgePad
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter ↓  Tab →  F2 edit  Del clear  ^C copy  ^O open in VisiGrid  Esc close"
            color: root.fgDim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width * 0.62
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: root.edgePad
            anchors.verticalCenter: parent.verticalCenter
            text: root.engineError && root.engineState === "ready" ? root.engineError : root.engineStatusText()
            color: root.engineState === "ready" && !root.engineError ? root.fgDim : (root.engineState === "missing" || root.engineError ? root.errFg : root.fgDim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
            width: parent.width * 0.36
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }
}
