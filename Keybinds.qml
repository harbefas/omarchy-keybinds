import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "KeybindSearch.js" as KeybindSearch

// Searchable keybinding reference. One tab per app, opening on the tab that
// matches whatever was focused when the overlay was summoned.
//
// Hyprland's binds come live from `hyprctl binds -j` and Neovim's from a
// headless keymap dump; the rest are hand-copied defaults in data/*.json.
// Nothing outside Hyprland, Quickshell, and an optional nvim is needed.
Item {
  id: root

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/harbefas.keybinds"
  property var shell: null
  property var manifest: null

  property bool opened: false
  // Without an explicit screen the layer surface lands on whichever output
  // Quickshell picked first, which is rarely the one being looked at.
  property var targetScreen: null
  property string filterText: ""
  // Selection is held by app name, not index: tabs arrive asynchronously and
  // re-sort as they land, so an index goes stale between open() and the last
  // source resolving.
  property string activeApp: ""
  readonly property int activeTab: {
    var at = tabIndexByApp(root.activeApp)
    return at >= 0 ? at : 0
  }
  property int selectedIndex: 0

  // Every tab: { app, aliases: [], windowClass: [], sections: [{name, binds}] }.
  // Hyprland and Neovim are placeheld at fixed indices so their async loads
  // can drop straight into place without reshuffling the strip.
  property var tabs: []
  property var visibleRows: []

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy
  // menu styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  // Sized like a dialog, not a fullscreen takeover: capped in absolute terms
  // and again as a share of the screen so it stays a card on a small display.
  property int cardWidth: Math.min(Style.space(720), Math.round(panel.width * 0.66))
  property int cardHeight: Math.min(Style.space(560), Math.round(panel.height * 0.62))
  property int rowHeight: Math.max(Style.space(26), Style.font.body + Style.spacing.sm * 2)

  // ---------------------------------------------------------------- lifecycle

  function currentScreen() {
    var name = ""
    try { name = Hyprland.focusedMonitor.name } catch (e) { name = "" }
    if (!name) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  function open(payloadJson) {
    root.targetScreen = root.currentScreen()
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.activeApp = guessAppForFocus()
    root.refreshHyprland()
    root.loadNeovim()
    root.rebuildRows()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "harbefas.keybinds")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
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
    var next = root.tabs.slice()
    var at = -1
    for (var i = 0; i < next.length; i++)
      if (next[i].app === tab.app) { at = i; break }

    tab.order = order
    if (at >= 0) next[at] = tab
    else next.push(tab)

    next.sort(function (a, b) { return a.order - b.order })
    root.tabs = next
    if (!root.activeApp && next.length > 0) root.activeApp = next[0].app
    root.rebuildRows()
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

    // A terminal window says nothing about which TUI is running inside it, so
    // ask the process tree; the answer arrives async and re-selects the tab.
    if (["ghostty", "com.mitchellh.ghostty", "kitty", "alacritty", "foot"].some(function (t) {
      return appId.indexOf(t) >= 0
    })) {
      terminalProbe.running = true
    }
    return fallback
  }

  // ------------------------------------------------------------------- rows

  function currentTab() {
    if (root.activeTab < 0 || root.activeTab >= root.tabs.length) return null
    return root.tabs[root.activeTab]
  }

  function rebuildRows() {
    var split = KeybindSearch.splitAtTab(root.filterText)
    if (split.tab) {
      var target = matchTabToken(split.tab)
      if (target >= 0 && target !== root.activeTab) root.activeApp = root.tabs[target].app
    }

    var tab = currentTab()
    if (!tab) { root.visibleRows = []; return }

    var flat = []
    for (var s = 0; s < tab.sections.length; s++) {
      var section = tab.sections[s]
      for (var b = 0; b < section.binds.length; b++) {
        flat.push({
          section: section.name,
          keys: section.binds[b].keys,
          action: section.binds[b].action
        })
      }
    }

    var query = split.tab ? split.rest : root.filterText
    root.visibleRows = KeybindSearch.filterBinds(flat, (tab.aliases || []).join(" "), query)

    if (root.selectedIndex >= root.visibleRows.length)
      root.selectedIndex = Math.max(0, root.visibleRows.length - 1)
  }

  // `@vim` matches the tab's name or any of its aliases, by prefix.
  function matchTabToken(token) {
    var needle = token.toLowerCase()
    for (var i = 0; i < root.tabs.length; i++) {
      var tab = root.tabs[i]
      if (tab.app.toLowerCase().indexOf(needle) === 0) return i
      var aliases = tab.aliases || []
      for (var a = 0; a < aliases.length; a++)
        if (aliases[a].toLowerCase().indexOf(needle) === 0) return i
    }
    return -1
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuildRows()
  }

  function selectTab(delta) {
    if (root.tabs.length === 0) return
    var next = (root.activeTab + delta + root.tabs.length) % root.tabs.length
    root.activeApp = root.tabs[next].app
    root.selectedIndex = 0
    root.rebuildRows()
  }

  function select(delta) {
    if (root.visibleRows.length === 0) return
    root.selectedIndex = (root.selectedIndex + delta + root.visibleRows.length) % root.visibleRows.length
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
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

  function resolveTerminalTab(psOutput) {
    var focusedPid = 0
    try { focusedPid = Hyprland.activeToplevel.lastIpcObject.pid || 0 } catch (e) { return }
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
      names[pid] = parts.slice(2).join(" ")
    }

    var queue = [focusedPid]
    while (queue.length) {
      var pid = queue.pop()
      var app = root.terminalApps[names[pid]]
      if (app) {
        if (root.tabIndexByApp(app) >= 0) { root.activeApp = app; root.rebuildRows() }
        return
      }
      if (children[pid]) queue = queue.concat(children[pid])
    }
  }

  Process {
    id: terminalProbe
    command: ["ps", "-e", "-o", "pid=,ppid=,comm="]
    stdout: StdioCollector { onStreamFinished: root.resolveTerminalTab(text) }
  }

  // -------------------------------------------------------------------- ui

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-keybinds"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
            root.select(1); event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
            root.select(-1); event.accepted = true
          } else if (event.key === Qt.Key_Right || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
            root.selectTab(1); event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab
                     || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            root.selectTab(-1); event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            root.setFilter(root.filterText.slice(0, -1)); event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
            root.setFilter(root.filterText + event.text); event.accepted = true
          }
        }

        // Column widths mirror the terminal build's table: a narrow section
        // gutter, a key column wide enough for "Prefix + shift + n / alt",
        // and the action taking whatever is left.
        readonly property real sectionWidth: Math.round(width * 0.20)
        readonly property real keysWidth: Math.round(width * 0.28)

        Column {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.spacing.md
          spacing: Style.spacing.md

          // Tab strip, framed and labelled like the TUI's bordered block.
          Rectangle {
            id: tabFrame
            width: parent.width
            height: tabRow.height + Style.spacing.md * 2
            color: "transparent"
            border.color: root.border
            border.width: 1
            radius: root.cornerRadius

            Row {
              id: tabRow
              anchors.centerIn: parent
              spacing: 0

              Repeater {
                model: root.tabs

                Row {
                  required property var modelData
                  required property int index
                  spacing: 0

                  Text {
                    text: "  |  "
                    visible: index > 0
                    color: root.border
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    text: modelData.app
                    color: index === root.activeTab ? root.accent : root.foreground
                    opacity: index === root.activeTab ? 1.0 : 0.65
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: index === root.activeTab

                    MouseArea {
                      anchors.fill: parent
                      onClicked: {
                        root.activeApp = modelData.app
                        root.selectedIndex = 0
                        root.rebuildRows()
                      }
                    }
                  }
                }
              }
            }
          }

          // Table
          Rectangle {
            width: parent.width
            height: parent.height - tabFrame.height - Style.spacing.md
            color: "transparent"
            border.color: root.border
            border.width: 1
            radius: root.cornerRadius

            Column {
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              spacing: Style.spacing.sm

              Row {
                width: parent.width
                height: root.rowHeight
                spacing: 0

                Text {
                  width: keyCatcher.sectionWidth
                  text: "Section"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  width: keyCatcher.keysWidth
                  text: "Key"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Action"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              ListView {
                id: resultList
                width: parent.width
                height: parent.height - root.rowHeight - Style.spacing.sm
                clip: true
                model: root.visibleRows
                currentIndex: root.selectedIndex

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  width: resultList.width
                  height: root.rowHeight
                  color: index === root.selectedIndex ? root.selectedBackground : "transparent"

                  // Selection marker, as in the TUI.
                  Rectangle {
                    width: Math.max(2, Style.space(2))
                    height: parent.height
                    color: root.accent
                    visible: index === root.selectedIndex
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.sm
                    spacing: 0

                    Text {
                      width: keyCatcher.sectionWidth
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.section
                      color: root.foreground
                      opacity: 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: index === root.selectedIndex
                      elide: Text.ElideRight
                    }

                    Text {
                      width: keyCatcher.keysWidth
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.keys
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: index === root.selectedIndex
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width - keyCatcher.sectionWidth - keyCatcher.keysWidth - Style.spacing.sm
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.action
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: index === root.selectedIndex
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.visibleRows.length === 0
              text: root.tabs.length === 0 ? "loading keybindings…" : "no match"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // The search line doubles as the hint bar, like the TUI's footer.
        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          leftPadding: Style.spacing.sm
          text: root.filterText
                ? "/ " + root.filterText
                : "Tab switch · ↑/↓ navigate · type to search · @tab to jump · Esc close"
          color: root.filterText ? root.accent : root.foreground
          opacity: root.filterText ? 1.0 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
