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
  property int colsSetting: 0             // 0 = as many as the width holds
  property string widthSetting: "full"    // "full" | "fit" | "60%" | pixels
  property string widthOverride: ""       // F11 toggles full/fit for this session
  readonly property string widthMode: widthOverride || widthSetting
  readonly property int cols: colsSetting > 0 ? colsSetting : Math.max(3, Math.floor((cardW - headW) / baseCellW))
  property string fontOverride: ""
  property bool vimSetting: false
  property int vimOverride: -1            // F12 toggles for this session: -1 follow setting, 0 off, 1 on
  readonly property bool vimMode: vimOverride === -1 ? vimSetting : vimOverride === 1
  property string pendingKey: ""          // "g" while waiting for the second g

  // ---- engine -------------------------------------------------------------
  // The engine is a detached `vgrid serve` managed by engine.sh; the plugin
  // adopts it across shell restarts via the pid and token kept beside the sheet.
  property string token: ""
  property string sessionId: ""
  property string enginePid: ""
  property string engineState: "starting"  // starting | ready | retrying | missing | paused
  property string engineError: ""
  property int restartDelay: 1000
  property bool suspended: false           // true while the real VisiGrid owns the file
  property bool launchAfterStop: false
  property int revision: -1
  readonly property string engineScriptPath: Qt.resolvedUrl("engine.sh").toString().replace(/^file:\/\//, "")
  property string ctlAction: "ensure"
  property bool ctlGotSession: false

  // ---- viewport + cursor ---------------------------------------------------
  property int topRow: 0
  property int leftCol: 0
  property int activeRow: 0
  property int activeCol: 0
  // Selection: anchor..active, or an explicit region from Ctrl+A.
  property int selAnchorRow: 0
  property int selAnchorCol: 0
  property var regionSel: null
  readonly property int stripMaxRows: 1000
  readonly property int rangeMaxCells: 20000
  property var rangeCallback: null
  property string rangeRequest: ""
  property var grid: Grid.emptyGrid(rows, cols)
  property int gridVersion: 0
  property bool editing: false
  property string queuedOps: ""
  property string inflightOps: ""
  property bool inspectDirty: false
  property string inflightRange: ""
  // Point mode: picking cell references into a formula with arrows or the mouse.
  property bool pointing: false
  property int pointAnchorRow: 0
  property int pointAnchorCol: 0
  property int pointRow: 0
  property int pointCol: 0
  property int refPos: 0                  // where the live reference starts in the editor text
  property int refLen: 0
  property int inflightRows: 0
  property int inflightCols: 0
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
  readonly property int cellW: Math.floor((cardW - headW) / cols)
  readonly property int cellH: Style.space(32)
  readonly property int headW: Style.space(56)
  readonly property int pad: 0
  readonly property int gap: 0
  readonly property int barH: cellH + Style.space(6)
  readonly property int cellFont: Style.font.title
  readonly property int headFont: Style.font.body
  readonly property int edgePad: Style.space(10)
  readonly property int cardW: {
    var w = root.widthMode, px
    if (w === "fit") px = headW + (colsSetting > 0 ? colsSetting : 10) * baseCellW
    else if (/^\d+%$/.test(w)) px = Math.round(panel.width * parseInt(w) / 100)
    else if (/^\d+$/.test(w)) px = parseInt(w)
    else px = panel.width
    return Math.max(headW + 3 * baseCellW, Math.min(px, panel.width))
  }
  readonly property int cardH: Math.min(barH + gap + cellH * (rows + 1) + gap + cellH + pad * 2 + borderW * 2, panel.height - Style.gapsOut * 2)

  // ---- shell contract ---------------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    root.suspended = false
    if (!root.sessionId) root.startEngine()
    else root.refresh()
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
    root.vimSetting = s.vim === true
    root.vimOverride = -1
    var r = parseInt(s.rows), c = parseInt(s.cols)
    root.rows = isFinite(r) ? Math.max(5, Math.min(60, r)) : 15
    root.colsSetting = isFinite(c) && c > 0 ? Math.max(3, Math.min(26, c)) : 0
    root.widthSetting = typeof s.width === "string" || typeof s.width === "number" ? String(s.width).trim() : "full"
  }

  onRowsChanged: root.resizeGrid()
  onColsChanged: root.resizeGrid()

  function resizeGrid() {
    root.grid = Grid.emptyGrid(root.rows, root.cols)
    root.gridVersion++
    root.refresh()
  }

  // ---- engine lifecycle -----------------------------------------------------------
  function startEngine() {
    if (ctlProc.running) return
    root.engineState = root.sessionId ? root.engineState : "starting"
    root.engineError = ""
    root.ctlAction = "ensure"
    root.ctlGotSession = false
    ctlProc.running = true
  }

  function onCtlLine(line) {
    var m = /^SESSION=(\S+) TOKEN=(\S+) PID=(\d+)/.exec(line)
    if (m) {
      root.sessionId = m[1]
      root.token = m[2]
      root.enginePid = m[3]
      root.ctlGotSession = true
      root.engineState = "ready"
      root.restartDelay = 1000
      root.flushOps()
      root.refresh()
      saveProc.running = true   // materialize the file right away
      return
    }
    if (/^MISSING/.test(line)) { root.engineState = "missing"; return }
    if (/^FAILED/.test(line)) { root.engineError = line.replace(/^FAILED\s*/, ""); return }
  }

  function onCtlExited(code) {
    if (root.ctlAction === "stop") {
      root.sessionId = ""
      root.enginePid = ""
      root.engineState = "paused"
      if (root.launchAfterStop) {
        root.launchAfterStop = false
        Quickshell.execDetached(["vgrid", "open", root.sheetPath])
        root.close()
      }
      return
    }
    if (root.ctlGotSession) return
    if (root.engineState === "missing" || code === 127) { root.engineState = "missing"; return }
    root.sessionId = ""
    root.engineState = "retrying"
    restartTimer.interval = root.restartDelay
    root.restartDelay = Math.min(root.restartDelay * 2, 30000)
    restartTimer.restart()
  }

  // A client command failed against the session: the engine is gone or the
  // token changed. Re-run ensure, which adopts a live engine or starts one.
  function engineLost(detail) {
    if (!root.sessionId) return
    root.sessionId = ""
    root.engineState = "retrying"
    root.engineError = detail || ""
    restartTimer.interval = 300
    restartTimer.restart()
  }

  function stopEngine() {
    if (ctlProc.running) return
    root.ctlAction = "stop"
    ctlProc.running = true
  }

  function openInVisiGrid() {
    if (root.editing) root.commitEdit(0, 0)
    root.suspended = true
    root.launchAfterStop = true
    if (root.sessionId && root.engineState === "ready") saveProc.running = true   // save -> stop -> launch
    else root.stopEngine()
  }

  // ---- reads ---------------------------------------------------------------------------
  function currentRange() {
    return Grid.rangeRef(root.topRow, root.leftCol, root.rows, root.cols)
  }

  function refresh() {
    if (!root.sessionId || !root.opened) return
    if (inspectProc.running) { root.inspectDirty = true; return }
    root.inflightRange = root.currentRange()
    root.inflightRows = root.rows
    root.inflightCols = root.cols
    inspectProc.running = true
  }

  function onInspect(text) {
    // The viewport moved or resized while this inspect was running: its cells
    // would land in the wrong places. Drop it and ask again.
    if (root.inflightRange !== root.currentRange()) { root.inspectDirty = true; return }
    var parsed = Grid.parseRange(text, root.inflightRows, root.inflightCols)
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
    if (root.hasRange()) root.clearSelection()
    else root.writeCell(root.activeRow, root.activeCol, "")
  }

  // ---- editing ---------------------------------------------------------------------------
  function beginEdit(initial, atStart) {
    root.editing = true
    editor.text = initial
    editor.cursorPosition = atStart ? 0 : editor.text.length
    editor.forceActiveFocus()
  }

  function cancelEdit() {
    root.editing = false
    root.pointing = false
    editor.text = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitEdit(dr, dc) {
    var text = Grid.balanceFormula(editor.text)
    root.editing = false
    root.pointing = false
    editor.text = ""
    root.writeCell(root.activeRow, root.activeCol, text)
    root.move(dr, dc)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- point mode + AutoSum ---------------------------------------------------------
  function formulaEditing() {
    return root.editing && editor.text.charAt(0) === "="
  }

  // A reference may be inserted where the formula expects an operand.
  function operandExpectedAt(text, pos) {
    if (pos <= 0) return false
    return "=(+-*/,;<>^&:".indexOf(text.charAt(pos - 1)) !== -1
  }

  function clampRowToView(r) { return Math.max(root.topRow, Math.min(root.topRow + root.rows - 1, r)) }
  function clampColToView(c) { return Math.max(root.leftCol, Math.min(root.leftCol + root.cols - 1, c)) }

  function pointRefText() {
    var r0 = Math.min(root.pointAnchorRow, root.pointRow), r1 = Math.max(root.pointAnchorRow, root.pointRow)
    var c0 = Math.min(root.pointAnchorCol, root.pointCol), c1 = Math.max(root.pointAnchorCol, root.pointCol)
    return (r0 === r1 && c0 === c1) ? Grid.cellRef(r0, c0) : Grid.cellRef(r0, c0) + ":" + Grid.cellRef(r1, c1)
  }

  function pointUpdate() {
    var t = editor.text, ref = root.pointRefText()
    editor.text = t.substring(0, root.refPos) + ref + t.substring(root.refPos + root.refLen)
    root.refLen = ref.length
    editor.cursorPosition = root.refPos + root.refLen
  }

  // Begin pointing at (r, c); the reference goes in at the caret.
  function pointBegin(r, c) {
    root.pointing = true
    root.refPos = editor.cursorPosition
    root.refLen = 0
    root.pointAnchorRow = root.pointRow = root.clampRowToView(r)
    root.pointAnchorCol = root.pointCol = root.clampColToView(c)
    root.pointUpdate()
  }

  function pointMove(dr, dc, extend) {
    root.pointRow = root.clampRowToView(root.pointRow + dr)
    root.pointCol = root.clampColToView(root.pointCol + dc)
    if (!extend) { root.pointAnchorRow = root.pointRow; root.pointAnchorCol = root.pointCol }
    root.pointUpdate()
  }

  // Arrow key while editing a formula. Returns true if it was consumed.
  function pointArrow(dr, dc, extend) {
    if (!root.formulaEditing()) return false
    if (root.pointing) { root.pointMove(dr, dc, extend); return true }
    if (!root.operandExpectedAt(editor.text, editor.cursorPosition)) return false
    root.pointBegin(root.activeRow + dr, root.activeCol + dc)
    return true
  }

  // Mouse click on a cell while editing a formula. Returns true if consumed.
  function pointClick(r, c) {
    if (!root.formulaEditing()) return false
    if (!root.pointing && !root.operandExpectedAt(editor.text, editor.cursorPosition)) return false
    if (root.pointing) { root.pointAnchorRow = root.pointRow = r; root.pointAnchorCol = root.pointCol = c; root.pointUpdate() }
    else root.pointBegin(r, c)
    editor.forceActiveFocus()
    return true
  }

  // Alt+=: =SUM() over the numbers directly above, else directly to the left.
  function autoSum() {
    if (root.editing) return
    var rr = root.activeRow - root.topRow, cc = root.activeCol - root.leftCol
    var r = rr - 1
    while (r >= 0 && Grid.isNumeric(root.cellAt(r, cc).display)) r--
    var range = ""
    if (rr - 1 - r >= 1) {
      range = Grid.cellRef(root.topRow + r + 1, root.activeCol) + ":" + Grid.cellRef(root.activeRow - 1, root.activeCol)
    } else {
      var c = cc - 1
      while (c >= 0 && Grid.isNumeric(root.cellAt(rr, c).display)) c--
      if (cc - 1 - c >= 1) range = Grid.cellRef(root.activeRow, root.leftCol + c + 1) + ":" + Grid.cellRef(root.activeRow, root.activeCol - 1)
    }
    root.beginEdit("=SUM(" + range + ")", false)
    if (range === "") Qt.callLater(function() { editor.cursorPosition = 5 })
  }

  // ---- navigation -------------------------------------------------------------------
  function move(dr, dc) {
    root.moveCursor(root.activeRow + dr, root.activeCol + dc, false)
  }

  function moveExt(dr, dc, extend) {
    root.moveCursor(root.activeRow + dr, root.activeCol + dc, extend)
  }

  function select(r, c) {
    root.moveCursor(r, c, false)
  }

  function moveCursor(r, c, extend) {
    r = Math.max(0, Math.min(root.maxRows - 1, r))
    c = Math.max(0, Math.min(root.maxCols - 1, c))
    root.regionSel = null
    root.activeRow = r
    root.activeCol = c
    if (!extend) { root.selAnchorRow = r; root.selAnchorCol = c }
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

  // ---- selection ------------------------------------------------------------------
  function selBounds() {
    if (root.regionSel) return root.regionSel
    return {
      r0: Math.min(root.selAnchorRow, root.activeRow), r1: Math.max(root.selAnchorRow, root.activeRow),
      c0: Math.min(root.selAnchorCol, root.activeCol), c1: Math.max(root.selAnchorCol, root.activeCol)
    }
  }

  function hasRange() {
    var b = root.selBounds()
    return b.r0 !== b.r1 || b.c0 !== b.c1
  }

  function filledAt(rr, cc) {
    return rr >= 0 && cc >= 0 && rr < root.rows && cc < root.cols && root.cellAt(rr, cc).raw !== ""
  }

  // Excel's "current region": grow a box around the active cell until the
  // ring around it is empty. Viewport coordinates; null if nothing is nearby.
  function currentRegion() {
    var r0 = root.activeRow - root.topRow, r1 = r0, c0 = root.activeCol - root.leftCol, c1 = c0
    var grew = true, any = root.filledAt(r0, c0)
    while (grew) {
      grew = false
      var up = false, down = false, left = false, right = false
      for (var c = c0 - 1; c <= c1 + 1; c++) {
        if (root.filledAt(r0 - 1, c)) { up = true; if (c < c0) left = true; if (c > c1) right = true }
        if (root.filledAt(r1 + 1, c)) { down = true; if (c < c0) left = true; if (c > c1) right = true }
      }
      for (var r = r0; r <= r1; r++) {
        if (root.filledAt(r, c0 - 1)) left = true
        if (root.filledAt(r, c1 + 1)) right = true
      }
      if (up && r0 > 0) { r0--; grew = true }
      if (down && r1 < root.rows - 1) { r1++; grew = true }
      if (left && c0 > 0) { c0--; grew = true }
      if (right && c1 < root.cols - 1) { c1++; grew = true }
      if (grew) any = true
    }
    if (!any) return null
    return { r0: root.topRow + r0, r1: root.topRow + r1, c0: root.leftCol + c0, c1: root.leftCol + c1 }
  }

  // Ctrl+A: the region around the cursor, then the whole visible grid.
  function selectAll() {
    var full = { r0: root.topRow, r1: root.topRow + root.rows - 1, c0: root.leftCol, c1: root.leftCol + root.cols - 1 }
    var reg = root.currentRegion()
    var cur = root.selBounds()
    if (!reg || (cur.r0 === reg.r0 && cur.r1 === reg.r1 && cur.c0 === reg.c0 && cur.c1 === reg.c1)) reg = full
    root.regionSel = reg
  }

  // One-shot range read from the engine for data that may be off screen.
  function fetchRange(ref, rows, cols, cb) {
    if (!root.sessionId || rangeProc.running) return false
    root.rangeCallback = function(text) { cb(Grid.parseRange(text, rows, cols)) }
    root.rangeRequest = ref
    rangeProc.running = true
    return true
  }

  // Ctrl+Arrow: end of the current run of filled cells, else the next filled
  // cell, else the edge. Reads the whole row or column strip first.
  function jump(dr, dc, extend) {
    var vertical = dr !== 0
    var n = vertical ? Math.min(root.stripMaxRows, root.maxRows) : root.maxCols
    var ref = vertical
      ? Grid.cellRef(0, root.activeCol) + ":" + Grid.cellRef(n - 1, root.activeCol)
      : Grid.cellRef(root.activeRow, 0) + ":" + Grid.cellRef(root.activeRow, n - 1)
    var d = vertical ? dr : dc
    var i = vertical ? root.activeRow : root.activeCol
    root.fetchRange(ref, vertical ? n : 1, vertical ? 1 : n, function(parsed) {
      if (!parsed.ok) return
      var filled = function(k) {
        if (k < 0 || k >= n) return false
        var cell = vertical ? parsed.grid[k][0] : parsed.grid[0][k]
        return cell && cell.raw !== ""
      }
      var j = i
      if (i + d < 0 || i + d >= n) return
      if (filled(i) && filled(i + d)) {
        while (filled(j + d)) j += d
      } else {
        j = i + d
        while (j >= 0 && j < n && !filled(j)) j += d
        if (j < 0 || j >= n) j = d < 0 ? 0 : n - 1
      }
      if (vertical) root.moveCursor(j, root.activeCol, extend)
      else root.moveCursor(root.activeRow, j, extend)
    })
  }

  function rangeToText(parsed, raw) {
    var lines = []
    for (var r = 0; r < parsed.grid.length; r++) {
      var row = []
      for (var c = 0; c < parsed.grid[r].length; c++) {
        var cell = parsed.grid[r][c]
        row.push(raw ? (cell.raw || cell.display) : cell.display)
      }
      lines.push(row.join("\t"))
    }
    return lines.join("\n")
  }

  function copySelection(raw) {
    var b = root.selBounds()
    var rows = b.r1 - b.r0 + 1, cols = b.c1 - b.c0 + 1
    if (rows * cols === 1) { root.copyActive(raw); return }
    if (rows * cols > root.rangeMaxCells) { root.engineError = "selection too large to copy"; return }
    root.fetchRange(Grid.rangeRef(b.r0, b.c0, rows, cols), rows, cols, function(parsed) {
      if (!parsed.ok) return
      Quickshell.execDetached(["wl-copy", "--", root.rangeToText(parsed, raw)])
    })
  }

  function clearSelection() {
    var b = root.selBounds()
    var rows = b.r1 - b.r0 + 1, cols = b.c1 - b.c0 + 1
    if (rows * cols > root.rangeMaxCells) { root.engineError = "selection too large to clear"; return }
    var ops = ""
    for (var r = b.r0; r <= b.r1; r++) {
      for (var c = b.c0; c <= b.c1; c++) {
        root.setLocal(r, c, "")
        ops += Grid.opFor(r, c, "") + "\n"
      }
    }
    root.queuedOps += ops
    root.flushOps()
  }

  function pasteFromClipboard() {
    if (root.editing || pasteProc.running) return
    pasteProc.running = true
  }

  function pasteText(text) {
    var lines = text.replace(/\r/g, "").split("\n")
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop()
    var ops = ""
    for (var r = 0; r < lines.length && root.activeRow + r < root.maxRows; r++) {
      var cells = lines[r].split("\t")
      for (var c = 0; c < cells.length && root.activeCol + c < root.maxCols; c++) {
        root.setLocal(root.activeRow + r, root.activeCol + c, cells[c])
        ops += Grid.opFor(root.activeRow + r, root.activeCol + c, cells[c]) + "\n"
      }
    }
    if (ops === "") return
    root.queuedOps += ops
    root.flushOps()
    root.regionSel = { r0: root.activeRow, c0: root.activeCol,
      r1: Math.min(root.maxRows - 1, root.activeRow + lines.length - 1),
      c1: Math.min(root.maxCols - 1, root.activeCol + Math.max.apply(null, lines.map(function(l) { return l.split("\t").length })) - 1) }
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

  // ---- vim mode (mirrors VisiGrid's optional vim bindings) ----------------
  function rowFilled(rr) {
    var row = root.grid[rr]
    if (!row) return false
    for (var c = 0; c < row.length; c++) if (row[c].raw !== "") return true
    return false
  }

  function vimKey(event) {
    var text = event.text || ""
    var pending = root.pendingKey
    root.pendingKey = ""
    var rr = root.activeRow - root.topRow, cc = root.activeCol - root.leftCol
    var row = root.grid[rr] || []
    var c
    switch (text) {
    case "h": root.move(0, -1); return true
    case "j": root.move(1, 0); return true
    case "k": root.move(-1, 0); return true
    case "l": root.move(0, 1); return true
    case "H": root.moveExt(0, -1, true); return true
    case "J": root.moveExt(1, 0, true); return true
    case "K": root.moveExt(-1, 0, true); return true
    case "L": root.moveExt(0, 1, true); return true
    case "0": root.select(root.activeRow, 0); return true
    case "$":
      for (c = row.length - 1; c >= 0; c--) if (row[c].raw !== "") { root.select(root.activeRow, root.leftCol + c); break }
      return true
    case "w":
      for (c = cc + 1; c < row.length; c++) if (row[c].raw !== "") { root.select(root.activeRow, root.leftCol + c); break }
      return true
    case "b":
      for (c = cc - 1; c >= 0; c--) if (row[c].raw !== "") { root.select(root.activeRow, root.leftCol + c); break }
      return true
    case "g":
      if (pending === "g") root.select(0, 0)
      else root.pendingKey = "g"
      return true
    case "G":
      for (var r = root.rows - 1; r >= 0; r--) if (root.rowFilled(r)) { root.select(root.topRow + r, root.activeCol); break }
      return true
    case "i": root.beginEdit(root.activeCell().raw, true); return true
    case "a": root.beginEdit(root.activeCell().raw, false); return true
    case "x": root.clearCell(); return true
    }
    // Numbers and formula starters still type straight in: it is a calculator first.
    if (text.length === 1 && /[0-9=.+\-]/.test(text)) { root.beginEdit(text, false); return true }
    // Swallow other letters so a stray key never starts an edit in normal mode.
    return text.length === 1 && text.charCodeAt(0) >= 32
  }

  function handleKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    if ((event.modifiers & Qt.AltModifier) && (event.key === Qt.Key_Equal || event.text === "=")) { root.autoSum(); return true }
    if (root.vimMode && !ctrl && event.text && event.text.length === 1 && event.key !== Qt.Key_Escape
        && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Tab
        && event.key !== Qt.Key_Backspace && event.key !== Qt.Key_Delete) {
      if (root.vimKey(event)) return true
    }
    root.pendingKey = ""
    switch (event.key) {
    case Qt.Key_Escape: root.close(); return true
    case Qt.Key_Left: if (ctrl) root.jump(0, -1, shift); else root.moveExt(0, -1, shift); return true
    case Qt.Key_Right: if (ctrl) root.jump(0, 1, shift); else root.moveExt(0, 1, shift); return true
    case Qt.Key_Up: if (ctrl) root.jump(-1, 0, shift); else root.moveExt(-1, 0, shift); return true
    case Qt.Key_Down: if (ctrl) root.jump(1, 0, shift); else root.moveExt(1, 0, shift); return true
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
    case Qt.Key_F11: root.widthOverride = root.widthMode === "full" ? "fit" : "full"; return true
    case Qt.Key_F12: root.vimOverride = root.vimMode ? 0 : 1; root.pendingKey = ""; return true
    case Qt.Key_Delete:
    case Qt.Key_Backspace: root.clearCell(); return true
    }
    if (ctrl) {
      switch (event.key) {
      case Qt.Key_C: root.copySelection(shift); return true
      case Qt.Key_V: root.pasteFromClipboard(); return true
      case Qt.Key_A: root.selectAll(); return true
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

  Component.onCompleted: root.startEngine()

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
  Process {
    id: ctlProc
    command: ["sh", root.engineScriptPath, root.sheetPath, root.ctlAction]
    stdout: SplitParser { onRead: function(line) { root.onCtlLine(line) } }
    stderr: SplitParser { onRead: function(line) { if (/error/i.test(line)) root.engineError = line } }
    onExited: function(code, status) { root.onCtlExited(code) }
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
      if (code !== 0 && /session|connect|refused|not found|unauthor/i.test(applyProc.lastStderr)) root.engineLost(root.engineError)
      root.flushOps()
      root.refresh()
    }
  }

  Process {
    id: inspectProc
    command: ["vgrid", "inspect", "--session", root.sessionId, "--json", root.inflightRange]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onInspect(text)
    }
    onExited: function(code, status) {
      if (code !== 0) { root.engineLost("engine not responding"); return }
      if (root.inspectDirty) { root.inspectDirty = false; root.refresh() }
    }
  }

  // Live refresh: while the overlay is open, poll the workbook revision (a
  // tiny JSON) and only re-read the visible range when it changed. This is
  // what makes edits from other clients (agents over MCP, the CLI) show up
  // as they happen.
  Timer {
    id: livePoll
    interval: 400
    repeat: true
    running: root.opened && root.sessionId !== "" && root.engineState === "ready"
    onTriggered: if (!revProc.running && !inspectProc.running && !applyProc.running) revProc.running = true
  }

  Process {
    id: revProc
    command: ["vgrid", "inspect", "--session", root.sessionId, "--json", "workbook"]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rev = -1
        try { rev = JSON.parse(text).revision } catch (e) { return }
        if (typeof rev === "number" && rev !== root.revision) root.refresh()
      }
    }
    onExited: function(code, status) { if (code !== 0) root.engineLost("engine not responding") }
  }

  Process {
    id: saveProc
    command: ["vgrid", "save", "--session", root.sessionId]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    onExited: function(code, status) {
      if (code !== 0) root.engineLost("save failed")
      if (root.launchAfterStop) root.stopEngine()
    }
  }

  Process {
    id: rangeProc
    command: ["vgrid", "inspect", "--session", root.sessionId, "--json", root.rangeRequest]
    environment: ({ "VISIGRID_SESSION_TOKEN": root.token })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cb = root.rangeCallback
        root.rangeCallback = null
        if (cb) cb(text)
      }
    }
  }

  // Clipboard text comes through engine.sh, which caps what it reads at
  // 64 KiB and gives wl-paste a two-second deadline, so an oversized or
  // stalled clipboard is reported in the status line rather than collected
  // here in full and parsed. Only a clean exit carries text.
  Process {
    id: pasteProc
    command: ["sh", root.engineScriptPath, root.sheetPath, "paste"]
    property string output: ""
    property string lastStderr: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: pasteProc.output = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: pasteProc.lastStderr = text.trim()
    }
    onExited: function(code, status) {
      var text = pasteProc.output
      pasteProc.output = ""
      if (code === 0) { root.pasteText(text); return }
      root.engineError = pasteProc.lastStderr || ("clipboard read failed (" + code + ")")
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
          if (root.editing) {
            // A fast typist can land a key here before the editor has focus.
            // Forward it instead of dropping it.
            if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && !(event.modifiers & Qt.ControlModifier)) {
              editor.insert(editor.cursorPosition, event.text)
              event.accepted = true
            } else {
              editor.forceActiveFocus()
            }
            return
          }
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
                      onClicked: function(mouse) {
                        if (root.pointClick(root.topRow + rowItem.index, root.leftCol + cellItem.index)) return
                        if (root.editing) root.commitEdit(0, 0)
                        root.moveCursor(root.topRow + rowItem.index, root.leftCol + cellItem.index, (mouse.modifiers & Qt.ShiftModifier) !== 0)
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

          // Selected range (clipped to the viewport). The active cell stays inverse video.
          Rectangle {
            // One binding computes the clipped box so no property depends on a sibling.
            readonly property var box: {
              var b = root.regionSel || {
                r0: Math.min(root.selAnchorRow, root.activeRow), r1: Math.max(root.selAnchorRow, root.activeRow),
                c0: Math.min(root.selAnchorCol, root.activeCol), c1: Math.max(root.selAnchorCol, root.activeCol)
              }
              var r0 = Math.max(b.r0, root.topRow), r1 = Math.min(b.r1, root.topRow + root.rows - 1)
              var c0 = Math.max(b.c0, root.leftCol), c1 = Math.min(b.c1, root.leftCol + root.cols - 1)
              var isRange = b.r0 !== b.r1 || b.c0 !== b.c1
              return { show: isRange && r1 >= r0 && c1 >= c0, r0: r0, r1: r1, c0: c0, c1: c1 }
            }
            visible: box.show
            x: root.headW + (box.c0 - root.leftCol) * root.cellW
            y: root.cellH + (box.r0 - root.topRow) * root.cellH
            width: (box.c1 - box.c0 + 1) * root.cellW
            height: (box.r1 - box.r0 + 1) * root.cellH
            color: Util.alpha(root.selBg, 0.22)
            border.color: root.selBg
            border.width: 1
            z: 3
          }

          // Outline of the reference being picked in point mode.
          Rectangle {
            visible: root.pointing
            x: root.headW + (Math.min(root.pointAnchorCol, root.pointCol) - root.leftCol) * root.cellW
            y: root.cellH + (Math.min(root.pointAnchorRow, root.pointRow) - root.topRow) * root.cellH
            width: (Math.abs(root.pointCol - root.pointAnchorCol) + 1) * root.cellW
            height: (Math.abs(root.pointRow - root.pointAnchorRow) + 1) * root.cellH
            color: Util.alpha(root.fgBright, 0.12)
            border.color: root.fgBright
            border.width: 2
            z: 4
          }

          // In-cell editor, floated over the active cell.
          Rectangle {
            id: editorBox
            visible: root.editing
            x: root.headW + (root.activeCol - root.leftCol) * root.cellW
            y: root.cellH + (root.activeRow - root.topRow) * root.cellH
            // One cell wide; grows over the neighbours only when the text needs it.
            width: Math.min(gridArea.width - x, Math.max(root.cellW, Math.ceil(editor.contentWidth) + Style.space(18)))
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
                case Qt.Key_Up: if (root.pointArrow(-1, 0, shift)) { event.accepted = true; return } root.commitEdit(-1, 0); event.accepted = true; return
                case Qt.Key_Down: if (root.pointArrow(1, 0, shift)) { event.accepted = true; return } root.commitEdit(1, 0); event.accepted = true; return
                case Qt.Key_Left: if (root.pointArrow(0, -1, shift)) { event.accepted = true; return } break
                case Qt.Key_Right: if (root.pointArrow(0, 1, shift)) { event.accepted = true; return } break
                }
                // Any other key locks the picked reference in and resumes typing.
                if (root.pointing && event.key !== Qt.Key_Shift) root.pointing = false
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
            text: root.vimMode
              ? "hjkl move  HJKL select  i/a edit  x clear  w/b  0/$  gg/G  ^arrows jump  ^A all  ^C/^V copy/paste  ^O VisiGrid  F11 F12  Esc close"
              : "⇧arrows select  ^arrows jump  ^A all  F2 edit  Alt+= sum  Del clear  ^C/^V copy/paste  ^O VisiGrid  F11 F12  Esc close"
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
