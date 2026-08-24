import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "IndexBuilder.js" as IndexBuilder

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool indexBuilt: false
  property bool indexFailed: false
  property bool refreshing: false
  property bool cursorActive: false
  property var activeSearchWorker: null
  property int sessionSerial: 0
  property bool emptySearchResult: false
  property string cliStatus: "unknown"
  property string filterText: ""
  property var indexOutputs: ({})
  property string fzfInput: ""
  property string errorText: ""
  property string activeSearchQuery: ""
  property int searchRevision: 0
  property int activeSearchRevision: 0
  property int selectedIndex: 0
  property var searchItems: []
  property var exactSearchIndex: ({})
  property var indexWorkers: []
  property var indexQueue: []
  property int indexSerial: 0
  property var indexBuildJob: null
  property var activeResultModel: displayModel

  readonly property bool indexReady: indexBuilt
  readonly property bool recentsReady: indexBuilt
  readonly property bool cliDisabled: cliStatus === "disabled"
  readonly property string cliDisabledMessage:
    "Obsidian CLI is not enabled. Enable it in Settings → General → Advanced."
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
  property real fontScale: 1.15
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(42), Math.round(Style.font.title * root.fontScale) + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(58), Math.round(Style.font.body * root.fontScale) + Math.round(Style.font.caption * root.fontScale) + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  property int rowPeek: Math.round(rowHeight * 0.55)
  readonly property int searchTimeoutMs: 3000
  readonly property int indexCommandTimeoutSeconds: 10
  readonly property int maxIndexAttempts: 2
  readonly property int maxConcurrentIndexWorkers: 2
  readonly property int indexBuildChunkMs: 4
  readonly property int maxFiles: 50000
  readonly property int maxAliases: 100000
  readonly property int maxAliasesPerFile: 64
  readonly property int maxBookmarks: 10000
  readonly property int maxUnresolved: 50000
  readonly property int maxRecents: 1000
  readonly property int maxSearchItems: 110000
  readonly property int maxPathBytes: 4096
  readonly property int maxLabelBytes: 1024
  readonly property int maxFzfInputBytes: 32 * 1024 * 1024
  readonly property int maxFzfOutputBytes: 8 * 1024 * 1024
  readonly property int maxFilesOutputBytes: 8 * 1024 * 1024
  readonly property int maxAliasesOutputBytes: 16 * 1024 * 1024
  readonly property int maxBookmarksOutputBytes: 4 * 1024 * 1024
  readonly property int maxUnresolvedOutputBytes: 16 * 1024 * 1024
  readonly property int maxRecentsOutputBytes: 1024 * 1024
  readonly property int maxStderrBytes: 64 * 1024
  readonly property string boundedCommandPath:
    decodeURIComponent(Qt.resolvedUrl("bounded-command").toString().replace(/^file:\/\//, ""))
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
  readonly property string fzfCommand:
    "fzf --filter=\"$1\" --delimiter=$'\\037' --nth=2.. "
    + "--tiebreak=begin,length,index --no-multi | head -n 50"
  readonly property string obsidianReadyProbe:
    "if ! command -v obsidian >/dev/null 2>&1; then "
    + "echo 'Obsidian CLI is not available' >&2; exit 127; fi; "
    + "probe_output=$(timeout 1 obsidian files total 2>&1 | head -c 4097); "
    + "count=$(printf '%s' \"$probe_output\" | tr -d '[:space:]'); "
    + "if printf '%s' \"$probe_output\" | grep -qi 'command line interface is not enabled'; then "
    + "echo 'Obsidian CLI is not enabled' >&2; exit 2; fi; "
  readonly property string obsidianReadinessCommand:
    "sleep 0.3; "
    + "for ((attempt = 0; attempt < 12; attempt++)); do "
    + root.obsidianReadyProbe
    + "if [[ $count =~ ^[0-9]+$ ]]; then exit 0; fi; "
    + "sleep 0.25; "
    + "done; "
    + "echo 'Obsidian CLI did not become ready within 15 seconds' >&2; exit 1"

  function open() {
    root.clearSession()
    root.opened = true
    root.startIndexLoad()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.clearSession()
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mateuszkowalczyk.obsidian-quick-switcher")
    else
      root.close()
  }

  function clearSession() {
    root.sessionSerial += 1
    var worker = root.activeSearchWorker
    root.activeSearchWorker = null
    searchTimeout.stop()
    searchTimeout.worker = null
    searchKillTimeout.stop()
    searchKillTimeout.worker = null
    root.cursorActive = false
    root.emptySearchResult = false
    root.filterText = ""
    root.errorText = ""
    root.activeSearchQuery = ""
    root.searchRevision = 0
    root.activeSearchRevision = 0
    root.selectedIndex = 0
    root.activeResultModel = recentModel
    displayModel.clear()
    stagingModel.clear()
    root.cursorActive = recentModel.count > 0
    pointerGate.reset()
    if (worker) {
      worker.cancelled = true
      worker.completed = true
      if (worker.running) worker.running = false
      Qt.callLater(function() { worker.destroy() })
    }
  }

  function startIndexLoad() {
    if (root.refreshing) return
    root.refreshing = true
    root.indexFailed = false
    root.cliStatus = "unknown"
    root.indexSerial += 1
    root.indexOutputs = ({})
    root.indexBuildJob = null
    // A first CLI call can turn into the long-running Electron app when
    // Obsidian is closed. Launch that app detached first, then let the owned
    // scan processes poll its command server. The bracketed pgrep pattern
    // avoids matching this shell command itself.
    Quickshell.execDetached([
      "bash", "-c",
      "pgrep -f '[o]bsidian/app.asar' >/dev/null || exec obsidian"
    ])

    // Probe readiness once, then use limited concurrency. Five simultaneous
    // requests proved unreliable, while two preserve most of the speedup.
    // Files and recents go first so the initial list appears quickly.
    root.indexQueue = [
      { kind: "files", outputLimit: root.maxFilesOutputBytes,
        command: root.obsidianCommand(["files"]) },
      { kind: "recents", outputLimit: root.maxRecentsOutputBytes,
        command: root.obsidianCommand(["recents"]) },
      { kind: "aliases", outputLimit: root.maxAliasesOutputBytes,
        command: root.obsidianCommand(["aliases", "verbose"]) },
      { kind: "bookmarks", outputLimit: root.maxBookmarksOutputBytes,
        command: root.obsidianCommand(["bookmarks", "verbose"]) },
      { kind: "unresolved", outputLimit: root.maxUnresolvedOutputBytes,
        command: root.obsidianCommand(["unresolved", "verbose", "format=json"]) }
    ]
    root.startIndexWorker("readiness", 4096,
      ["bash", "-c", root.obsidianReadinessCommand], 1)
  }

  function obsidianCommand(args) {
    return ["timeout", "--signal=TERM", "--kill-after=1s",
      root.indexCommandTimeoutSeconds + "s", "obsidian"].concat(args)
  }

  function startNextIndexWorker() {
    if (!root.refreshing || root.indexFailed || root.cliDisabled) return
    while (root.refreshing && !root.indexFailed && !root.cliDisabled
        && root.indexWorkers.length < root.maxConcurrentIndexWorkers
        && root.indexQueue.length > 0) {
      var queue = root.indexQueue.slice()
      var next = queue.shift()
      root.indexQueue = queue
      root.startIndexWorker(next.kind, next.outputLimit, next.command, next.attempt || 1)
    }
  }

  function startIndexWorker(kind, outputLimit, command, attempt) {
    var worker = indexWorkerComponent.createObject(root, {
      kind: kind,
      sessionSerial: root.indexSerial,
      outputLimit: outputLimit,
      originalCommand: command,
      attempt: attempt,
      command: [root.boundedCommandPath, String(outputLimit), String(root.maxStderrBytes), kind].concat(command)
    })
    if (!worker) {
      root.failIndex("Unable to start Obsidian CLI " + kind + " worker")
      return
    }
    var nextWorkers = root.indexWorkers.slice()
    nextWorkers.push(worker)
    root.indexWorkers = nextWorkers
    worker.launchRequested = true
    worker.running = true
  }

  function maybeFinishIndexWorker(worker) {
    if (!worker || worker.completed || !worker.exitFinished || !worker.stdoutFinished) return
    worker.completed = true

    var kind = worker.kind
    var session = worker.sessionSerial
    var outputLimit = worker.outputLimit
    var originalCommand = worker.originalCommand
    var attempt = worker.attempt
    var exitCode = worker.exitCode
    var output = worker.output
    var errorOutput = worker.errorOutput
    var current = root.refreshing && !worker.cancelled && session === root.indexSerial

    var nextWorkers = []
    for (var i = 0; i < root.indexWorkers.length; i++) {
      if (root.indexWorkers[i] !== worker) nextWorkers.push(root.indexWorkers[i])
    }
    root.indexWorkers = nextWorkers

    Qt.callLater(function() { worker.destroy() })
    if (!current) return

    if (exitCode === 124) {
      if (attempt < root.maxIndexAttempts) {
        if (kind === "readiness") {
          Qt.callLater(function() {
            if (root.refreshing && session === root.indexSerial && !root.indexFailed)
              root.startIndexWorker(kind, outputLimit, originalCommand, attempt + 1)
          })
          return
        }
        var retryQueue = root.indexQueue.slice()
        retryQueue.unshift({ kind: kind, outputLimit: outputLimit,
          command: originalCommand, attempt: attempt + 1 })
        root.indexQueue = retryQueue
        root.startNextIndexWorker()
      } else {
        root.failIndex("Obsidian " + kind + " command timed out after "
          + root.maxIndexAttempts + " attempts")
      }
      return
    }

    var successfulOutput = exitCode === 0 ? output : ""
    var error = exitCode === 0 ? "" : (errorOutput || "Obsidian CLI command failed")
    if (exitCode === 2) error = "Obsidian CLI is not enabled"
    if (exitCode === 127) error = "Obsidian CLI is not available"
    if (exitCode === 74) {
      root.failIndex(error)
      return
    }
    if (kind === "readiness") {
      if (exitCode !== 0) {
        if (!root.indexBuilt && (exitCode === 2 || exitCode === 127))
          root.finishIndexKind(kind, "", error)
        root.failIndex(error)
        return
      }
      root.finishIndexKind(kind, "", "")
      root.startNextIndexWorker()
      return
    }
    if (exitCode !== 0) {
      root.failIndex(error)
      return
    }
    root.finishIndexKind(kind, successfulOutput, error)
    Qt.callLater(function() {
      if (root.refreshing && session === root.indexSerial && !root.indexFailed)
        root.startNextIndexWorker()
    })
  }

  function abandonIndexWorker(worker) {
    if (!worker || worker.completed) return
    worker.completed = true
    var session = worker.sessionSerial
    var kind = worker.kind
    var cancelled = worker.cancelled
    var nextWorkers = []
    for (var i = 0; i < root.indexWorkers.length; i++) {
      if (root.indexWorkers[i] !== worker) nextWorkers.push(root.indexWorkers[i])
    }
    root.indexWorkers = nextWorkers
    Qt.callLater(function() { worker.destroy() })
    if (root.refreshing && !cancelled && session === root.indexSerial)
      root.failIndex("Unable to start Obsidian CLI " + kind + " worker")
  }

  function finishIndexKind(kind, output, error) {
    if (error && /command line interface is not enabled|obsidian cli is not available|command not found/i.test(String(error))) {
      root.cliStatus = "disabled"
      root.errorText = ""
    } else if (!error && root.cliStatus === "unknown") {
      root.cliStatus = "available"
    }

    if (!root.refreshing || ["files", "aliases", "bookmarks", "unresolved", "recents"].indexOf(kind) < 0)
      return
    if (kind in root.indexOutputs) return
    root.indexOutputs[kind] = String(output || "")
    root.maybeBuildIndex()
  }

  function cleanField(value) {
    return String(value || "")
      .replace(/\x00/g, "")
      .replace(/[\r\n]/g, " ")
      .replace(/\x1f/g, " ")
      .replace(/\x1e/g, " ")
  }

  function utf8Bytes(value) {
    try {
      return encodeURIComponent(String(value || ""))
        .replace(/%[0-9A-Fa-f]{2}/g, "x").length
    } catch (e) {
      return Number.MAX_SAFE_INTEGER
    }
  }

  function stopIndexProcesses() {
    root.indexSerial += 1
    root.refreshing = false
    root.indexQueue = []
    indexBuildTimer.stop()
    root.indexBuildJob = null
    var workers = root.indexWorkers
    root.indexWorkers = []
    for (var i = 0; i < workers.length; i++) {
      var worker = workers[i]
      if (!worker) continue
      worker.cancelled = true
      worker.completed = true
      if (worker.running) worker.running = false
      Qt.callLater((function(workerToDestroy) {
        return function() { workerToDestroy.destroy() }
      })(worker))
    }
  }

  function failIndex(message) {
    if (root.indexFailed) return false
    root.stopIndexProcesses()
    root.indexOutputs = ({})
    if (root.indexBuilt) return false

    root.indexFailed = true
    root.errorText = String(message || "Vault index exceeds a supported resource limit")
    root.searchItems = []
    root.exactSearchIndex = ({})
    root.fzfInput = ""
    root.cursorActive = false
    displayModel.clear()
    stagingModel.clear()
    recentModel.clear()
    return false
  }

  function checkField(value, byteLimit, label) {
    if (root.utf8Bytes(value) <= byteLimit) return true
    return root.failIndex("Vault index exceeds the supported " + label + " size limit")
  }

  function pathIndexKey(path) {
    return "$" + root.cleanField(path).trim()
  }

  function appendSearchItem(items, rows, item, budget) {
    if (items.length >= root.maxSearchItems)
      return root.failIndex("Vault index exceeds the supported search-item limit (" + root.maxSearchItems + ")")
    var itemIndex = items.length
    var row = [
      String(itemIndex),
      root.cleanField(item.title),
      root.cleanField(item.path),
      root.cleanField(item.searchText)
    ].join(root.fieldSeparator)
    var rowBytes = root.utf8Bytes(row) + 1
    if (budget.bytes + rowBytes > root.maxFzfInputBytes)
      return root.failIndex("Vault index exceeds the supported fuzzy-search input limit")
    budget.bytes += rowBytes
    items.push(item)
    rows.push(row)
    return true
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
    var outputs = root.indexOutputs
    if (!root.refreshing || root.indexFailed || root.indexBuildJob
        || typeof outputs.files !== "string" || typeof outputs.aliases !== "string"
        || typeof outputs.bookmarks !== "string" || typeof outputs.unresolved !== "string"
        || typeof outputs.recents !== "string") return

    root.indexBuildJob = IndexBuilder.createJob(root.indexSerial, outputs)
    root.indexOutputs = ({})
    indexBuildTimer.start()
  }

  function continueIndexBuild() {
    var job = root.indexBuildJob
    if (!job || !root.refreshing || job.serial !== root.indexSerial) return

    if (IndexBuilder.advance(job, root, Date.now() + root.indexBuildChunkMs, 200)) {
      root.searchItems = job.searchItems
      root.exactSearchIndex = job.exactIndex
      root.fzfInput = job.rows.join("\n") + (job.rows.length ? "\n" : "")
      root.indexBuilt = true
      root.refreshing = false
      root.indexBuildJob = null
      recentModel.clear()
      for (var i = 0; i < job.recentRows.length; i++) recentModel.append(job.recentRows[i])
      if (!root.filterText && root.activeResultModel === recentModel) {
        root.selectedIndex = 0
        root.cursorActive = recentModel.count > 0
        pointerGate.reset()
      }
      if (root.opened && root.filterText) root.requestSearch()
      return
    }

    if (root.indexBuildJob === job && root.refreshing) indexBuildTimer.restart()
  }

  function titleForPath(path) {
    var slash = path.lastIndexOf("/")
    var name = slash >= 0 ? path.substring(slash + 1) : path
    return /\.md$/i.test(name) ? name.substring(0, name.length - 3) : name
  }

  function iconForPath(path) {
    var lower = String(path || "").toLocaleLowerCase()
    if (/\.base$/.test(lower)) return "󰆼"
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
      root.selectedIndex = 0
      root.emptySearchResult = false
      root.activeResultModel = recentModel
      root.cursorActive = recentModel.count > 0
      return
    }
    if (!root.indexReady) {
      // Do not make an entered query look ignored while the initial index
      // load is still in progress. maybeBuildIndex() starts this search once
      // all sources are ready.
      displayModel.clear()
      root.activeResultModel = displayModel
      root.cursorActive = false
      return
    }
    // Keep the current search batch visible until fzf returns its complete
    // replacement.
    root.requestSearch()
  }

  function requestSearch() {
    root.searchRevision += 1
    root.startSearch()
  }

  function startSearch() {
    if (root.activeSearchWorker) return
    if (!root.opened || !root.filterText || !root.indexReady) return

    if (!root.fzfInput) {
      root.activeSearchQuery = root.filterText
      root.activeSearchRevision = root.searchRevision
      root.emptySearchResult = true
      root.finishSearchProcess(root.searchRevision, false)
      return
    }

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
      root.errorText = "Unable to start fzf search"
      return
    }

    root.activeSearchWorker = worker
    searchTimeout.worker = worker
    searchTimeout.restart()
    worker.launchRequested = true
    worker.running = true
  }

  function finishSearchProcess(completedRevision, retryCurrent) {
    // The revision is the authoritative queue. If the query changed while
    // this worker was running—or the worker failed transiently—run exactly
    // the latest revision next. A separate boolean queue can lose this wakeup
    // when completion, timeout, and typing events interleave.
    if (root.filterText && (retryCurrent || completedRevision !== root.searchRevision)) {
      Qt.callLater(function() { root.startSearch() })
      return
    }

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
    var retryCurrent = false

    try {
      if (isCurrent && root.opened && !worker.cancelled
          && worker.sessionSerial === root.sessionSerial) {
        if (worker.timedOut) {
          retryCurrent = true
        } else if (worker.exitCode === 0 || worker.exitCode === 1) {
          root.applySearchOutput(worker.revision, worker.query, worker.exactIndexes, worker.collected)
          root.errorText = ""
        } else {
          root.emptySearchResult = false
          if (worker.revision === root.searchRevision)
            root.errorText = worker.errorOutput || "fzf search failed"
        }
      }
    } catch (error) {
      if (isCurrent && root.opened) {
        root.errorText = "Unable to process fzf results"
      }
      console.warn("Obsidian quick switcher search completion failed:", error)
    } finally {
      if (isCurrent) root.finishSearchProcess(worker.revision, retryCurrent)
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

    if (root.filterText) Qt.callLater(function() { root.startSearch() })
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
    root.dismiss()
    Quickshell.execDetached(args)
  }

  function createNote(requestedName) {
    var name = String(requestedName || root.filterText).trim()
    if (!name) return

    var args = ["obsidian", "create", "name=" + name, "open"]
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
      required property int outputLimit
      required property var originalCommand
      required property int attempt
      property string output: ""
      property string errorOutput: ""
      property int exitCode: -1
      property bool exitFinished: false
      property bool stdoutFinished: false
      property bool cancelled: false
      property bool completed: false
      property bool started: false
      property bool launchRequested: false

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
        onStreamFinished: {
          indexWorker.errorOutput = String(text || "").trim()
        }
      }
      onStarted: {
        indexWorker.started = true
      }
      onExited: function(code) {
        indexWorker.exitCode = code
        indexWorker.exitFinished = true
        root.maybeFinishIndexWorker(indexWorker)
      }
      onRunningChanged: {
        // Quickshell does not emit exited when a process fails to start.
        if (indexWorker.launchRequested && !indexWorker.running && !indexWorker.started
            && !indexWorker.exitFinished && !indexWorker.completed)
          root.abandonIndexWorker(indexWorker)
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
      property bool timedOut: false
      property bool cancelled: false
      property bool completed: false
      property bool forceKilled: false
      property bool launchRequested: false
      property bool started: false

      stdinEnabled: true
      command: [
        root.boundedCommandPath,
        String(root.maxFzfOutputBytes),
        String(root.maxStderrBytes),
        "fzf",
        "bash", "-c", root.fzfCommand, "obsidian-quick-switcher", worker.query
      ]

      stdout: StdioCollector {
        id: searchOutput
        waitForEnd: true
      }
      stderr: StdioCollector {
        id: searchError
        waitForEnd: true
      }

      onStarted: {
        worker.started = true
        if (worker.cancelled) {
          worker.running = false
          return
        }
        // Each worker receives one immutable in-memory index, then gets an
        // explicit EOF. This avoids depending on a sentinel surviving a large
        // asynchronous stdin write and guarantees fzf can finish its batch.
        worker.write(worker.searchInput)
        worker.stdinEnabled = false
        worker.searchInput = ""
      }
      onExited: function(code) {
        // Quickshell finalizes StdioCollector before emitting Process.exited,
        // so completion needs only this single event rather than two flags.
        worker.collected = searchOutput.text
        worker.errorOutput = String(searchError.text || "").trim()
        worker.exitCode = code
        worker.exitFinished = true
        root.completeSearchWorker(worker)
      }
      onRunningChanged: {
        // Quickshell does not emit exited when a process fails to start.
        // Retire that worker immediately so it cannot hold the latest query.
        if (worker.launchRequested && !worker.running && !worker.started
            && !worker.exitFinished && !worker.completed)
          root.abandonSearchWorker(worker)
      }
    }
  }

  Timer {
    id: indexBuildTimer
    interval: 0
    repeat: false
    onTriggered: root.continueIndexBuild()
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
                font.pixelSize: Math.round(Style.font.iconLarge * root.fontScale)
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
                  font.pixelSize: Math.round(Style.font.body * root.fontScale)
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
                  font.pixelSize: Math.round(Style.font.caption * root.fontScale)
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
            text: root.cliDisabled
              ? root.cliDisabledMessage
              : (root.filterText
                ? (root.errorText || (!root.indexReady ? "Loading files, aliases, bookmarks, and links…" : "No matching files"))
                : (root.errorText || (!root.recentsReady ? "Loading recent notes…" : "No recent notes")))
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.body * root.fontScale)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
