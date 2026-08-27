import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "KeybindSearch.js" as KeybindSearch

// The full keybinding reference: one tab per app, opening on the tab matching
// whatever was focused when it was summoned. The bar widget is the everyday
// surface; this is the escape hatch, reached from there or from a keybind.
//
// All the data lives in Service.qml, shared with the bar widget.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property var service: root.shell && typeof root.shell.serviceFor === "function"
    ? root.shell.serviceFor("harbefas.keybinds") : null
  readonly property var tabs: root.service ? root.service.tabs : []

  function tabIndexByApp(app) {
    return root.service ? root.service.tabIndexByApp(app) : -1
  }

  property bool opened: false
  // Without an explicit screen the layer surface lands on whichever output
  // Quickshell picked first, which is rarely the one being looked at.
  property var targetScreen: null
  // Input is modal like the terminal build: normal keys navigate, `/` opens
  // search, `w` opens which-key narrowing.
  property string mode: "normal"
  property string filterText: ""
  property bool pendingG: false
  readonly property int halfPage: 10
  // Selection is held by app name, not index: tabs arrive asynchronously and
  // re-sort as they land, so an index goes stale between open() and the last
  // source resolving.
  property string activeApp: ""
  readonly property int activeTab: {
    var at = tabIndexByApp(root.activeApp)
    return at >= 0 ? at : 0
  }
  property int selectedIndex: 0

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
  property int cardWidth: Math.min(Style.space(880), Math.round(panel.width * 0.80))
  property int cardHeight: Math.min(Style.space(640), Math.round(panel.height * 0.74))
  property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.md * 2)

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
    root.mode = "normal"
    root.filterText = ""
    root.pendingG = false
    root.selectedIndex = 0
    if (root.service) {
      root.activeApp = root.service.guessAppForFocus()
      root.service.refresh()
    }
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

    var flat = root.service ? root.service.flatRows(tab) : []

    if (root.mode === "whichkey") {
      root.visibleRows = KeybindSearch.whichKeyFilter(flat, root.filterText)
    } else {
      var query = split.tab ? split.rest : root.filterText
      root.visibleRows = KeybindSearch.filterBinds(flat, (tab.aliases || []).join(" "), query)
    }

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

  // Clamped rather than wrapping, as a half-page jump should behave.
  function selectBy(delta) {
    if (root.visibleRows.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.visibleRows.length - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectEdge(top) {
    if (root.visibleRows.length === 0) return
    root.selectedIndex = top ? 0 : root.visibleRows.length - 1
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function enterMode(next) {
    root.mode = next
    root.filterText = ""
    root.selectedIndex = 0
    root.pendingG = false
    root.rebuildRows()
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
        anchors.margins: root.contentMargin
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          event.accepted = true
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

          // Arrows and Tab work in every mode, so the overlay stays usable
          // without knowing the vim bindings.
          if (event.key === Qt.Key_Down) { root.select(1); return }
          if (event.key === Qt.Key_Up) { root.select(-1); return }
          if (event.key === Qt.Key_Right) { root.selectTab(1); return }
          if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) { root.selectTab(-1); return }
          if (event.key === Qt.Key_Tab) {
            root.selectTab((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.mode !== "normal") root.enterMode("normal")
            else root.dismiss()
            return
          }

          if (root.mode === "normal") {
            if (ctrl && event.key === Qt.Key_D) { root.selectBy(root.halfPage); return }
            if (ctrl && event.key === Qt.Key_U) { root.selectBy(-root.halfPage); return }

            switch (event.text) {
            case "h": root.selectTab(-1); return
            case "l": root.selectTab(1); return
            case "j": root.select(1); return
            case "k": root.select(-1); return
            case "G": root.selectEdge(false); return
            case "/": root.enterMode("search"); return
            case "w": root.enterMode("whichkey"); return
            case "q": root.dismiss(); return
            case "g":
              // `gg` jumps to the top; a lone `g` waits for the second press.
              if (root.pendingG) { root.pendingG = false; root.selectEdge(true) }
              else root.pendingG = true
              return
            }
            root.pendingG = false
            return
          }

          // search and which-key both type into filterText.
          if (event.key === Qt.Key_Backspace) {
            if (!root.filterText) root.enterMode("normal")
            else root.setFilter(root.filterText.slice(0, -1))
            return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.mode = "normal"
            return
          }
          if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
            root.setFilter(root.filterText + event.text)
            return
          }
          event.accepted = false
        }

        // Column widths mirror the terminal build's table: a narrow section
        // gutter, a key column wide enough for "Prefix + shift + n / alt",
        // and the action taking whatever is left.
        readonly property real sectionWidth: Math.round(width * 0.18)
        readonly property real keysWidth: Math.round(width * 0.32)

        Column {
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.lg
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

            // The label straddles the frame's top line and has to hide the
            // stretch behind it. A child with z:-1 is painted behind its own
            // parent — border included — so the mask is a plain sibling
            // declared before the text instead.
            Item {
              x: Style.spacing.md
              y: -Math.round(height / 2)
              width: labelText.implicitWidth + Style.spacing.sm * 2
              height: labelText.implicitHeight

              Rectangle {
                anchors.fill: parent
                color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
              }

              Text {
                id: labelText
                anchors.centerIn: parent
                text: "keybinds"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                textFormat: Text.PlainText
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              id: tabRow
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
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
                    textFormat: Text.PlainText
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    text: modelData.app
                    color: index === root.activeTab ? root.accent : root.foreground
                    opacity: index === root.activeTab ? 1.0 : 0.65
                    font.family: root.fontFamily
                    textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  width: keyCatcher.keysWidth
                  text: "Key"
                  color: root.foreground
                  font.family: root.fontFamily
                  textFormat: Text.PlainText
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Action"
                  color: root.foreground
                  font.family: root.fontFamily
                  textFormat: Text.PlainText
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              ListView {
                id: resultList
                width: parent.width
                height: {
                  var available = parent.height - root.rowHeight - Style.spacing.sm
                  return Math.max(root.rowHeight, Math.floor(available / root.rowHeight) * root.rowHeight)
                }
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
                      rightPadding: Style.spacing.md
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.section
                      color: root.foreground
                      opacity: 0.6
                      font.family: root.fontFamily
                      textFormat: Text.PlainText
                      font.pixelSize: Style.font.body
                      font.bold: index === root.selectedIndex
                      elide: Text.ElideRight
                    }

                    Text {
                      width: keyCatcher.keysWidth
                      rightPadding: Style.spacing.md
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.keys
                      color: root.accent
                      font.family: root.fontFamily
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
          text: {
            if (root.mode === "search") return "/ " + root.filterText
            if (root.mode === "whichkey") return "w " + root.filterText
            return "h/l switch tab · j/k navigate · Ctrl+d/u half page · gg/G top/bottom · / search · w which-key · q quit"
          }
          color: root.mode === "normal" ? root.foreground : root.accent
          opacity: root.mode === "normal" ? 0.75 : 1.0
          font.family: root.fontFamily
          textFormat: Text.PlainText
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
