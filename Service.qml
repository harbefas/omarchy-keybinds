import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Shared state for the bar popup and the full overlay. Both show the same
// binds, so the sources are read once here rather than once per surface.
//
// Hyprland's binds come live from `hyprctl binds -j` and Neovim's from a
// headless keymap dump; the rest are hand-copied defaults in data/*.json.
// Nothing outside Hyprland, Quickshell, and an optional nvim is needed.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/harbefas.keybinds"

  // Flattens a tab into the {section, keys, action} rows both surfaces render.
  function flatRows(tab) {
    if (!tab) return []
    var out = []
    for (var s = 0; s < tab.sections.length; s++) {
      var section = tab.sections[s]
      for (var b = 0; b < section.binds.length; b++) {
        out.push({
          section: section.name,
          keys: section.binds[b].keys,
          action: section.binds[b].action
        })
      }
    }
    return out
  }

  // Surfaces call this when they open, so a refresh costs nothing while idle.
  function refresh() {
    root.refreshHyprland()
    root.loadNeovim()
  }

  // Every tab: { app, aliases: [], windowClass: [], binaries: [], sections: [] }.
  // Hyprland and Neovim are placeheld at fixed indices so their async loads
  // can drop straight into place without reshuffling the strip.
  property var allTabs: []

  // A tab declaring `binaries` is only shown when one of them is on PATH, so
  // installing the plugin does not hand you a reference to somebody else's
  // tools. Tabs with no `binaries` (Hyprland, Neovim) always show.
  property var installedBinaries: null
  readonly property var tabs: {
    if (root.installedBinaries === null) return root.allTabs
    return root.allTabs.filter(function (tab) {
      var needed = tab.binaries || []
      if (needed.length === 0) return true
      return needed.some(function (b) { return root.installedBinaries[b] === true })
    })
  }

  // ------------------------------------------------------------- onboarding

  // Nothing writes to the user's Hyprland config, so a fresh install has no
  // shortcut. Both surfaces offer one until a binding referencing this plugin
  // shows up, at which point the hint retires itself.
  readonly property string suggestedKey: "SUPER + SHIFT + H"
  readonly property string suggestedBind:
    'o.bind("' + root.suggestedKey + '", "Keybinds", "omarchy-shell harbefas.keybinds.widget toggle")'

  property bool keybindConfigured: false

  // The files are read asynchronously, so a surface opening right after a
  // shell restart would otherwise see "no keybind" and suggest one to someone
  // who already has it. Wait until both have been accounted for.
  property int bindingsScanned: 0
  readonly property bool bindingsReady: root.bindingsScanned >= 2

  function noteBindings(text) {
    if (String(text || "").indexOf("harbefas.keybinds") >= 0) root.keybindConfigured = true
    root.bindingsScanned += 1
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    watchChanges: true
    onLoaded: root.noteBindings(text())
    onLoadFailed: root.bindingsScanned += 1
  }

  // Pre-Quattro setups still keep their bindings here.
  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/bindings.conf"
    watchChanges: true
    onLoaded: root.noteBindings(text())
    onLoadFailed: root.bindingsScanned += 1
  }

  // ------------------------------------------------------------------- ipc

  // The bar widget registers itself here so the popup can be driven from a
  // keybind or a script, the same way the overlay is summoned.
  property var widget: null

  function openWidget() {
    if (!root.widget) return false
    root.widget.openPopup()
    return true
  }

  function closeWidget() {
    if (!root.widget) return false
    root.widget.closePopup()
    return true
  }

  function isWidgetOpen() {
    return !!(root.widget && root.widget.popupOpen)
  }

  IpcHandler {
    target: "harbefas.keybinds.widget"

    function open(): string {
      return root.openWidget() ? "opened" : "unavailable"
    }

    function close(): string {
      return root.closeWidget() ? "closed" : "unavailable"
    }

    function toggle(): string {
      return root.isWidgetOpen()
        ? (root.closeWidget() ? "closed" : "unavailable")
        : (root.openWidget() ? "opened" : "unavailable")
    }
  }

  // --------------------------------------------------------------- untrusted

  // Binds reach us from the compositor, from a headless Neovim dump written by
  // whatever plugins the user has installed, and from process names — none of
  // it under our control. Bound the length and drop control characters here,
  // and render every one of these strings as PlainText, so a hostile value
  // cannot smuggle markup into the long-lived shell UI.
  readonly property int maxFieldLength: 200

  function clean(value, limit) {
    var text = String(value === undefined || value === null ? "" : value)
    // Strip C0/C7 control characters, including the ESC that starts an
    // terminal escape sequence, plus the Unicode line/paragraph separators.
    text = text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
    text = text.replace(/\s+/g, " ").replace(/^ | $/g, "")
    var max = limit || root.maxFieldLength
    return text.length > max ? text.slice(0, max) + "…" : text
  }

  function cleanSections(sections) {
    var out = []
    for (var s = 0; s < sections.length; s++) {
      var binds = sections[s].binds || []
      var cleanBinds = []
      for (var b = 0; b < binds.length; b++) {
        var keys = root.clean(binds[b].keys, 80)
        var action = root.clean(binds[b].action)
        if (!keys && !action) continue
        cleanBinds.push({ keys: keys, action: action })
      }
      if (cleanBinds.length === 0) continue
      out.push({ name: root.clean(sections[s].name, 60), binds: cleanBinds })
    }
    return out
  }

  // ------------------------------------------------------------------- tabs

  function tabIndexByApp(app) {
    for (var i = 0; i < root.tabs.length; i++)
      if (root.tabs[i].app === app) return i
    return -1
  }

  // Replaces a tab in place when its async source resolves, or appends it
  // keeping `order` (lower first) so the strip does not jump around.
  function upsertTab(tab, order) {
    tab.app = root.clean(tab.app, 40)
    tab.sections = root.cleanSections(tab.sections || [])
    if (!tab.app) return

    var next = root.allTabs.slice()
    var at = -1
    for (var i = 0; i < next.length; i++)
      if (next[i].app === tab.app) { at = i; break }

    tab.order = order
    if (at >= 0) next[at] = tab
    else next.push(tab)

    next.sort(function (a, b) { return a.order - b.order })
    root.allTabs = next
  }

  // The overlay takes keyboard focus as a layer surface, not a toplevel, so
  // the active toplevel is still whatever the user was in. No env-var handoff
  // needed, unlike the terminal build.
  function guessAppForFocus() {
    var fallback = root.tabs.length > 0 ? root.tabs[0].app : ""
    var toplevel = null
    try { toplevel = ToplevelManager.activeToplevel } catch (e) { toplevel = null }
    if (!toplevel) return fallback

    var appId = (toplevel.appId || "").toLowerCase()
    if (!appId) return fallback

    for (var i = 0; i < root.tabs.length; i++) {
      var classes = root.tabs[i].windowClass || []
      for (var c = 0; c < classes.length; c++)
        if (appId.indexOf(classes[c].toLowerCase()) >= 0) return root.tabs[i].app
    }

    if (!["ghostty", "com.mitchellh.ghostty", "kitty", "alacritty", "foot"].some(function (t) {
      return appId.indexOf(t) >= 0
    })) return fallback

    // A terminal window does not say which TUI is running inside it. The title
    // usually does — scratchpad launchers and most TUIs set it — so try that
    // before paying for a process-tree walk.
    var title = (toplevel.title || "").toLowerCase()
    for (var name in root.terminalApps) {
      if (title.indexOf(name) >= 0 && root.tabIndexByApp(root.terminalApps[name]) >= 0)
        return root.terminalApps[name]
    }

    // Otherwise ask the process tree; the answer arrives async and re-selects.
    activeWindowProbe.running = true
    return fallback
  }

  // ------------------------------------------------------- static data files

  readonly property var staticSlugs: [
    "tridactyl", "spotify_player", "lazygit", "yazi", "glow", "tuicr"
  ]

  function loadStaticTab(raw, order) {
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { return }
    if (parsed && parsed.app) root.upsertTab(parsed, order)
  }

  readonly property var candidateBinaries: [
    "herdr", "spotify_player", "lazygit", "yazi", "glow", "tuicr",
    "librewolf", "firefox", "zen-browser", "floorp"
  ]

  function recordInstalled(paths) {
    var found = {}
    var lines = String(paths || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      found[line.split("/").pop()] = true
    }
    root.installedBinaries = found
  }

  Process {
    running: true
    command: ["which"].concat(root.candidateBinaries)
    stdout: StdioCollector { onStreamFinished: root.recordInstalled(text) }
  }

  Instantiator {
    model: root.staticSlugs
    delegate: FileView {
      required property string modelData
      required property int index
      path: root.pluginDir + "/data/" + modelData + ".json"
      // Hyprland is 0 and Herdr 1; static tables follow, Neovim last.
      onLoaded: root.loadStaticTab(text(), 2 + index)
    }
  }

  // ------------------------------------------------------------------ herdr

  // Defaults ship in data/herdr.json; ~/.config/herdr/config.toml's [keys]
  // table overrides individual binds, so it is merged on top when present.
  property var herdrDefaults: null
  property var herdrOverrides: ({})

  function actionId(action) {
    return action.toLowerCase().replace(/ /g, "_")
  }

  function rebuildHerdr() {
    if (!root.herdrDefaults) return
    var tab = JSON.parse(JSON.stringify(root.herdrDefaults))
    for (var s = 0; s < tab.sections.length; s++) {
      var binds = tab.sections[s].binds
      for (var b = 0; b < binds.length; b++) {
        var override = root.herdrOverrides[actionId(binds[b].action)]
        if (override) binds[b].keys = override
      }
    }
    root.upsertTab(tab, 1)
  }

  // Small [keys] reader — `key = "value"` or `key = ["alt", "alt"]`; quoted
  // substrings cover both without pulling in a TOML parser.
  function parseHerdrKeys(content) {
    var out = {}
    var inKeys = false
    var lines = content.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.charAt(0) === "[") { inKeys = line === "[keys]"; continue }
      if (!inKeys) continue
      var eq = line.indexOf("=")
      if (eq < 0) continue
      var key = line.slice(0, eq).trim()
      var quoted = line.slice(eq + 1).split('"').filter(function (_, idx) { return idx % 2 === 1 })
      if (quoted.length === 0) continue
      out[key] = quoted.map(function (v) {
        return v.replace(/prefix/g, "Prefix").replace(/\+/g, " + ")
      }).join(" / ")
    }
    return out
  }

  FileView {
    path: root.pluginDir + "/data/herdr.json"
    onLoaded: {
      try { root.herdrDefaults = JSON.parse(text()) } catch (e) { return }
      root.rebuildHerdr()
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/herdr/config.toml"
    watchChanges: true
    onLoaded: {
      root.herdrOverrides = root.parseHerdrKeys(text())
      root.rebuildHerdr()
    }
    onLoadFailed: root.rebuildHerdr()
  }

  // --------------------------------------------------------------- hyprland

  // `hyprctl binds -j` beats parsing ~/.config/hypr/*.conf: it reports what
  // the compositor actually has bound, including binds from any include the
  // parser would have to chase, plus the submap each one belongs to.
  readonly property var modNames: [
    { mask: 64, name: "SUPER" }, { mask: 4, name: "CTRL" },
    { mask: 8, name: "ALT" }, { mask: 1, name: "SHIFT" }
  ]

  function formatBindKeys(bind) {
    var parts = []
    for (var i = 0; i < root.modNames.length; i++)
      if (bind.modmask & root.modNames[i].mask) parts.push(root.modNames[i].name)

    var key = bind.key || (bind.keycode ? "code:" + bind.keycode : "")
    if (bind.mouse && !key) key = "mouse"
    if (key) parts.push(key)
    return parts.join(" + ")
  }

  function buildHyprlandTab(raw) {
    var binds = []
    try { binds = JSON.parse(raw) } catch (e) { return }

    var bySubmap = {}
    var order = []
    for (var i = 0; i < binds.length; i++) {
      var bind = binds[i]
      var keys = formatBindKeys(bind)
      if (!keys) continue

      var action = bind.description || ""
      if (!action) {
        action = (bind.dispatcher || "").replace(/^__/, "")
        if (bind.arg) action += " " + bind.arg
      }
      if (!action) continue

      var name = bind.submap ? "submap: " + bind.submap : "Global"
      if (!bySubmap[name]) { bySubmap[name] = []; order.push(name) }
      bySubmap[name].push({ keys: keys, action: action })
    }

    var sections = order.map(function (name) {
      return { name: name, binds: bySubmap[name] }
    })
    root.upsertTab({
      app: "Hyprland",
      aliases: ["compositor", "wm", "wayland"],
      windowClass: [],
      sections: sections
    }, 0)
  }

  function refreshHyprland() {
    hyprBinds.running = true
  }

  Process {
    id: hyprBinds
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector { onStreamFinished: root.buildHyprlandTab(text) }
  }

  // ----------------------------------------------------------------- neovim

  // The dump costs seconds on a plugin-heavy config, so the last one is kept
  // and rendered immediately on open while a fresh dump runs behind it.
  readonly property string dumpPath: "/tmp/omarchy-keybinds-nvim-dump.json"
  readonly property string nvimDumpLua:
    'local out = {} ' +
    'for _, mode in ipairs({"n", "i", "v", "x"}) do ' +
    '  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do ' +
    '    table.insert(out, {mode = mode, lhs = m.lhs, rhs = m.rhs or "", desc = m.desc}) ' +
    '  end ' +
    'end ' +
    'local f = io.open(os.getenv("KB_NVIM_DUMP"), "w") ' +
    'f:write(vim.json.encode(out)) ' +
    'f:close() ' +
    'vim.cmd("qa!")'

  property bool nvimLoaded: false

  readonly property var nvimModeNames: ({
    "n": "Normal", "i": "Insert", "v": "Visual", "x": "Visual (block)"
  })

  function placeholderNeovimTab(message) {
    return {
      app: "Neovim",
      aliases: ["vim", "editor"],
      windowClass: [],
      sections: [{ name: "status", binds: [{ keys: "-", action: message }] }]
    }
  }

  function neovimTabFrom(sections) {
    root.upsertTab({
      app: "Neovim",
      aliases: ["vim", "editor"],
      windowClass: [],
      sections: sections
    }, 99)
    root.nvimLoaded = true
    return true
  }

  function buildNeovimTab(raw) {
    var entries = []
    try { entries = JSON.parse(raw) } catch (e) { return false }
    if (!entries.length) return false

    var byMode = {}
    var order = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry.lhs || !entry.lhs.trim()) continue

      var mode = root.nvimModeNames[entry.mode] || entry.mode
      var action = entry.desc || entry.rhs || "<cmd lua>"
      if (!byMode[mode]) { byMode[mode] = []; order.push(mode) }
      byMode[mode].push({ keys: entry.lhs, action: action })
    }

    if (order.length === 0) return false
    order.sort()
    return root.neovimTabFrom(order.map(function (mode) {
      return { name: mode, binds: byMode[mode] }
    }))
  }

  // Renders the previous dump straight away, then refreshes it in the
  // background so a config edit shows up on the next open.
  property bool nvimDumpedThisSession: false

  function loadNeovim() {
    if (!root.nvimLoaded) previousDump.reload()
    if (!root.nvimDumpedThisSession) {
      root.nvimDumpedThisSession = true
      nvimDump.running = true
    }
  }

  FileView {
    id: previousDump
    path: root.dumpPath
    onLoaded: root.buildNeovimTab(text())
  }

  // `timeout` guards against plugins that hang headless startup waiting on a
  // UI that never attaches.
  Process {
    id: nvimDump
    command: ["timeout", "8", "nvim", "--headless", "-c", "lua " + root.nvimDumpLua]
    environment: ({ "KB_NVIM_DUMP": root.dumpPath })
    onExited: function (code, status) {
      freshDump.reload()
    }
  }

  FileView {
    id: freshDump
    path: root.dumpPath
    onLoaded: {
      if (!root.buildNeovimTab(text()) && !root.nvimLoaded)
        root.upsertTab(root.placeholderNeovimTab("no keymaps found in the nvim dump"), 99)
    }
    onLoadFailed: {
      if (!root.nvimLoaded)
        root.upsertTab(root.placeholderNeovimTab("failed to run `nvim --headless` (binary in PATH?)"), 99)
    }
  }

  // --------------------------------------------------- terminal focus probe

  // Walks the process tree under the focused terminal looking for a TUI whose
  // tab we carry, so opening on top of `yazi` lands on the Yazi tab.
  readonly property var terminalApps: ({
    "nvim": "Neovim", "herdr": "Herdr", "spotify_player": "Spotify",
    "lazygit": "Lazygit", "yazi": "Yazi", "glow": "Glow", "tuicr": "Tuicr"
  })

  property int focusedPid: 0

  // Published for the surfaces to watch: the process-tree walk finishes after
  // they have already opened on a best guess.
  property string detectedApp: ""

  function setFocusedPid(raw) {
    try { root.focusedPid = JSON.parse(raw).pid || 0 } catch (e) { root.focusedPid = 0 }
    if (root.focusedPid) terminalProbe.running = true
  }

  function resolveTerminalTab(psOutput) {
    var focusedPid = root.focusedPid
    if (!focusedPid) return

    var children = {}
    var names = {}
    var lines = psOutput.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s+/)
      if (parts.length < 3) continue
      var pid = parseInt(parts[0])
      var ppid = parseInt(parts[1])
      if (!pid) continue
      if (!children[ppid]) children[ppid] = []
      children[ppid].push(pid)
      names[pid] = root.clean(parts.slice(2).join(" "), 64)
    }

    var queue = [focusedPid]
    while (queue.length) {
      var pid = queue.pop()
      var app = root.terminalApps[names[pid]]
      if (app) {
        if (root.tabIndexByApp(app) >= 0) root.detectedApp = app
        return
      }
      if (children[pid]) queue = queue.concat(children[pid])
    }
  }

  Process {
    id: activeWindowProbe
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector { onStreamFinished: root.setFocusedPid(text) }
  }

  Process {
    id: terminalProbe
    command: ["ps", "-e", "-o", "pid=,ppid=,comm="]
    stdout: StdioCollector { onStreamFinished: root.resolveTerminalTab(text) }
  }
}
