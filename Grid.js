.pragma library

// Column index (0-based) -> letters: 0 -> A, 25 -> Z, 26 -> AA.
function colName(c) {
  var s = ""
  c = c + 1
  while (c > 0) {
    var r = (c - 1) % 26
    s = String.fromCharCode(65 + r) + s
    c = Math.floor((c - 1) / 26)
  }
  return s
}

function cellRef(row, col) {
  return colName(col) + (row + 1)
}

function rangeRef(top, left, rows, cols) {
  return cellRef(top, left) + ":" + cellRef(top + rows - 1, left + cols - 1)
}

// Parse `vgrid inspect --json` for a range into rows[r][c] = {raw, display, formula}.
// Cells come back flat, row-major.
function parseRange(json, rows, cols) {
  var out = emptyGrid(rows, cols)
  var doc
  try { doc = JSON.parse(json) } catch (e) { return { grid: out, revision: -1, ok: false } }
  var res = doc && doc.result
  if (!res || res.result !== "range" || !Array.isArray(res.cells)) return { grid: out, revision: -1, ok: false }
  for (var i = 0; i < res.cells.length && i < rows * cols; i++) {
    var r = Math.floor(i / cols), c = i % cols
    var cell = res.cells[i] || {}
    out[r][c] = { raw: cell.raw || "", display: cell.display || "", formula: cell.formula || "" }
  }
  return { grid: out, revision: typeof doc.revision === "number" ? doc.revision : -1, ok: true }
}

function emptyGrid(rows, cols) {
  var g = []
  for (var r = 0; r < rows; r++) {
    var row = []
    for (var c = 0; c < cols; c++) row.push({ raw: "", display: "", formula: "" })
    g.push(row)
  }
  return g
}

function isNumeric(display) {
  return /^\s*[-+(]?[$€£]?\s*[\d,]*\.?\d+\s*%?\)?\s*$/.test(display)
}

function isError(display) {
  return display.length > 1 && display.charAt(0) === "#"
}

// One JSONL op per edit. The engine treats a leading "=" in a value as a formula.
function opFor(row, col, text) {
  if (text === "") return JSON.stringify({ op: "clear_cell", row: row, col: col })
  return JSON.stringify({ op: "set_cell_value", row: row, col: col, value: text })
}

function randomToken() {
  var s = ""
  for (var i = 0; i < 48; i++) s += "abcdefghijklmnopqrstuvwxyz0123456789".charAt(Math.floor(Math.random() * 36))
  return s
}
