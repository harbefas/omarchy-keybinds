import QtQuick
import qs.Commons
import qs.Ui
import "KeybindSearch.js" as KeybindSearch

// The everyday surface: click the bar icon for a compact Key/Action list you
// can still tab through. The full overlay, with sections and the vim keys,
// is one press away from here or from the keybind.
BarWidget {
  id: root
  moduleName: "harbefas.keybinds"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("harbefas.keybinds") : null
  readonly property var tabs: service ? service.tabs : []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color secondary: Util.alpha(foreground, 0.55)
  readonly property color accent: Color.accent

  property bool popupOpen: false
  property string activeApp: ""
  property string filterText: ""
  property int selectedIndex: 0

  readonly property int activeTab: {
    if (!root.service) return 0
    var at = root.service.tabIndexByApp(root.activeApp)
    return at >= 0 ? at : 0
  }

  readonly property var rows: {
    if (!root.service || root.activeTab >= root.tabs.length) return []
    var flat = root.service.flatRows(root.tabs[root.activeTab])
    var aliases = (root.tabs[root.activeTab].aliases || []).join(" ")
    return KeybindSearch.filterBinds(flat, aliases, root.filterText)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function openPopup() {
    if (root.service) {
      root.service.refresh()
      root.activeApp = root.service.guessAppForFocus()
    }
    root.filterText = ""
    root.selectedIndex = 0
    root.popupOpen = true
    Qt.callLater(function () { rowList.forceActiveFocus() })
  }

  function closePopup() {
    root.popupOpen = false
  }

  function toggle() {
    root.popupOpen ? root.closePopup() : root.openPopup()
  }

  // Hand off to the overlay, which carries the sections column and the full
  // key handling. Hiding first keeps the two surfaces from overlapping.
  function openFull() {
    root.closePopup()
    if (!bar || !bar.shell) return
    var payload = JSON.stringify({ app: root.activeApp })
    if (typeof bar.shell.hide === "function" && typeof bar.shell.summon === "function") {
      bar.shell.hide("harbefas.keybinds")
      Qt.callLater(function () {
        if (root.bar && root.bar.shell) root.bar.shell.summon("harbefas.keybinds", payload)
      })
    } else if (typeof bar.shell.summon === "function") {
      bar.shell.summon("harbefas.keybinds", payload)
    }
  }

  function selectTab(delta) {
    if (root.tabs.length === 0) return
    var next = (root.activeTab + delta + root.tabs.length) % root.tabs.length
    root.activeApp = root.tabs[next].app
    root.selectedIndex = 0
  }

  function select(delta) {
    if (root.rows.length === 0) return
    root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    rowList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function handleKey(event) {
    event.accepted = true
    if (event.key === Qt.Key_Escape) {
      if (root.filterText) root.filterText = ""
      else root.closePopup()
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.openFull(); return }
    if (event.key === Qt.Key_Down) { root.select(1); return }
    if (event.key === Qt.Key_Up) { root.select(-1); return }
    if (event.key === Qt.Key_Right
        || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
      root.selectTab(1); return
    }
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab
        || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
      root.selectTab(-1); return
    }
    if (event.key === Qt.Key_Backspace) {
      root.filterText = root.filterText.slice(0, -1)
      root.selectedIndex = 0
      return
    }
    if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
      root.filterText += event.text
      root.selectedIndex = 0
      return
    }
    event.accepted = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    tooltipText: "Keybinds"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.openFull()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: rowList
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.space(8)

      // Tab strip, wrapping rather than eliding: the popup is narrower than
      // the overlay and the app list is long.
      Flow {
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.tabs

          Rectangle {
            required property var modelData
            required property int index
            radius: Style.cornerRadius
            color: index === root.activeTab ? Color.menu.selectedBackground : "transparent"
            implicitWidth: tabLabel.implicitWidth + Style.spacing.controlPaddingX
            implicitHeight: tabLabel.implicitHeight + Style.spacing.xs * 2

            Text {
              id: tabLabel
              anchors.centerIn: parent
              text: modelData.app
              textFormat: Text.PlainText
              color: index === root.activeTab ? root.accent : root.secondary
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: index === root.activeTab
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.activeApp = modelData.app
                root.selectedIndex = 0
              }
            }
          }
        }
      }

      ListView {
        id: rowList
        width: parent.width
        height: Math.min(Style.space(280), Math.max(Style.space(60), root.rows.length * Style.space(22)))
        clip: true
        model: root.rows
        currentIndex: root.selectedIndex
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) { root.handleKey(event) }

        delegate: Rectangle {
          required property var modelData
          required property int index
          width: rowList.width
          height: Style.space(22)
          color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
          radius: Style.cornerRadius

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.sm
            spacing: 0

            Text {
              width: Math.round(parent.width * 0.38)
              rightPadding: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.keys
              textFormat: Text.PlainText
              color: root.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              width: parent.width - Math.round(parent.width * 0.38) - Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.action
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: root.selectedIndex = index
            onDoubleClicked: root.openFull()
          }
        }
      }

      Text {
        width: parent.width
        visible: root.rows.length === 0
        text: root.tabs.length === 0 ? "loading…" : "no match"
        textFormat: Text.PlainText
        color: root.secondary
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        text: root.filterText
              ? "/ " + root.filterText
              : "Tab switch · type to search · Enter full view · Esc close"
        textFormat: Text.PlainText
        color: root.filterText ? root.accent : root.secondary
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
