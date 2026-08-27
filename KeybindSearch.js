.pragma library

// Port of keybinds-tui's `Tab::filtered` / `split_at_tab` (src/model.rs).
// Kept behaviourally identical to the Rust tests so the TUI and this plugin
// answer the same query the same way.

// True if every char of `needle` appears in `haystack` in order, not
// necessarily contiguous — a cheap fzf-style fuzzy match.
function isSubsequence(needle, haystack) {
  var h = 0
  for (var n = 0; n < needle.length; n++) {
    while (h < haystack.length && haystack[h] !== needle[n]) h++
    if (h >= haystack.length) return false
    h++
  }
  return true
}

// If `search` starts with `@token`, splits it into the tab-selector token and
// the remaining filter text ("@vim scroll" -> {tab: "vim", rest: "scroll"}).
function splitAtTab(search) {
  if (search.charAt(0) !== "@") return { tab: null, rest: search }
  var rest = search.slice(1)
  var end = rest.search(/\s/)
  if (end < 0) end = rest.length
  var token = rest.slice(0, end)
  if (!token) return { tab: null, rest: search }
  return { tab: token, rest: rest.slice(end).replace(/^\s+/, "") }
}

// Every whitespace-separated word in `search` must appear — as a substring
// or, failing that, as an in-order subsequence — somewhere in the row
// (section, keys, action, or the tab's aliases). Substring matches rank
// first. `rows` are {section, keys, action}; `aliasText` is the tab's
// aliases joined with spaces.
function filterBinds(rows, aliasText, search) {
  var words = search.toLowerCase().split(/\s+/).filter(function (w) { return w.length > 0 })
  var aliases = (aliasText || "").toLowerCase()
  var scored = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var haystack = (row.section + " " + row.keys + " " + row.action + " " + aliases).toLowerCase()
    var score = 0
    var matched = true
    for (var w = 0; w < words.length; w++) {
      if (haystack.indexOf(words[w]) >= 0) score += 2
      else if (isSubsequence(words[w], haystack)) score += 1
      else { matched = false; break }
    }
    if (matched) scored.push({ score: score, index: i, row: row })
  }

  if (words.length > 0) {
    // Stable: equal scores keep source order, matching the Rust sort.
    scored.sort(function (a, b) { return b.score - a.score || a.index - b.index })
  }
  return scored.map(function (s) { return s.row })
}

// Which-key narrowing: keeps rows where some "/"-separated alternative of
// `keys` starts with `buffer` once whitespace is stripped from both, so
// "g g" matches typing "gg" and "SUPER + Q" matches "SUPER+Q".
function whichKeyFilter(rows, buffer) {
  if (!buffer) return rows
  return rows.filter(function (row) {
    return row.keys.split("/").some(function (alt) {
      return alt.replace(/\s+/g, "").indexOf(buffer) === 0
    })
  })
}
