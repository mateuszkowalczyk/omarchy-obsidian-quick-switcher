import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool filesLoaded: false
  property bool aliasesLoaded: false
  property bool cursorActive: false
  property bool stoppingProcesses: false
  property bool searchQueued: false
  property bool searchBusy: false
  property bool emptySearchResult: false
  property bool recentsLoaded: false
  property string filterText: ""
  property string vault: ""
  property string filesOutput: ""
  property string aliasesOutput: ""
  property string recentsOutput: ""
  property string fzfInput: ""
  property string errorText: ""
  property string activeSearchQuery: ""
  property int searchRevision: 0
  property int activeSearchRevision: 0
  property int selectedIndex: 0
  property var notes: []
  property var activeResultModel: displayModel

  readonly property bool indexReady: filesLoaded && aliasesLoaded
  readonly property bool showResults: opened

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property color createActionColor: Color.accent
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(42), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  property int rowPeek: Math.round(rowHeight * 0.55)
  property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
  property int resultHeight: {
    if (!showResults) return 0
    if (!activeResultModel || activeResultModel.count === 0) return root.rowHeight
    var fullHeight = activeResultModel.count * root.rowHeight + Math.max(0, activeResultModel.count - 1) * root.rowSpacing
    var foldedHeight = 7 * root.rowHeight + 7 * root.rowSpacing + root.rowPeek
    var maxResultHeight = Math.max(root.rowHeight,
      panel.maxCardHeight - root.contentMargin * 2 - root.headerHeight - root.contentSpacing)
    return Math.min(fullHeight, foldedHeight, maxResultHeight)
  }
  property int cardHeight: contentMargin * 2 + headerHeight + (showResults ? contentSpacing + resultHeight : 0)

  readonly property string fieldSeparator: "\x1f"
  readonly property string inputSentinel: "\x1eOMARCHY_OBSIDIAN_END\x1e"
  readonly property string fzfCommand:
    "IFS= read -r query || exit 0; "
    + "while IFS= read -r row; do "
    + "[[ $row == $'\\036OMARCHY_OBSIDIAN_END\\036' ]] && break; "
    + "printf '%s\\n' \"$row\"; "
    + "done | fzf --filter=\"$query\" --delimiter=$'\\037' --nth=2.. "
    + "--tiebreak=begin,length,index --no-multi"
  readonly property string obsidianIndexCommand:
    "vault_args=(); "
    + "[[ -n $1 ]] && vault_args=(\"vault=$1\"); "
    + "sleep 0.3; "
    + "for ((attempt = 0; attempt < 12; attempt++)); do "
    + "count=$(timeout 1 obsidian files total \"${vault_args[@]}\" 2>/dev/null | tr -d '[:space:]'); "
    + "if [[ $count =~ ^[0-9]+$ ]]; then "
    + "if [[ $2 == files ]]; then exec obsidian files \"${vault_args[@]}\"; "
    + "else exec obsidian aliases verbose \"${vault_args[@]}\"; fi; "
    + "fi; "
    + "sleep 0.25; "
    + "done; "
      + "echo 'Obsidian CLI did not become ready within 15 seconds' >&2; exit 1"
  readonly property string obsidianRecentsCommand:
    "vault_args=(); "
    + "[[ -n $1 ]] && vault_args=(\"vault=$1\"); "
    + "sleep 0.3; "
    + "for ((attempt = 0; attempt < 12; attempt++)); do "
    + "count=$(timeout 1 obsidian files total \"${vault_args[@]}\" 2>/dev/null | tr -d '[:space:]'); "
    + "if [[ $count =~ ^[0-9]+$ ]]; then exec obsidian recents \"${vault_args[@]}\"; fi; "
    + "sleep 0.25; "
    + "done; "
    + "echo 'Obsidian CLI did not become ready within 15 seconds' >&2; exit 1"

  function open(payloadJson) {
    var payload = {}
    if (payloadJson) {
      try { payload = JSON.parse(payloadJson) || {} } catch (e) { payload = {} }
    }

    root.stopProcesses()
    root.clearSession()
    root.vault = String(payload.vault || "")
    root.opened = true
    root.startIndexLoad()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopProcesses()
    root.clearSession()
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mk.obsidian-quick-switcher")
    else
      root.close()
  }

  function clearSession() {
    root.filesLoaded = false
    root.aliasesLoaded = false
    root.cursorActive = false
    root.searchQueued = false
    root.searchBusy = false
    root.emptySearchResult = false
    root.filterText = ""
    root.filesOutput = ""
    root.aliasesOutput = ""
    root.recentsOutput = ""
    root.fzfInput = ""
    root.errorText = ""
    root.activeSearchQuery = ""
    root.searchRevision = 0
    root.activeSearchRevision = 0
    root.selectedIndex = 0
    root.notes = []
    root.recentsLoaded = false
    root.activeResultModel = recentModel
    displayModel.clear()
    stagingModel.clear()
    recentModel.clear()
    pointerGate.reset()
  }

  function stopProcesses() {
    root.stoppingProcesses = true
    filesProc.running = false
    aliasesProc.running = false
    recentProc.running = false
    searchProc.running = false
    root.searchBusy = false
    root.stoppingProcesses = false
  }

  function startIndexLoad() {
    root.filesLoaded = false
    root.aliasesLoaded = false
    // A first CLI call can turn into the long-running Electron app when
    // Obsidian is closed. Launch that app detached first, then let the owned
    // scan processes poll its command server. The bracketed pgrep pattern
    // avoids matching this shell command itself.
    Quickshell.execDetached([
      "bash", "-c",
      "pgrep -f '[o]bsidian/app.asar' >/dev/null || exec obsidian"
    ])

    // Poll a numeric file count before the real scans. Each probe is bounded
    // because a startup race must not turn a scan process into the app. Empty
    // vaults remain valid because zero is a numeric readiness response.
    filesProc.command = ["bash", "-c", root.obsidianIndexCommand, "obsidian-quick-switcher", root.vault, "files"]
    aliasesProc.command = ["bash", "-c", root.obsidianIndexCommand, "obsidian-quick-switcher", root.vault, "aliases"]
    recentProc.command = ["bash", "-c", root.obsidianRecentsCommand, "obsidian-quick-switcher", root.vault]
    filesProc.running = true
    aliasesProc.running = true
    recentProc.running = true
  }

  function cleanField(value) {
    return String(value || "")
      .replace(/\x00/g, "")
      .replace(/[\r\n]/g, " ")
      .replace(/\x1f/g, " ")
      .replace(/\x1e/g, " ")
  }

  function finishFiles(output) {
    if (!root.opened) return
    root.filesOutput = String(output || "")
    root.filesLoaded = true
    root.maybeBuildIndex()
  }

  function finishAliases(output) {
    if (!root.opened) return
    root.aliasesOutput = String(output || "")
    root.aliasesLoaded = true
    root.maybeBuildIndex()
  }

  function finishRecents(output) {
    if (!root.opened) return
    root.recentsOutput = String(output || "")
    root.recentsLoaded = true
    root.buildRecentModel()
  }

  function buildRecentModel() {
    if (!root.recentsLoaded) return

    var rows = []
    var seen = ({})
    var recentLines = root.recentsOutput.split("\n")
    for (var i = 0; i < recentLines.length; i++) {
      var path = root.cleanField(recentLines[i].trim())
      if (!path || seen[path]) continue
      seen[path] = true

      var title = root.titleForPath(path)
      var aliases = ""
      for (var j = 0; j < root.notes.length; j++) {
        if (root.notes[j].path !== path) continue
        title = root.notes[j].title
        aliases = root.notes[j].aliases.join(" · ")
        break
      }
      rows.push({
        notePath: path,
        noteTitle: title,
        aliases: aliases,
        fileIcon: root.iconForPath(path)
      })
      if (rows.length >= 50) break
    }

    recentModel.clear()
    for (var k = 0; k < rows.length; k++) recentModel.append(rows[k])

    // Recent notes are the initial result set. Make the first row an actual
    // keyboard selection as soon as the asynchronous batch is ready.
    if (!root.filterText && root.activeResultModel === recentModel) {
      root.selectedIndex = 0
      root.cursorActive = recentModel.count > 0
      pointerGate.reset()
    }
  }

  function maybeBuildIndex() {
    if (!root.indexReady || root.errorText) return

    var byPath = ({})
    var order = []
    var fileLines = root.filesOutput.split("\n")
    for (var i = 0; i < fileLines.length; i++) {
      var path = root.cleanField(fileLines[i].trim())
      if (!path || byPath[path]) continue
      byPath[path] = { path: path, title: root.titleForPath(path), aliases: [] }
      order.push(path)
    }

    var aliasLines = root.aliasesOutput.split("\n")
    for (var j = 0; j < aliasLines.length; j++) {
      var line = aliasLines[j]
      var tab = line.indexOf("\t")
      if (tab < 1) continue
      var alias = root.cleanField(line.substring(0, tab).trim())
      var aliasPath = root.cleanField(line.substring(tab + 1).trim())
      if (!alias || !aliasPath) continue
      if (!byPath[aliasPath]) {
        byPath[aliasPath] = { path: aliasPath, title: root.titleForPath(aliasPath), aliases: [] }
        order.push(aliasPath)
      }
      if (byPath[aliasPath].aliases.indexOf(alias) < 0) byPath[aliasPath].aliases.push(alias)
    }

    var nextNotes = []
    var rows = []
    for (var k = 0; k < order.length; k++) {
      var note = byPath[order[k]]
      var noteIndex = nextNotes.length
      nextNotes.push(note)
      rows.push([
        String(noteIndex),
        root.cleanField(note.title),
        root.cleanField(note.path),
        root.cleanField(note.aliases.join(" "))
      ].join(root.fieldSeparator))
    }

    root.notes = nextNotes
    root.fzfInput = rows.join("\n") + (rows.length ? "\n" : "")
    if (root.recentsLoaded) root.buildRecentModel()
    // Release the raw command output once the compact in-memory index exists.
    root.filesOutput = ""
    root.aliasesOutput = ""
    if (root.filterText) root.requestSearch()
  }

  function titleForPath(path) {
    var slash = path.lastIndexOf("/")
    var name = slash >= 0 ? path.substring(slash + 1) : path
    return /\.md$/i.test(name) ? name.substring(0, name.length - 3) : name
  }

  function iconForPath(path) {
    var lower = String(path || "").toLocaleLowerCase()
    if (/\.md$/.test(lower)) return "󰍔"
    if (/\.(png|jpe?g|gif|webp|svg|avif)$/.test(lower)) return "󰋩"
    if (/\.pdf$/.test(lower)) return "󰈦"
    if (/\.(mp3|wav|flac|m4a|ogg)$/.test(lower)) return "󰎆"
    if (/\.(mp4|mkv|mov|webm)$/.test(lower)) return "󰕧"
    return "󰈔"
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    pointerGate.reset()

    if (!root.filterText) {
      // Let an in-flight fzf process finish naturally. Stopping it here can
      // deliver a late empty collector result after the next query starts.
      // The revision/query guards discard that result, while the old rows
      // and their current selection stay available until the replacement
      // search is ready.
      root.searchQueued = false
      root.selectedIndex = 0
      root.emptySearchResult = false
      root.activeResultModel = recentModel
      root.cursorActive = recentModel.count > 0
      return
    }
    // Keep the current batch—including recents on the first query—visible
    // until fzf returns its complete replacement.
    // Keep the previous model visible until fzf returns the replacement.
    // QML paints only after applySearchOutput finishes rebuilding the model,
    // so this also avoids an empty frame during the eventual swap.
    if (root.indexReady && root.fzfInput) root.requestSearch()
  }

  function requestSearch() {
    root.searchRevision += 1
    if (root.searchBusy) {
      root.searchQueued = true
      return
    }
    root.startSearch()
  }

  function startSearch() {
    if (!root.opened || !root.filterText || !root.indexReady || !root.fzfInput) return
    root.searchQueued = false
    root.searchBusy = true
    root.activeSearchQuery = root.filterText
    root.activeSearchRevision = root.searchRevision
    searchProc.revision = root.searchRevision
    searchProc.query = root.filterText
    searchProc.searchInput = root.fzfInput
    searchProc.exited = false
    searchProc.outputFinished = false
    searchProc.running = true
  }

  function finishSearchProcess() {
    if (!searchProc.exited || !searchProc.outputFinished) return
    root.searchBusy = false
    if (!root.searchQueued || !root.filterText) {
      root.searchQueued = false
      if (root.filterText && root.emptySearchResult
          && root.activeSearchRevision === root.searchRevision
          && root.activeSearchQuery === root.filterText) {
        var emptyModel = root.activeResultModel === displayModel ? stagingModel : displayModel
        emptyModel.clear()
        emptyModel.append({
          notePath: "",
          noteTitle: root.filterText,
          aliases: "",
          fileIcon: "󰐖"
        })
        root.activeResultModel = emptyModel
        root.emptySearchResult = false
        root.selectedIndex = 0
        root.cursorActive = true
        Qt.callLater(function() { resultList.positionViewAtIndex(0, ListView.Beginning) })
      }
      return
    }
    root.searchQueued = false
    Qt.callLater(function() { root.startSearch() })
  }

  function applySearchOutput(revision, query, output) {
    if (!root.opened || revision !== root.searchRevision || query !== root.filterText) return

    var nextRows = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length && nextRows.length < 50; i++) {
      if (!lines[i]) continue
      var separator = lines[i].indexOf(root.fieldSeparator)
      var indexText = separator >= 0 ? lines[i].substring(0, separator) : lines[i]
      var noteIndex = Number(indexText)
      if (!Number.isInteger(noteIndex) || noteIndex < 0 || noteIndex >= root.notes.length) continue
      var note = root.notes[noteIndex]
      nextRows.push({
        notePath: note.path,
        noteTitle: note.title,
        aliases: note.aliases.join(" · "),
        fileIcon: root.iconForPath(note.path)
      })
    }

    if (nextRows.length === 0) {
      // Keep the previous result set visible until the process has fully
      // finished. This avoids a blank/no-match frame during query handoff.
      root.emptySearchResult = true
      return
    }

    var nextModel = root.activeResultModel === displayModel ? stagingModel : displayModel
    nextModel.clear()
    for (var j = 0; j < nextRows.length; j++) nextModel.append(nextRows[j])
    // Swap only after the complete replacement batch is ready. The visible
    // model is never cleared or partially rebuilt, so ListView has no empty
    // intermediate state to paint.
    root.activeResultModel = nextModel
    pointerGate.reset()
    root.emptySearchResult = false

    root.selectedIndex = 0
    root.cursorActive = root.activeResultModel.count > 0
    Qt.callLater(function() {
      if (root.activeResultModel.count > 0) resultList.positionViewAtIndex(0, ListView.Beginning)
    })
  }

  function select(delta) {
    if (root.activeResultModel.count === 0) return
    pointerGate.reset()
    root.cursorActive = true
    root.selectedIndex = (root.selectedIndex + delta + root.activeResultModel.count) % root.activeResultModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectPage(delta) {
    if (root.activeResultModel.count === 0) return
    pointerGate.reset()
    var visibleRows = Math.max(1, Math.floor(resultList.height / root.rowHeight))
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(root.activeResultModel.count - 1, root.selectedIndex + delta * visibleRows))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.activeResultModel.count) return
    var row = root.activeResultModel.get(index)
    if (!row.notePath) {
      root.createNote()
      return
    }

    var args = ["obsidian", "open", "path=" + row.notePath]
    if (root.vault) args.push("vault=" + root.vault)
    root.dismiss()
    Quickshell.execDetached(args)
  }

  function createNote() {
    var name = root.filterText.trim()
    if (!name) return

    var args = ["obsidian", "create", "name=" + name, "open"]
    if (root.vault) args.push("vault=" + root.vault)
    root.dismiss()
    Quickshell.execDetached(args)
  }

  function htmlEscape(value) {
    return String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\"/g, "&quot;")
      .replace(/'/g, "&#39;")
  }

  function highlighted(value) {
    var source = String(value || "")
    var query = root.filterText.trim().toLocaleLowerCase()
    if (!query) return root.htmlEscape(source)

    var marked = []
    var lower = source.toLocaleLowerCase()
    var tokens = query.split(/\s+/)
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t]
      var cursor = 0
      var positions = []
      for (var i = 0; i < token.length; i++) {
        var found = lower.indexOf(token.charAt(i), cursor)
        if (found < 0) {
          positions = []
          break
        }
        positions.push(found)
        cursor = found + 1
      }
      for (var p = 0; p < positions.length; p++) marked[positions[p]] = true
    }

    var out = ""
    var bold = false
    for (var j = 0; j < source.length; j++) {
      if (marked[j] && !bold) { out += "<b>"; bold = true }
      if (!marked[j] && bold) { out += "</b>"; bold = false }
      out += root.htmlEscape(source.charAt(j))
    }
    if (bold) out += "</b>"
    return out
  }

  ListModel { id: displayModel }
  ListModel { id: stagingModel }
  ListModel { id: recentModel }

  // Ignore hover events caused by rows moving under a stationary pointer when
  // a new fzf result set replaces the old one.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: filesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishFiles(text)
    }
    stderr: StdioCollector { id: filesErrorCollector; waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.opened || root.stoppingProcesses || exitCode === 0) return
      root.errorText = String(filesErrorCollector.text || "").trim() || "Unable to load files from Obsidian"
      root.filesLoaded = true
    }
  }

  Process {
    id: aliasesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishAliases(text)
    }
    onExited: function(exitCode) {
      // File search remains useful if aliases are unavailable.
      if (root.opened && !root.stoppingProcesses && exitCode !== 0 && !root.aliasesLoaded) root.finishAliases("")
    }
  }

  Process {
    id: recentProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishRecents(text)
    }
    stderr: StdioCollector { id: recentErrorCollector; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.opened && !root.stoppingProcesses && exitCode !== 0 && !root.recentsLoaded)
        root.finishRecents("")
    }
  }

  Process {
    id: searchProc
    stdinEnabled: true
    property int revision: 0
    property string query: ""
    property string searchInput: ""
    property bool exited: false
    property bool outputFinished: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applySearchOutput(searchProc.revision, searchProc.query, text)
        searchProc.outputFinished = true
        root.finishSearchProcess()
      }
    }
    stderr: StdioCollector { id: searchErrorCollector; waitForEnd: true }
    command: ["bash", "-c", root.fzfCommand]
    onStarted: write(searchProc.query + "\n" + searchProc.searchInput + root.inputSentinel + "\n")
    onExited: function(exitCode) {
      searchProc.exited = true
      root.finishSearchProcess()
      if (root.opened && !root.stoppingProcesses
          && exitCode !== 0 && exitCode !== 1
          && searchProc.revision === root.searchRevision) {
        root.errorText = String(searchErrorCollector.text || "").trim() || "fzf search failed"
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-obsidian-quick-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Keep the overlay in a predictable upper-middle position while its
    // result list grows. The list itself is capped so the panel never grows
    // beyond half the screen height.
    readonly property int cardTop: Math.round(height * 0.25)
    readonly property int maxCardHeight: Math.round(height * 0.5)

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
      height: Math.min(root.cardHeight, panel.maxCardHeight)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.cardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectPage(1)
            event.accepted = true
          } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                     && (event.modifiers & Qt.ShiftModifier)) {
            root.createNote()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Open in Obsidian…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: root.resultHeight
          visible: root.showResults

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.activeResultModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: root.rowSpacing

            delegate: BorderSurface {
              id: row
              required property int index
              required property string notePath
              required property string noteTitle
              required property string aliases
              required property string fileIcon

              readonly property bool isCreateRow: !row.notePath
              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Text {
                id: iconText
                text: row.isCreateRow ? "󰐖" : row.fileIcon
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.left: iconText.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(12)
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: root.highlighted(row.noteTitle)
                  textFormat: Text.RichText
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: row.isCreateRow
                    ? "↵ to create"
                    : root.highlighted(row.notePath + (row.aliases ? "  ·  " + row.aliases : ""))
                  textFormat: row.isCreateRow ? Text.PlainText : Text.RichText
                  color: row.isCreateRow
                    ? (row.hasCursor ? root.selectedText : root.createActionColor)
                    : (row.hasCursor ? root.selectedText : root.foreground)
                  opacity: row.isCreateRow ? 1 : 0.62
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignLeft
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                function selectFromPointer(mouse) {
                  if (!pointerGate.moved(row, mouse)) return
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onEntered: selectFromPointer({ x: mouseArea.mouseX, y: mouseArea.mouseY })
                onPositionChanged: selectFromPointer(mouse)
                onClicked: {
                  pointerGate.allowInitialSample()
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index)
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            visible: !root.activeResultModel || root.activeResultModel.count === 0
            text: root.filterText
              ? (root.errorText || (!root.indexReady ? "Loading files and aliases…" : "No matching files"))
              : (!root.recentsLoaded ? "Loading recent notes…" : "No recent notes")
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
