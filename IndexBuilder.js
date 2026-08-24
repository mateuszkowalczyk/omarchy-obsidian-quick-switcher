.pragma library

function createJob(serial, sources) {
  return {
    serial: serial,
    sources: sources,
    phase: "files",
    filesStart: 0,
    filesCount: 0,
    existingPathIndex: ({}),
    byPath: ({}),
    order: [],
    aliasStart: 0,
    aliasCount: 0,
    bookmarksByPath: ({}),
    bookmarkPaths: [],
    bookmarkStart: 0,
    bookmarkCount: 0,
    unresolvedItems: [],
    unresolvedSeen: ({}),
    unresolvedCursor: 0,
    notesByPath: ({}),
    searchItems: [],
    rows: [],
    fzfBudget: { bytes: 0 },
    orderCursor: 0,
    orderBookmarks: null,
    orderBookmarkCursor: 0,
    orphanPaths: [],
    orphanPathCursor: 0,
    orphanBookmarks: null,
    orphanBookmarkCursor: 0,
    exactIndex: ({}),
    exactCursor: 0,
    recentsStart: 0,
    recentsCount: 0,
    recentsSeen: ({}),
    recentRows: []
  }
}


function advance(job, host, deadline, operationLimit) {
  var operations = 0
  while (host.indexBuildJob === job && host.refreshing
      && operations < operationLimit && Date.now() <= deadline) {
    if (job.phase === "files") {
      if (job.filesStart >= job.sources.files.length) {
        job.phase = "aliases"
        continue
      }
      var fileEnd = job.sources.files.indexOf("\n", job.filesStart)
      if (fileEnd < 0) fileEnd = job.sources.files.length
      var path = host.cleanField(job.sources.files.substring(job.filesStart, fileEnd).trim())
      job.filesStart = fileEnd + 1
      job.filesCount += 1
      operations += 1
      if (job.filesCount > host.maxFiles) {
        host.failIndex("Vault index exceeds the supported file limit (" + host.maxFiles + ")")
        return
      }
      if (!host.checkField(path, host.maxPathBytes, "path")) return
      var pathKey = host.pathIndexKey(path)
      if (!path || job.existingPathIndex[pathKey]) continue
      job.existingPathIndex[pathKey] = true
      job.byPath[path] = { path: path, title: host.titleForPath(path), aliases: [] }
      job.order.push(path)
      continue
    }

    if (job.phase === "aliases") {
      if (job.aliasStart >= job.sources.aliases.length) {
        job.phase = "bookmarks"
        continue
      }
      var aliasEnd = job.sources.aliases.indexOf("\n", job.aliasStart)
      if (aliasEnd < 0) aliasEnd = job.sources.aliases.length
      var line = job.sources.aliases.substring(job.aliasStart, aliasEnd)
      job.aliasStart = aliasEnd + 1
      job.aliasCount += 1
      operations += 1
      if (job.aliasCount > host.maxAliases) {
        host.failIndex("Vault index exceeds the supported alias limit (" + host.maxAliases + ")")
        return
      }
      var tab = line.indexOf("\t")
      if (tab < 1) continue
      var alias = host.cleanField(line.substring(0, tab).trim())
      var aliasPath = host.cleanField(line.substring(tab + 1).trim())
      if (!alias || !aliasPath) continue
      if (!host.checkField(alias, host.maxLabelBytes, "alias")
          || !host.checkField(aliasPath, host.maxPathBytes, "alias path")) return
      if (!job.byPath[aliasPath]) {
        if (job.order.length >= host.maxFiles) {
          host.failIndex("Vault index exceeds the supported indexed-path limit (" + host.maxFiles + ")")
          return
        }
        job.byPath[aliasPath] = { path: aliasPath, title: host.titleForPath(aliasPath), aliases: [] }
        job.order.push(aliasPath)
      }
      if (job.byPath[aliasPath].aliases.indexOf(alias) < 0) {
        if (job.byPath[aliasPath].aliases.length >= host.maxAliasesPerFile) {
          host.failIndex("Vault index exceeds the supported aliases-per-file limit (" + host.maxAliasesPerFile + ")")
          return
        }
        job.byPath[aliasPath].aliases.push(alias)
      }
      continue
    }

    if (job.phase === "bookmarks") {
      if (job.bookmarkStart >= job.sources.bookmarks.length) {
        job.phase = "unresolved-json"
        continue
      }
      var bookmarkEnd = job.sources.bookmarks.indexOf("\n", job.bookmarkStart)
      if (bookmarkEnd < 0) bookmarkEnd = job.sources.bookmarks.length
      var bookmarkLine = job.sources.bookmarks.substring(job.bookmarkStart, bookmarkEnd)
      job.bookmarkStart = bookmarkEnd + 1
      job.bookmarkCount += 1
      operations += 1
      if (job.bookmarkCount > host.maxBookmarks) {
        host.failIndex("Vault index exceeds the supported bookmark limit (" + host.maxBookmarks + ")")
        return
      }
      var firstTab = bookmarkLine.indexOf("\t")
      var secondTab = firstTab >= 0 ? bookmarkLine.indexOf("\t", firstTab + 1) : -1
      if (firstTab < 1 || secondTab <= firstTab + 1
          || bookmarkLine.substring(0, firstTab).trim() !== "file") continue
      var bookmarkPath = host.cleanField(bookmarkLine.substring(firstTab + 1, secondTab).trim())
      var bookmarkName = host.cleanField(bookmarkLine.substring(secondTab + 1).trim())
      if (!bookmarkPath) continue
      if (!bookmarkName) bookmarkName = host.titleForPath(bookmarkPath)
      if (!host.checkField(bookmarkPath, host.maxPathBytes, "bookmark path")
          || !host.checkField(bookmarkName, host.maxLabelBytes, "bookmark name")) return
      if (!job.bookmarksByPath[bookmarkPath]) {
        job.bookmarksByPath[bookmarkPath] = []
        job.bookmarkPaths.push(bookmarkPath)
      }
      job.bookmarksByPath[bookmarkPath].push({ path: bookmarkPath, name: bookmarkName })
      continue
    }

    if (job.phase === "unresolved-json") {
      try {
        var parsedUnresolved = JSON.parse(job.sources.unresolved || "[]")
        if (Array.isArray(parsedUnresolved)) {
          if (parsedUnresolved.length > host.maxUnresolved) {
            host.failIndex("Vault index exceeds the supported unresolved-link limit (" + host.maxUnresolved + ")")
            return
          }
          job.unresolvedItems = parsedUnresolved
        }
      } catch (e) {
        job.unresolvedItems = []
      }
      job.phase = "items"
      operations += 1
      continue
    }

    if (job.phase === "items") {
      if (job.orderCursor >= job.order.length) {
        job.orphanPaths = job.bookmarkPaths
        job.phase = "orphans"
        continue
      }
      var note = job.byPath[job.order[job.orderCursor]]
      if (job.orderBookmarks === null) {
        job.notesByPath[host.pathIndexKey(note.path)] = note
        if (!host.appendSearchItem(job.searchItems, job.rows, {
          path: note.path,
          title: note.title,
          aliases: note.aliases.join(" · "),
          bookmarkName: "",
          isBookmark: false,
          createName: "",
          fileIcon: host.iconForPath(note.path),
          searchText: note.aliases.join(" ")
        }, job.fzfBudget)) return
        job.orderBookmarks = job.bookmarksByPath[note.path] || []
        job.orderBookmarkCursor = 0
        operations += 1
        continue
      }
      if (job.orderBookmarkCursor < job.orderBookmarks.length) {
        var noteBookmark = job.orderBookmarks[job.orderBookmarkCursor++]
        if (!host.appendSearchItem(job.searchItems, job.rows, {
          path: noteBookmark.path,
          title: noteBookmark.name,
          aliases: "",
          bookmarkName: noteBookmark.name,
          isBookmark: true,
          createName: "",
          fileIcon: host.bookmarkIcon,
          searchText: noteBookmark.name
        }, job.fzfBudget)) return
        operations += 1
        continue
      }
      job.orderBookmarks = null
      job.orderCursor += 1
      continue
    }

    if (job.phase === "orphans") {
      if (job.orphanBookmarks === null) {
        if (job.orphanPathCursor >= job.orphanPaths.length) {
          job.phase = "unresolved-items"
          continue
        }
        if (job.byPath[job.orphanPaths[job.orphanPathCursor]]) {
          job.orphanPathCursor += 1
          operations += 1
          continue
        }
        job.orphanBookmarks = job.bookmarksByPath[job.orphanPaths[job.orphanPathCursor]] || []
        job.orphanBookmarkCursor = 0
      }
      if (job.orphanBookmarkCursor < job.orphanBookmarks.length) {
        var orphan = job.orphanBookmarks[job.orphanBookmarkCursor++]
        if (!host.appendSearchItem(job.searchItems, job.rows, {
          path: orphan.path,
          title: orphan.name,
          aliases: "",
          bookmarkName: orphan.name,
          isBookmark: true,
          createName: "",
          fileIcon: host.bookmarkIcon,
          searchText: orphan.name
        }, job.fzfBudget)) return
        operations += 1
        continue
      }
      job.orphanBookmarks = null
      job.orphanPathCursor += 1
      continue
    }

    if (job.phase === "unresolved-items") {
      if (job.unresolvedCursor >= job.unresolvedItems.length) {
        job.phase = "exact-index"
        continue
      }
      var unresolvedItem = job.unresolvedItems[job.unresolvedCursor++]
      var unresolvedLink = unresolvedItem && unresolvedItem.link
      if (!host.checkField(unresolvedLink, host.maxPathBytes, "unresolved link")) return
      var unresolvedName = host.createableUnresolvedName(unresolvedLink)
      operations += 1
      if (!unresolvedName || job.unresolvedSeen[unresolvedName]) continue
      job.unresolvedSeen[unresolvedName] = true
      if (!host.appendSearchItem(job.searchItems, job.rows, {
        path: "",
        title: unresolvedName,
        aliases: "",
        bookmarkName: "",
        isBookmark: false,
        createName: unresolvedName,
        fileIcon: host.createIcon,
        searchText: unresolvedName
      }, job.fzfBudget)) return
      continue
    }

    if (job.phase === "exact-index") {
      if (job.exactCursor >= job.searchItems.length) {
        job.phase = "recents"
        continue
      }
      var exactItem = job.searchItems[job.exactCursor]
      host.addExactSearchEntry(job.exactIndex, exactItem.title, job.exactCursor)
      host.addExactSearchEntry(job.exactIndex, exactItem.bookmarkName, job.exactCursor)
      host.addExactSearchEntry(job.exactIndex, exactItem.createName, job.exactCursor)
      host.addExactSearchEntry(job.exactIndex, exactItem.path, job.exactCursor)
      host.addExactSearchEntry(job.exactIndex,
        host.cleanField(exactItem.path).trim().replace(/\.[^/.]+$/, ""), job.exactCursor)
      var exactAliases = String(exactItem.aliases || "").split(" · ")
      for (var aliasIndex = 0; aliasIndex < exactAliases.length; aliasIndex++)
        host.addExactSearchEntry(job.exactIndex, exactAliases[aliasIndex], job.exactCursor)
      job.exactCursor += 1
      operations += 1
      continue
    }

    if (job.phase === "recents") {
      if (job.recentsStart >= job.sources.recents.length) {
        job.phase = "finalize"
        continue
      }
      var recentEnd = job.sources.recents.indexOf("\n", job.recentsStart)
      if (recentEnd < 0) recentEnd = job.sources.recents.length
      var recentPath = host.cleanField(job.sources.recents.substring(job.recentsStart, recentEnd).trim())
      job.recentsStart = recentEnd + 1
      job.recentsCount += 1
      operations += 1
      if (job.recentsCount > host.maxRecents) {
        host.failIndex("Vault index exceeds the supported recent-file limit (" + host.maxRecents + ")")
        return
      }
      if (!host.checkField(recentPath, host.maxPathBytes, "recent path")) return
      var recentKey = host.pathIndexKey(recentPath)
      if (!recentPath || !job.existingPathIndex[recentKey] || job.recentsSeen[recentKey]) continue
      job.recentsSeen[recentKey] = true
      if (job.recentRows.length >= 50) continue
      var recentTitle = host.titleForPath(recentPath)
      var recentAliases = ""
      var recentNote = job.notesByPath[recentKey]
      if (recentNote) {
        recentTitle = recentNote.title
        recentAliases = recentNote.aliases.join(" · ")
      }
      job.recentRows.push({
        notePath: recentPath,
        noteTitle: recentTitle,
        aliases: recentAliases,
        bookmarkName: "",
        isBookmark: false,
        createName: "",
        fileIcon: host.iconForPath(recentPath)
      })
      continue
    }

    if (job.phase === "finalize") return true
  }

  return false
}
