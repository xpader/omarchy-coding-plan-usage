import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Util.js" as Util

// Bar widget + popup for coding-plan usage across LLM platforms.
// Every enabled platform renders as its own stacked section (hero, status,
// usage windows, key editor); no tabs. All platform knowledge lives behind
// Providers.qml — this file only renders the provider contract.
Panel {
  id: root
  moduleName: "pader.coding-plan-usage"
  ipcTarget: "pader.coding-plan-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property double nowMs: Date.now()

  // Text fields report focus here so the key catcher stands down while
  // someone is typing in any provider's editor.
  property int keyFieldActiveCount: 0
  readonly property bool keyFieldActive: keyFieldActiveCount > 0

  // Which providers currently have their editor flipped open by hand,
  // keyed by providerId. Reassigning the object emits the change signal;
  // clearing it on panel open gives every section a clean slate.
  property var editorState: ({})

  // Live section objects, registered on completion, so keyboard shortcuts
  // and the open-focus logic can reach a specific provider's field.
  property var sections: []

  function setEditorOpen(id, open) {
    var next = {}
    for (var k in editorState) next[k] = editorState[k]
    if (open) next[id] = true
    else delete next[id]
    editorState = next
  }

  function sectionFor(id) {
    for (var i = 0; i < sections.length; i++)
      if (sections[i] && sections[i].provider && sections[i].provider.providerId === id)
        return sections[i]
    return null
  }

  function toggleEditorFor(id) {
    var opening = editorState[id] !== true
    setEditorOpen(id, opening)
    if (opening) focusEditorFor(id)
  }

  function focusEditorFor(id) {
    Qt.callLater(function() {
      var s = sectionFor(id)
      if (s) s.focusKeyField()
    })
  }

  // "e" targets the first provider that still needs a key pasted in —
  // that is the one situation where the keyboard path really matters.
  function firstKeylessProvider() {
    for (var i = 0; i < providerList.length; i++)
      if (providerList[i].state === "no-key") return providerList[i]
    return null
  }

  Providers {
    id: providers
    settings: root.settings
  }

  readonly property var providerList: providers.providers

  // ------------------------------------------------------------- bar pill

  readonly property string gaugeGlyph: "\uF0374" // nf-md-gauge
  readonly property string keyGlyph: "\uF023D"   // nf-md-key

  // Each provider contributes at most one value segment (GLM: 5h percent
  // once used; DeepSeek: today's spend once > 0). Segments only exist when
  // they carry information — a quiet bar means nothing to report.
  readonly property var barSegments: {
    var segs = []
    for (var i = 0; i < providerList.length; i++) {
      var p = providerList[i]
      if (p && p.state === "ok" && p.barSegments) segs = segs.concat(p.barSegments)
    }
    return segs
  }

  readonly property bool anySegmentUrgent: {
    for (var i = 0; i < barSegments.length; i++)
      if (barSegments[i].urgent) return true
    return false
  }

  // Fallback states when no segment carries data: error/no-key/loading
  // keep the pill alive so the panel (and its key editors) stays reachable.
  readonly property string barStatus: {
    if (barSegments.length > 0) return "ok"
    for (var i = 0; i < providerList.length; i++)
      if (providerList[i].state === "error") return "error"
    if (providers.anyKeyMissing) return "no-key"
    return "loading"
  }


  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function severityColor(percent) {
    var s = Util.severity(percent)
    if (s === "urgent") return urgent
    if (s === "accent") return accent
    return foreground
  }

  function refreshNow() {
    providers.refreshAll()
  }

  function providerMeta(p) {
    if (!p) return ""
    if (p.state === "no-key") return "No API key"
    if (p.state === "loading") return "Loading"
    if (p.state === "error") return "Error"
    return p.planLabel !== "" ? p.planLabel : "Coding plan"
  }

  // Reset line under a meter: point-in-time, countdown, then usage numbers.
  // Balance windows have no reset schedule — the amount is the title row's
  // trailing value, so they get no meta line at all.
  function windowMeta(w) {
    if (!w) return ""
    if (w.kind === "balance") return ""
    var parts = []
    if (w.resetAtMs > 0) {
      var at = Util.formatResetTime(w.resetAtMs, nowMs)
      var left = Util.formatCountdown(w.resetAtMs, nowMs)
      parts.push("Resets " + at + (left !== "" ? " · in " + left : ""))
    } else {
      parts.push("Resets after the next request")
    }
    var used = Util.formatUsedLimit(w.used, w.limit, w.unit)
    if (used !== "") parts.push(used)
    return parts.join(" · ")
  }

  readonly property double latestUpdateMs: {
    var t = 0
    for (var i = 0; i < providerList.length; i++)
      t = Math.max(t, Number(providerList[i].updatedAtMs))
    return t
  }

  readonly property bool anyRefreshing: {
    for (var i = 0; i < providerList.length; i++)
      if (providerList[i].refreshing) return true
    return false
  }

  visible: providerList.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    editorState = ({})
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
    })
  }

  // Keeps countdowns honest while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function status(): string {
      var out = []
      for (var i = 0; i < root.providerList.length; i++) {
        var p = root.providerList[i]
        out.push({
          id: p.providerId,
          state: p.state,
          statusText: p.statusText,
          plan: p.planLabel,
          windows: p.windows,
          headline: p.headlinePercent
        })
      }
      return JSON.stringify(out)
    }
  }

  // Glyph-only fallback for states without data (loading/no-key/error).
  readonly property string barFallbackText: {
    if (barStatus === "error") return gaugeGlyph + " !"
    if (barStatus === "no-key") return keyGlyph
    return gaugeGlyph
  }

  BrandPill {
    id: button
    anchors.fill: parent
    segments: root.barSegments
    fallbackText: root.barFallbackText
    // Bar text rides barForeground (base Ui/Panel property): in transparent
    // bar mode that is the wallpaper-contrast color every stock widget uses.
    // bar.foreground is the raw theme/shell.toml value and ignores that
    // recomputation, so the pill would diverge from the rest of the bar.
    foreground: root.barForeground
    urgentColor: root.urgent
    dim: Qt.darker(root.barForeground, 1.55)
    active: root.anySegmentUrgent
    dimmed: root.barStatus === "no-key"
    // Match neighboring BarIconButton widgets (power/battery, audio, network):
    // icon+value text renders at Style.bar.iconFont, not caption.
    fontSize: Style.bar.iconFont
    fontFamily: root.fontFamily
    tooltipText: {
      if (root.barSegments.length > 0) {
        var lines = []
        for (var i = 0; i < root.barSegments.length; i++)
          lines.push(root.barSegments[i].tooltip)
        return lines.join("\n")
      }
      if (root.barStatus === "no-key") return "Coding plan usage — click to set an API key"
      if (root.barStatus === "error") return "Coding plan usage — click for details"
      return "Coding plan usage"
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) root.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Bands bleed to the panel border: no padding here, spacing only inside
    // each band (sections carry their own 12px inset).
    padding: 0
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.keyFieldActive

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        // "k" is taken by the kit's vim navigation; "e" opens the key editor
        // of the first provider still missing its key.
        else if (t === "e" || t === "E") {
          var p = root.firstKeylessProvider()
          if (p) root.toggleEditorFor(p.providerId)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: 0

          Repeater {
            model: root.providerList

            ProviderSection {
              required property var modelData
              required property int index
              width: column.width
              provider: modelData
              sectionIndex: index
            }
          }
          // ---------- Footer (kept off the last band by a spacer) ----------
          Item { width: parent.width; height: Style.space(12) }

          Item {
            width: parent.width
            implicitHeight: footerRow.implicitHeight + Style.space(12)

            Item {
              id: footerRow
              x: Style.space(12)
              width: parent.width - Style.space(24)
              implicitHeight: Math.max(updatedText.implicitHeight, refreshButton.implicitHeight)

              Text {
                id: updatedText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              text: root.latestUpdateMs > 0
                ? "Updated " + Util.formatClock(root.latestUpdateMs)
                : (root.anyRefreshing ? "Refreshing…" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              PanelActionButton {
                id: refreshButton
                iconText: "\uF021" // nf-fa-refresh
                tooltipText: "Refresh now"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refreshNow()
              }
            }
            }
          }
        }
      }
    }
  }

  // One stacked platform as a full-width band: hero, status, usage windows
  // and its own key editor. Odd/even rows alternate between two subtle
  // foreground washes; square corners + the gaps around each band (column
  // spacing, panel padding) keep them reading as stacked blocks rather
  // than floating cards.
  // Bar pill with inline brand marks: [logo] 18% · [logo] ¥1.23.
  // Home-grown because WidgetButton is text-only; interaction shell
  // (tooltip/click/cursor) mirrors WidgetButton.qml.
  component BrandPill: Item {
    id: pill

    property var segments: []
    property string fallbackText: ""
    property color foreground: Color.foreground
    property color urgentColor: Color.urgent
    property color dim: Qt.darker(foreground, 1.55)
    property bool active: false
    property bool dimmed: false
    property real fontSize: Style.font.caption
    property string fontFamily: Style.font.family
    property string tooltipText: ""

    signal pressed(int button)

    readonly property real hMargin: Style.spaceReal(8.5)

    implicitWidth: content.implicitWidth + hMargin * 2
    implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal
    opacity: content.implicitWidth > 0 ? (dimmed ? 0.45 : 1) : 0

    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.spacing.xs

      Text {
        visible: pill.segments.length === 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: pill.fallbackText
        color: pill.active ? pill.urgentColor : pill.foreground
        font.family: pill.fontFamily
        font.pixelSize: pill.fontSize
      }

      Repeater {
        model: pill.segments

        Row {
          required property var modelData
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          Text {
            visible: index > 0
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "·"
            color: pill.dim
            font.family: pill.fontFamily
            font.pixelSize: pill.fontSize
          }

          Image {
            visible: String(modelData.brandIcon || "") !== ""
            // Hang the mark off the text baseline so its optical center
            // (mid cap-height, digits have no descenders) lines up with "18%".
            anchors.baseline: segText.baseline
            // Image's baseline is its TOP edge; put the mark's optical
            // center (mid cap-height) on the digits' optical center.
            anchors.baselineOffset: -pill.fontSize * 0.93
            width: pill.fontSize * 1.15
            height: pill.fontSize * 1.15
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            source: visible ? modelData.brandIcon : ""
          }

          Text {
            id: segText
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: (String(modelData.brandIcon || "") === "" ? modelData.icon + " " : "") + modelData.text
            color: modelData.urgent ? pill.urgentColor : pill.foreground
            font.family: pill.fontFamily
            font.pixelSize: pill.fontSize
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(pill, pill.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(pill)
      onClicked: function(mouse) {
        if (root.bar) root.bar.hideTooltip(pill)
        pill.pressed(mouse.button)
      }
      onWheel: function(wheel) {
        if (root.bar) root.bar.hideTooltip(pill)
        root.refreshNow()
      }
    }
  }

  component ProviderSection: BorderSurface {
    id: section
    property var provider: null
    property int sectionIndex: 0

    readonly property bool editorOpen: {
      if (!provider) return false
      return root.editorState[provider.providerId] === true
    }

    // Alternating stripes: even bands stay on the panel's own background,
    // odd bands get one subtle wash — just enough to tell platforms apart.
    color: section.sectionIndex % 2 === 0
      ? "transparent"
      : root.alpha(root.foreground, 0.07)
    padding: Style.space(12)
    implicitHeight: sectionColumn.implicitHeight + contentTopInset + contentBottomInset

    Component.onCompleted: root.sections.push(section)
    Component.onDestruction: {
      var i = root.sections.indexOf(section)
      if (i >= 0) root.sections.splice(i, 1)
    }

    onEditorOpenChanged: if (!editorOpen) keyInput.text = ""

    function toggleEditor() {
      root.toggleEditorFor(provider.providerId)
    }

    function saveKey() {
      if (!provider) return
      var value = String(keyInput.text || "").trim()
      if (value === "") return
      provider.setKey(value)
      keyInput.text = ""
      root.setEditorOpen(provider.providerId, false)
      keyCatcher.forceActiveFocus()
    }

    function focusKeyField() {
      Qt.callLater(function() {
        keyInput.text = ""
        keyInput.forceActiveFocus()
      })
    }

    Column {
      id: sectionColumn
      x: section.contentLeftInset
      y: section.contentTopInset
      width: section.width - section.contentLeftInset - section.contentRightInset
      spacing: Style.space(12)

      // ---------- Hero: platform mark · name · plan · key ----------
      PanelHero {
      visible: !!section.provider
      width: parent.width
      title: section.provider ? section.provider.providerName : ""
      meta: root.providerMeta(section.provider)
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconOpacity: section.provider && section.provider.state === "ok" ? 1.0 : 0.5

      iconComponent: Component {
        Item {
          width: Style.font.display
          height: Style.font.display

          // Brand mark (SVG) when the provider ships one, glyph otherwise.
          Image {
            anchors.centerIn: parent
            visible: section.provider && String(section.provider.brandIcon) !== ""
            width: Style.font.display
            height: Style.font.display
            fillMode: Image.PreserveAspectFit
            // Decode at physical pixels so SVG stays sharp on HiDPI.
            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            source: visible ? section.provider.brandIcon : ""
            opacity: section.provider && section.provider.state === "ok" ? 1.0 : 0.6
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: !section.provider || String(section.provider.brandIcon) === ""
            text: section.provider ? section.provider.iconGlyph : root.gaugeGlyph
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
      }

      // One key button on the trailing edge toggles this provider's key
      // editor (field, save/remove/cancel) below the usage windows.
      trailingControl: Component {
        PanelActionButton {
          iconText: "\uF023D" // nf-md-key
          tooltipText: section.editorOpen ? "Close key editor" : "API key"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          bordered: section.editorOpen
          onClicked: section.toggleEditor()
        }
      }
    }

    // ---------- No-key hint (replaces the auto-opened editor) ----------
    // One quiet line instead of a big input field; clicking it (or `e`)
    // expands this provider's key editor below.
    Button {
      visible: !!section.provider && section.provider.state === "no-key" && !section.editorOpen
      width: parent.width
      iconText: "\uF023D" // nf-md-key
      text: "No API key — click to set one"
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
      onClicked: root.toggleEditorFor(section.provider.providerId)
    }

    // ---------- Status / error ----------
    BorderSurface {
      visible: !!section.provider && section.provider.state === "error" && section.provider.statusText !== "" && !section.editorOpen
      width: parent.width
      implicitHeight: errorText.implicitHeight + Style.spacing.xl * 2
      color: root.alpha(root.urgent, 0.10)
      borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
      radius: Style.cornerRadius

      Text {
        id: errorText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        text: section.provider ? section.provider.statusText : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Text {
      visible: !!section.provider && section.provider.state !== "error" && section.provider.statusText !== "" && !section.editorOpen
      width: parent.width
      text: section.provider ? section.provider.statusText : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // ---------- Quota windows (hidden while the key editor is open) ----------
    Column {
      id: limitsSection
      visible: !!section.provider && section.provider.state === "ok" && section.provider.windows.length > 0 && !section.editorOpen
      width: parent.width
      spacing: Style.space(12)

      PanelSectionHeader {
        text: section.provider ? section.provider.usageHeader : "LIMITS"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Repeater {
        model: section.provider ? section.provider.windows : []

        WindowRow {
          required property var modelData
          width: limitsSection.width
          window: modelData
        }
      }
    }

    // ---------- Key editor ----------
    Column {
      id: keyEditor
      visible: section.editorOpen
      width: parent.width
      spacing: Style.space(8)

      PanelSectionHeader {
        text: "API KEY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      TextField {
        id: keyInput
        width: parent.width
        password: true
        placeholderText: section.provider ? "Paste " + section.provider.keyLabel : ""
        foreground: root.foreground
        onActiveFocusChanged: if (activeFocus) root.keyFieldActiveCount++
                              else root.keyFieldActiveCount = Math.max(0, root.keyFieldActiveCount - 1)
        onAccepted: section.saveKey()
        Keys.onEscapePressed: {
          if (section.provider) root.setEditorOpen(section.provider.providerId, false)
          keyCatcher.forceActiveFocus()
        }
      }

      // Save/Cancel keep the button shape on the left; Remove is
      // de-emphasized to a plain dim text action on the right.
      Item {
        width: parent.width
        implicitHeight: keyActionsRow.implicitHeight

        Row {
          id: keyActionsRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Button {
            text: "Save"
            bordered: true
            active: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: section.saveKey()
          }

          Button {
            text: "Cancel"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: section.toggleEditor()
          }
        }

        Button {
          visible: section.provider && section.provider.hasApiKey
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Remove"
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.xs
          verticalPadding: Style.spacing.xxs
          onClicked: {
            if (section.provider) section.provider.clearKey()
            keyInput.text = ""
            root.setEditorOpen(section.provider.providerId, false)
            keyCatcher.forceActiveFocus()
          }
        }
      }

      Text {
        width: parent.width
        text: section.provider
          ? "Stored locally at " + section.provider.stateDir + "/keys/" + section.provider.providerId
          : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      }
    }
  }

  // One quota window: label + percent, meter, reset/usage line, per-model
  // breakdown.
  component WindowRow: Column {
    id: windowRow
    property var window: null

    readonly property real percent: window ? Number(window.percent) : -1
    readonly property bool alarming: percent >= 90

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(windowLabel.implicitHeight, windowValue.implicitHeight)

      Text {
        id: windowLabel
        textFormat: Text.PlainText
        text: windowRow.window ? windowRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: windowValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: windowValue
        textFormat: Text.PlainText
        // Quota rows trail with their percent; balance rows with the amount.
        text: windowRow.percent >= 0
          ? Util.formatPercent(windowRow.percent)
          : (windowRow.window && windowRow.window.valueText ? windowRow.window.valueText : "")
        color: root.severityColor(windowRow.percent)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      visible: windowRow.percent >= 0
      width: parent.width
      value: windowRow.percent / 100
      fillColor: root.severityColor(windowRow.percent)
      alarming: windowRow.alarming
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      text: root.windowMeta(windowRow.window)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Per-model / per-tool breakdown as one wrapped line instead of one
    // bar row per entry.
    Text {
      visible: windowRow.window && windowRow.window.details.length > 0 && text !== ""
      width: parent.width
      text: {
        if (!windowRow.window) return ""
        var parts = []
        var details = windowRow.window.details
        for (var i = 0; i < details.length; i++)
          parts.push(details[i].name + " " + Util.formatCountFor(details[i].value, windowRow.window.unit))
        return parts.join("  ·  ")
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // Rounded track showing the used share of a quota window.
  component Meter: Item {
    id: meter
    property real value: -1
    property color fillColor: root.foreground
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : meter.fillColor

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}
