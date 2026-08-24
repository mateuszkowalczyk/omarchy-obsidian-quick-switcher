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
  property bool bookmarksLoaded: false
  property bool unresolvedLoaded: false
  property bool indexBuilt: false
  property bool cursorActive: false
  property bool searchQueued: false
  property var activeSearchWorker: null
  property int sessionSerial: 0
  property bool emptySearchResult: false
  property bool recentsLoaded: false
  property string filterText: ""
  property string vault: ""
  property string filesOutput: ""
  property string aliasesOutput: ""
  property string bookmarksOutput: ""
  property string unresolvedOutput: ""
  property string recentsOutput: ""
  property string fzfInput: ""
  property string errorText: ""
  property string activeSearchQuery: ""
  property int searchRevision: 0
  property int activeSearchRevision: 0
  property int selectedIndex: 0
  property var notesByPath: ({})
  property var filePaths: []
  property var existingPathIndex: ({})
  property var searchItems: []
  property var exactSearchIndex: ({})
  property var indexWorkers: []
  property var activeResultModel: displayModel

  readonly property bool indexReady: indexBuilt
  readonly property bool recentsReady: recentsLoaded && filesLoaded
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
  property string bookmarkIcon: "󰃀"
  property string createIcon: "󰝒"
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
  readonly property int searchTimeoutMs: 8000
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
    + "--tiebreak=begin,length,index --no-multi | head -n 50"
  readonly property string obsidianIndexCommand:
    "vault_args=(); "
    + "[[ -n $1 ]] && vault_args=(\"vault=$1\"); "
    + "sleep 0.3; "
    + "for ((attempt = 0; attempt < 12; attempt++)); do "
    + "count=$(timeout 1 obsidian files total \"${vault_args[@]}\" 2>/dev/null | tr -d '[:space:]'); "
    + "if [[ $count =~ ^[0-9]+$ ]]; then "
    + "if [[ $2 == files ]]; then exec obsidian files \"${vault_args[@]}\"; "
    + "elif [[ $2 == unresolved ]]; then exec obsidian unresolved verbose format=json \"${vault_args[@]}\"; "
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
  readonly property string obsidianBookmarksCommand:
    "vault_args=(); "
    + "[[ -n $1 ]] && vault_args=(\"vault=$1\"); "
    + "sleep 0.3; "
    + "for ((attempt = 0; attempt < 12; attempt++)); do "
    + "count=$(timeout 1 obsidian bookmarks total \"${vault_args[@]}\" 2>/dev/null | tr -d '[:space:]'); "
    + "if [[ $count =~ ^[0-9]+$ ]]; then exec obsidian bookmarks verbose \"${vault_args[@]}\"; fi; "
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
    root.sessionSerial += 1
    searchTimeout.stop()
    searchTimeout.worker = null
    searchKillTimeout.stop()
    searchKillTimeout.worker = null
    root.filesLoaded = false
    root.aliasesLoaded = false
    root.unresolvedLoaded = false
    root.indexBuilt = false
    root.cursorActive = false
    root.searchQueued = false
    root.activeSearchWorker = null
    root.emptySearchResult = false
    root.filterText = ""
    root.filesOutput = ""
    root.aliasesOutput = ""
    root.bookmarksOutput = ""
    root.unresolvedOutput = ""
    root.recentsOutput = ""
    root.fzfInput = ""
    root.errorText = ""
    root.activeSearchQuery = ""
    root.searchRevision = 0
    root.activeSearchRevision = 0
    root.selectedIndex = 0
    root.notesByPath = ({})
    root.filePaths = []
    root.existingPathIndex = ({})
    root.searchItems = []
    root.exactSearchIndex = ({})
    root.indexWorkers = []
    root.bookmarksLoaded = false
    root.recentsLoaded = false
    root.activeResultModel = recentModel
    displayModel.clear()
    stagingModel.clear()
    recentModel.clear()
    pointerGate.reset()
  }

  function stopProcesses() {
    searchTimeout.stop()
    searchTimeout.worker = null
    searchKillTimeout.stop()
    searchKillTimeout.worker = null
    var indexWorkerList = root.indexWorkers
    root.indexWorkers = []
    for (var i = 0; i < indexWorkerList.length; i++) {
      var indexWorker = indexWorkerList[i]
      if (!indexWorker) continue
      indexWorker.cancelled = true
      indexWorker.completed = true
      if (indexWorker.running) indexWorker.running = false
      Qt.callLater((function(workerToDestroy) {
        return function() { workerToDestroy.destroy() }
      })(indexWorker))
    }
    var worker = root.activeSearchWorker
    root.activeSearchWorker = null
    if (worker) {
      worker.cancelled = true
      worker.completed = true
      if (worker.running) worker.running = false
      Qt.callLater(function() { worker.destroy() })
    }
  }

  function startIndexLoad() {
    root.filesLoaded = false
    root.aliasesLoaded = false
    root.bookmarksLoaded = false
    root.unresolvedLoaded = false
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
    root.startIndexWorker("files", ["bash", "-c", root.obsidianIndexCommand, "obsidian-quick-switcher", root.vault, "files"])
    root.startIndexWorker("aliases", ["bash", "-c", root.obsidianIndexCommand, "obsidian-quick-switcher", root.vault, "aliases"])
    root.startIndexWorker("unresolved", ["bash", "-c", root.obsidianIndexCommand, "obsidian-quick-switcher", root.vault, "unresolved"])
    root.startIndexWorker("recents", ["bash", "-c", root.obsidianRecentsCommand, "obsidian-quick-switcher", root.vault])
    root.startIndexWorker("bookmarks", ["bash", "-c", root.obsidianBookmarksCommand, "obsidian-quick-switcher", root.vault])
  }

  function startIndexWorker(kind, command) {
    var worker = indexWorkerComponent.createObject(root, {
      kind: kind,
      sessionSerial: root.sessionSerial,
      command: command
    })
    if (!worker) {
      root.finishIndexKind(kind, "", "Unable to start Obsidian CLI")
      return
    }
    var nextWorkers = root.indexWorkers.slice()
    nextWorkers.push(worker)
    root.indexWorkers = nextWorkers
    worker.running = true
  }

  function maybeFinishIndexWorker(worker) {
    if (!worker || worker.completed || !worker.exitFinished || !worker.stdoutFinished) return
    worker.completed = true

    var nextWorkers = []
    for (var i = 0; i < root.indexWorkers.length; i++) {
      if (root.indexWorkers[i] !== worker) nextWorkers.push(root.indexWorkers[i])
    }
    root.indexWorkers = nextWorkers

    if (root.opened && !worker.cancelled && worker.sessionSerial === root.sessionSerial) {
      var output = worker.exitCode === 0 ? worker.output : ""
      var error = worker.exitCode === 0 ? "" : (worker.errorOutput || "Obsidian CLI command failed")
      root.finishIndexKind(worker.kind, output, error)
    }
    Qt.callLater(function() { worker.destroy() })
  }

  function finishIndexKind(kind, output, error) {
    if (kind === "files") {
      if (error) root.errorText = error
      root.finishFiles(output)
    } else if (kind === "aliases") {
      root.finishAliases(output)
    } else if (kind === "bookmarks") {
      root.finishBookmarks(output)
    } else if (kind === "unresolved") {
      root.finishUnresolved(output)
    } else if (kind === "recents") {
      root.finishRecents(output)
    }
  }

  function cleanField(value) {
    return String(value || "")
      .replace(/\x00/g, "")
      .replace(/[\r\n]/g, " ")
      .replace(/\x1f/g, " ")
      .replace(/\x1e/g, " ")
  }

  function pathIndexKey(path) {
    return "$" + root.cleanField(path).trim()
  }

  function finishFiles(output) {
    if (!root.opened || root.filesLoaded) return
    root.filesOutput = String(output || "")

    var paths = []
    var pathIndex = ({})
    var lines = root.filesOutput.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var path = root.cleanField(lines[i].trim())
      var key = root.pathIndexKey(path)
      if (!path || pathIndex[key]) continue
      pathIndex[key] = true
      paths.push(path)
    }
    root.filePaths = paths
    root.existingPathIndex = pathIndex
    root.filesLoaded = true
    if (root.recentsLoaded) root.buildRecentModel()
    root.maybeBuildIndex()
  }

  function finishAliases(output) {
    if (!root.opened || root.aliasesLoaded) return
    root.aliasesOutput = String(output || "")
    root.aliasesLoaded = true
    root.maybeBuildIndex()
  }

  function finishBookmarks(output) {
    if (!root.opened || root.bookmarksLoaded) return
    root.bookmarksOutput = String(output || "")
    root.bookmarksLoaded = true
    root.maybeBuildIndex()
  }

  function finishUnresolved(output) {
    if (!root.opened || root.unresolvedLoaded) return
    root.unresolvedOutput = String(output || "")
    root.unresolvedLoaded = true
    root.maybeBuildIndex()
  }

  function finishRecents(output) {
    if (!root.opened || root.recentsLoaded) return
    root.recentsOutput = String(output || "")
    root.recentsLoaded = true
    root.buildRecentModel()
  }

  function buildRecentModel() {
    if (!root.recentsReady) return

    var rows = []
    var seen = ({})
    var recentLines = root.recentsOutput.split("\n")
    for (var i = 0; i < recentLines.length; i++) {
      var path = root.cleanField(recentLines[i].trim())
      var pathKey = root.pathIndexKey(path)
      if (!path || !root.existingPathIndex[pathKey] || seen[pathKey]) continue
      seen[pathKey] = true

      var title = root.titleForPath(path)
      var aliases = ""
      var note = root.notesByPath[pathKey]
      if (note) {
        title = note.title
        aliases = note.aliases.join(" · ")
      }
      rows.push({
        notePath: path,
        noteTitle: title,
        aliases: aliases,
        bookmarkName: "",
        isBookmark: false,
        createName: "",
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

  function appendSearchItem(items, rows, item) {
    var itemIndex = items.length
    items.push(item)
    rows.push([
      String(itemIndex),
      root.cleanField(item.title),
      root.cleanField(item.path),
      root.cleanField(item.searchText)
    ].join(root.fieldSeparator))
  }

  function exactSearchKey(value) {
    return "$" + root.cleanField(value).trim().toLocaleLowerCase()
  }

  function addExactSearchEntry(index, value, itemIndex) {
    var cleaned = root.cleanField(value).trim()
    if (!cleaned) return
    var key = root.exactSearchKey(cleaned)
    if (!index[key]) index[key] = []
    if (index[key].indexOf(itemIndex) < 0) index[key].push(itemIndex)
  }

  function buildExactSearchIndex(items) {
    var index = ({})
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      root.addExactSearchEntry(index, item.title, i)
      root.addExactSearchEntry(index, item.bookmarkName, i)
      root.addExactSearchEntry(index, item.createName, i)
      root.addExactSearchEntry(index, item.path, i)
      root.addExactSearchEntry(index, root.cleanField(item.path).trim().replace(/\.[^/.]+$/, ""), i)

      var aliases = String(item.aliases || "").split(" · ")
      for (var j = 0; j < aliases.length; j++)
        root.addExactSearchEntry(index, aliases[j], i)
    }
    return index
  }

  function exactSearchMatches(query) {
    var matches = root.exactSearchIndex[root.exactSearchKey(query)]
    return matches ? matches.slice() : []
  }

  function createableUnresolvedName(value) {
    var name = root.cleanField(value).trim()
    if (!name || /^<%[\s\S]*%>$/.test(name)) return ""
    if (/(?:https?|ftp|mailto|file):\/\//i.test(name) || name.indexOf("://") >= 0) return ""

    // A link may include an alias or a heading/block subpath. The switcher
    // creates the note target, not the display alias or subpath.
    var pipe = name.indexOf("|")
    if (pipe > 0) name = name.substring(0, pipe).trim()
    var hash = name.indexOf("#")
    if (hash === 0) return ""
    if (hash > 0) name = name.substring(0, hash).trim()
    var caret = name.indexOf("^")
    if (caret === 0) return ""
    if (caret > 0) name = name.substring(0, caret).trim()
    return name
  }

  function maybeBuildIndex() {
    if (root.indexBuilt || !root.filesLoaded || !root.aliasesLoaded
        || !root.bookmarksLoaded || !root.unresolvedLoaded) return

    var byPath = ({})
    var order = []
    for (var i = 0; i < root.filePaths.length; i++) {
      var path = root.filePaths[i]
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

    var bookmarksByPath = ({})
    var bookmarkLines = root.bookmarksOutput.split("\n")
    for (var b = 0; b < bookmarkLines.length; b++) {
      var bookmarkLine = bookmarkLines[b]
      var firstTab = bookmarkLine.indexOf("\t")
      var secondTab = firstTab >= 0 ? bookmarkLine.indexOf("\t", firstTab + 1) : -1
      if (firstTab < 1 || secondTab <= firstTab + 1) continue
      var bookmarkType = bookmarkLine.substring(0, firstTab).trim()
      if (bookmarkType !== "file") continue
      var bookmarkPath = root.cleanField(bookmarkLine.substring(firstTab + 1, secondTab).trim())
      var bookmarkName = root.cleanField(bookmarkLine.substring(secondTab + 1).trim())
      if (!bookmarkPath) continue
      if (!bookmarkName) bookmarkName = root.titleForPath(bookmarkPath)
      if (!bookmarksByPath[bookmarkPath]) bookmarksByPath[bookmarkPath] = []
      bookmarksByPath[bookmarkPath].push({ path: bookmarkPath, name: bookmarkName })
    }

    var unresolvedItems = []
    try {
      var parsedUnresolved = JSON.parse(root.unresolvedOutput || "[]")
      if (Array.isArray(parsedUnresolved)) unresolvedItems = parsedUnresolved
    } catch (e) {
      unresolvedItems = []
    }

    var notesByPath = ({})
    var searchItems = []
    var rows = []
    for (var k = 0; k < order.length; k++) {
      var note = byPath[order[k]]
      notesByPath[root.pathIndexKey(note.path)] = note

      root.appendSearchItem(searchItems, rows, {
        path: note.path,
        title: note.title,
        aliases: note.aliases.join(" · "),
        bookmarkName: "",
        isBookmark: false,
        createName: "",
        fileIcon: root.iconForPath(note.path),
        searchText: note.aliases.join(" ")
      })

      var noteBookmarks = bookmarksByPath[note.path] || []
      for (var m = 0; m < noteBookmarks.length; m++) {
        root.appendSearchItem(searchItems, rows, {
          path: noteBookmarks[m].path,
          title: noteBookmarks[m].name,
          aliases: "",
          bookmarkName: noteBookmarks[m].name,
          isBookmark: true,
          createName: "",
          fileIcon: root.bookmarkIcon,
          searchText: noteBookmarks[m].name
        })
      }
    }

    // Keep bookmarks to paths that are not present in `obsidian files`
    // searchable as well, while retaining every bookmark as a separate row.
    for (var bookmarkPath in bookmarksByPath) {
      if (byPath[bookmarkPath]) continue
      var orphanBookmarks = bookmarksByPath[bookmarkPath]
      for (var n = 0; n < orphanBookmarks.length; n++) {
        root.appendSearchItem(searchItems, rows, {
          path: orphanBookmarks[n].path,
          title: orphanBookmarks[n].name,
          aliases: "",
          bookmarkName: orphanBookmarks[n].name,
          isBookmark: true,
          createName: "",
          fileIcon: root.bookmarkIcon,
          searchText: orphanBookmarks[n].name
        })
      }
    }

    var unresolvedSeen = ({})
    for (var u = 0; u < unresolvedItems.length; u++) {
      var unresolvedName = root.createableUnresolvedName(unresolvedItems[u].link)
      if (!unresolvedName || unresolvedSeen[unresolvedName]) continue
      unresolvedSeen[unresolvedName] = true
      root.appendSearchItem(searchItems, rows, {
        path: "",
        title: unresolvedName,
        aliases: "",
        bookmarkName: "",
        isBookmark: false,
        createName: unresolvedName,
        fileIcon: root.createIcon,
        searchText: unresolvedName
      })
    }

    root.notesByPath = notesByPath
    root.searchItems = searchItems
    root.exactSearchIndex = root.buildExactSearchIndex(searchItems)
    root.fzfInput = rows.join("\n") + (rows.length ? "\n" : "")
    root.indexBuilt = true
    if (root.recentsLoaded) root.buildRecentModel()
    // Release the raw command output once the compact in-memory index exists.
    root.filesOutput = ""
    root.aliasesOutput = ""
    root.bookmarksOutput = ""
    root.unresolvedOutput = ""
    if (root.filterText) root.requestSearch()
  }

  function titleForPath(path) {
    var slash = path.lastIndexOf("/")
    var name = slash >= 0 ? path.substring(slash + 1) : path
    return /\.md$/i.test(name) ? name.substring(0, name.length - 3) : name
  }

  function iconForPath(path) {
    var lower = String(path || "").toLocaleLowerCase()
    if (/\.md$/.test(lower)) return ""
    if (/\.html?$/.test(lower)) return "󰌝"
    if (/\.css$/.test(lower)) return "󰌜"
    if (/\.(js|mjs|cjs|ts|tsx)$/.test(lower)) return "󰌞"
    if (/\.py$/.test(lower)) return "󰌠"
    if (/\.(png|jpe?g|gif|webp|svg|avif)$/.test(lower)) return "󰋩"
    if (/\.pdf$/.test(lower)) return "󰈦"
    if (/\.(mp3|wav|flac|m4a|ogg)$/.test(lower)) return "󰎆"
    if (/\.(mp4|mkv|mov|webm)$/.test(lower)) return "󰕧"
    return "󰈙"
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    pointerGate.reset()

    if (!root.filterText) {
      // Each run owns its output and metadata, so an in-flight query can
      // finish safely. Its revision guard discards it while recents become
      // visible immediately.
      root.searchQueued = false
      root.selectedIndex = 0
      root.emptySearchResult = false
      root.activeResultModel = recentModel
      root.cursorActive = recentModel.count > 0
      return
    }
    // Keep the current batch—including recents on the first query—visible
    // until fzf returns its complete replacement.
    if (root.indexReady) root.requestSearch()
  }

  function requestSearch() {
    root.searchRevision += 1
    root.searchQueued = true
    root.startSearch()
  }

  function startSearch() {
    if (root.activeSearchWorker) return
    if (!root.opened || !root.filterText || !root.indexReady) {
      if (!root.filterText) root.searchQueued = false
      return
    }

    if (!root.fzfInput) {
      root.searchQueued = false
      root.activeSearchQuery = root.filterText
      root.activeSearchRevision = root.searchRevision
      root.emptySearchResult = true
      root.finishSearchProcess()
      return
    }

    root.searchQueued = false
    root.activeSearchQuery = root.filterText
    root.activeSearchRevision = root.searchRevision

    var worker = searchWorkerComponent.createObject(root, {
      revision: root.searchRevision,
      query: root.filterText,
      searchInput: root.fzfInput,
      exactIndexes: root.exactSearchMatches(root.filterText),
      sessionSerial: root.sessionSerial
    })
    if (!worker) {
      root.searchQueued = false
      root.errorText = "Unable to start fzf search"
      return
    }

    root.activeSearchWorker = worker
    searchTimeout.worker = worker
    searchTimeout.restart()
    worker.running = true
  }

  function finishSearchProcess() {
    if (root.searchQueued && root.filterText) {
      Qt.callLater(function() { root.startSearch() })
      return
    }

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
        bookmarkName: "",
        isBookmark: false,
        createName: root.filterText,
        fileIcon: root.createIcon
      })
      root.activeResultModel = emptyModel
      root.emptySearchResult = false
      root.selectedIndex = 0
      root.cursorActive = true
      Qt.callLater(function() { resultList.positionViewAtIndex(0, ListView.Beginning) })
    }
  }

  function maybeFinishSearchWorker(worker) {
    if (!worker || worker.completed || !worker.exitFinished || !worker.stdoutFinished) return
    root.completeSearchWorker(worker)
  }

  function completeSearchWorker(worker) {
    if (!worker || worker.completed) return
    worker.completed = true

    if (searchTimeout.worker === worker) {
      searchTimeout.stop()
      searchTimeout.worker = null
    }
    if (searchKillTimeout.worker === worker) {
      searchKillTimeout.stop()
      searchKillTimeout.worker = null
    }

    var isCurrent = root.activeSearchWorker === worker
    if (isCurrent) root.activeSearchWorker = null

    try {
      if (isCurrent && root.opened && !worker.cancelled
          && worker.sessionSerial === root.sessionSerial) {
        if (worker.timedOut) {
          root.searchQueued = !!root.filterText
        } else {
          root.applySearchOutput(worker.revision, worker.query, worker.exactIndexes, worker.collected)
          if (worker.exitCode === 0 || worker.exitCode === 1) root.errorText = ""
          if (worker.exitCode !== 0 && worker.exitCode !== 1
              && worker.revision === root.searchRevision) {
            root.errorText = worker.errorOutput || "fzf search failed"
          }
        }
      }
    } catch (error) {
      if (isCurrent && root.opened) {
        root.errorText = "Unable to process fzf results"
        root.searchQueued = false
      }
      console.warn("Obsidian quick switcher search completion failed:", error)
    } finally {
      if (isCurrent) root.finishSearchProcess()
      Qt.callLater(function() { worker.destroy() })
    }
  }

  function abandonSearchWorker(worker) {
    if (!worker || root.activeSearchWorker !== worker) return
    if (searchTimeout.worker === worker) {
      searchTimeout.stop()
      searchTimeout.worker = null
    }
    if (searchKillTimeout.worker === worker) {
      searchKillTimeout.stop()
      searchKillTimeout.worker = null
    }

    root.activeSearchWorker = null
    worker.cancelled = true
    worker.completed = true
    if (worker.running) worker.signal(9)
    Qt.callLater(function() { worker.destroy() })

    root.searchQueued = !!root.filterText
    if (root.searchQueued) Qt.callLater(function() { root.startSearch() })
  }

  function applySearchOutput(revision, query, exactIndexes, output) {
    if (!root.opened || revision !== root.searchRevision || query !== root.filterText) return

    var nextRows = []
    var seen = ({})

    function appendItem(itemIndex) {
      if (!Number.isInteger(itemIndex) || itemIndex < 0
          || itemIndex >= root.searchItems.length || seen[itemIndex]) return
      seen[itemIndex] = true
      var item = root.searchItems[itemIndex]
      nextRows.push({
        notePath: item.path,
        noteTitle: item.title,
        aliases: item.aliases,
        bookmarkName: item.bookmarkName,
        isBookmark: item.isBookmark,
        createName: item.createName,
        fileIcon: item.fileIcon
      })
    }

    var exact = exactIndexes || []
    for (var exactIndex = 0; exactIndex < exact.length; exactIndex++)
      appendItem(Number(exact[exactIndex]))

    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length && nextRows.length < 50; i++) {
      if (!lines[i]) continue
      var separator = lines[i].indexOf(root.fieldSeparator)
      var indexText = separator >= 0 ? lines[i].substring(0, separator) : lines[i]
      appendItem(Number(indexText))
    }

    if (nextRows.length > 50) nextRows = nextRows.slice(0, 50)

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
      root.createNote(row.createName || root.filterText)
      return
    }

    var args = ["obsidian", "open", "path=" + row.notePath]
    if (root.vault) args.push("vault=" + root.vault)
    root.dismiss()
    Quickshell.execDetached(args)
  }

  function createNote(requestedName) {
    var name = String(requestedName || root.filterText).trim()
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
      var complete = true
      for (var i = 0; i < token.length; i++) {
        var found = lower.indexOf(token.charAt(i), cursor)
        if (found < 0) {
          complete = false
          break
        }
        positions.push(found)
        cursor = found + 1
      }

      if (!complete) {
        // fzf may match the query in another field (for example a path or
        // alias), while this visible field contains the same letters in a
        // different order. Mark the available characters instead of
        // dropping the whole highlight for this field.
        positions = []
        var used = []
        for (var fallbackIndex = 0; fallbackIndex < token.length; fallbackIndex++) {
          var fallbackFound = lower.indexOf(token.charAt(fallbackIndex))
          while (fallbackFound >= 0 && used.indexOf(fallbackFound) >= 0)
            fallbackFound = lower.indexOf(token.charAt(fallbackIndex), fallbackFound + 1)
          if (fallbackFound < 0) continue
          used.push(fallbackFound)
          positions.push(fallbackFound)
        }
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

  Component {
    id: indexWorkerComponent

    Process {
      id: indexWorker
      required property string kind
      required property int sessionSerial
      property string output: ""
      property string errorOutput: ""
      property int exitCode: -1
      property bool exitFinished: false
      property bool stdoutFinished: false
      property bool cancelled: false
      property bool completed: false

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          indexWorker.output = text
          indexWorker.stdoutFinished = true
          root.maybeFinishIndexWorker(indexWorker)
        }
      }
      stderr: StdioCollector {
        waitForEnd: true
        onStreamFinished: indexWorker.errorOutput = String(text || "").trim()
      }
      onExited: function(code) {
        indexWorker.exitCode = code
        indexWorker.exitFinished = true
        root.maybeFinishIndexWorker(indexWorker)
      }
    }
  }

  Component {
    id: searchWorkerComponent

    Process {
      id: worker
      required property int revision
      required property string query
      required property string searchInput
      required property var exactIndexes
      required property int sessionSerial
      property string collected: ""
      property string errorOutput: ""
      property int exitCode: -1
      property bool exitFinished: false
      property bool stdoutFinished: false
      property bool timedOut: false
      property bool cancelled: false
      property bool completed: false
      property bool forceKilled: false

      stdinEnabled: true
      command: ["bash", "-c", root.fzfCommand]

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          worker.collected = text
          worker.stdoutFinished = true
          root.maybeFinishSearchWorker(worker)
        }
      }
      stderr: StdioCollector {
        waitForEnd: true
        onStreamFinished: worker.errorOutput = String(text || "").trim()
      }

      onStarted: {
        if (worker.cancelled) {
          worker.running = false
          return
        }
        worker.write(worker.query + "\n" + worker.searchInput + root.inputSentinel + "\n")
      }
      onExited: function(code) {
        worker.exitCode = code
        worker.exitFinished = true
        root.maybeFinishSearchWorker(worker)
      }
    }
  }

  Timer {
    id: searchTimeout
    property var worker: null
    interval: root.searchTimeoutMs
    repeat: false
    onTriggered: {
      var candidate = searchTimeout.worker
      searchTimeout.worker = null
      if (!candidate || root.activeSearchWorker !== candidate) return

      candidate.timedOut = true
      root.searchQueued = !!root.filterText
      if (candidate.running) {
        candidate.running = false
        searchKillTimeout.worker = candidate
        searchKillTimeout.restart()
        return
      }
      root.abandonSearchWorker(candidate)
    }
  }

  Timer {
    id: searchKillTimeout
    property var worker: null
    interval: 500
    repeat: false
    onTriggered: {
      var candidate = searchKillTimeout.worker
      if (!candidate || root.activeSearchWorker !== candidate) {
        searchKillTimeout.worker = null
        return
      }

      if (candidate.running && !candidate.forceKilled) {
        candidate.forceKilled = true
        candidate.signal(9)
        searchKillTimeout.restart()
        return
      }
      root.abandonSearchWorker(candidate)
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
          } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_P) {
            root.select(-1)
            event.accepted = true
          } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
            root.select(1)
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
              required property string bookmarkName
              required property bool isBookmark
              required property string createName
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
                text: row.isCreateRow ? root.createIcon : (row.isBookmark ? root.bookmarkIcon : row.fileIcon)
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.left: parent.left
                anchors.right: iconText.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.rightMargin: Style.spacing.sm
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
                    : root.highlighted(row.isBookmark
                      ? row.bookmarkName
                      : row.notePath + (row.aliases ? "  ·  " + row.aliases : ""))
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
              ? (root.errorText || (!root.indexReady ? "Loading files, aliases, bookmarks, and links…" : "No matching files"))
              : (!root.recentsReady ? "Loading recent notes…" : "No recent notes")
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
