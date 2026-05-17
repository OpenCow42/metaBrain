import Foundation
import MetaBrainAppSupport
import MetaBrainCore
import Testing

private final class FakeStoreClient: MetaBrainStoreClient, @unchecked Sendable {
    let location: MetaBrainStoreLocation
    var entries: [DocumentTreeEntry]
    var documents: [DocumentPath: StoredDocument]
    var results: [SearchResult]
    var searchError: Error?
    var treeLoadCount = 0
    var searchedText: String?
    var searchedLimit: Int?

    init(
        location: MetaBrainStoreLocation = MetaBrainStoreLocation(
            metaBrainFolderURL: URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true),
            storeURL: URL(fileURLWithPath: "/tmp/.metabrain/store.leveldb", isDirectory: true)
        ),
        entries: [DocumentTreeEntry] = [],
        documents: [DocumentPath: StoredDocument] = [:],
        results: [SearchResult] = [],
        searchError: Error? = nil
    ) {
        self.location = location
        self.entries = entries
        self.documents = documents
        self.results = results
        self.searchError = searchError
    }

    func loadTree() async throws -> [DocumentTreeEntry] {
        treeLoadCount += 1
        return entries
    }

    func loadDocument(path: DocumentPath) async throws -> StoredDocument? {
        documents[path]
    }

    func search(text: String, limit: Int) async throws -> [SearchResult] {
        if let searchError {
            throw searchError
        }

        searchedText = text
        searchedLimit = limit
        return results
    }
}

private enum TestStoreError: Error, LocalizedError {
    case locked
    case searchUnavailable

    var errorDescription: String? {
        switch self {
        case .locked:
            "The metaBrain store is already open somewhere else."
        case .searchUnavailable:
            "Search index is unavailable."
        }
    }
}

private final class OpenFailureSwitch: @unchecked Sendable {
    var shouldFail = false
}

@Test func resolvesSelectedMetaBrainFolderToStoreChild() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
        .appendingPathComponent("metabrain-app-tests-\(UUID().uuidString)", isDirectory: true)
    let folderURL = rootURL.appendingPathComponent(".metaBrain", isDirectory: true)
    let storeURL = folderURL.appendingPathComponent("store.leveldb", isDirectory: true)
    try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: rootURL)
    }

    let location = try MetaBrainStoreLocation.resolve(selectedFolder: folderURL)

    #expect(location.metaBrainFolderURL.path == folderURL.standardizedFileURL.path)
    #expect(location.storeURL.path == storeURL.standardizedFileURL.path)
}

@Test func rejectsMissingOrWrongMetaBrainFolders() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
        .appendingPathComponent("metabrain-app-tests-\(UUID().uuidString)", isDirectory: true)
    let folderURL = rootURL.appendingPathComponent(".metabrain", isDirectory: true)
    let missingFolderURL = rootURL
        .appendingPathComponent("missing", isDirectory: true)
        .appendingPathComponent(".metabrain", isDirectory: true)
    let wrongFolderURL = rootURL.appendingPathComponent("notes", isDirectory: true)
    try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: wrongFolderURL, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: rootURL)
    }

    #expect(throws: MetaBrainAppSupportError.missingStore(
        folderURL.appendingPathComponent("store.leveldb", isDirectory: true).standardizedFileURL.path
    )) {
        try MetaBrainStoreLocation.resolve(selectedFolder: folderURL)
    }
    #expect(throws: MetaBrainAppSupportError.invalidMetaBrainFolder(wrongFolderURL.standardizedFileURL.path)) {
        try MetaBrainStoreLocation.resolve(selectedFolder: wrongFolderURL)
    }
    #expect(throws: MetaBrainAppSupportError.missingMetaBrainFolder(missingFolderURL.standardizedFileURL.path)) {
        try MetaBrainStoreLocation.resolve(selectedFolder: missingFolderURL)
    }
}

@Test func treeBuilderCreatesMissingAncestorsAndStableChildren() throws {
    let notesPath = try DocumentPath("/notes")
    let todayPath = try DocumentPath("/notes/today")
    let archivePath = try DocumentPath("/notes/archive")
    let todayID = try DocumentID(rawValue: "doc-today")
    let archiveID = try DocumentID(rawValue: "doc-archive")

    let forest = MetaBrainTreeBuilder.forest(from: [
        DocumentTreeEntry(
            path: todayPath,
            name: "today",
            hasChildren: false,
            documentID: todayID
        ),
        DocumentTreeEntry(
            path: archivePath,
            name: "archive",
            hasChildren: false,
            documentID: archiveID
        )
    ])

    #expect(forest.count == 1)
    #expect(forest.first?.path == notesPath)
    #expect(forest.first?.isDirectoryOnly == true)
    #expect(forest.first?.children.map(\.path) == [archivePath, todayPath])
    #expect(MetaBrainTreeBuilder.ancestorPathIDs(for: todayPath) == [notesPath.rawValue])
}

@Test @MainActor func openingStoreLoadsTreeAndClearsSelection() async throws {
    let path = try DocumentPath("/notes/today")
    let fakeStore = FakeStoreClient(entries: [
        DocumentTreeEntry(
            path: path,
            name: "today",
            hasChildren: false,
            documentID: try DocumentID(rawValue: "doc-today")
        )
    ])
    let model = MetaBrainBrowserModel(
        state: MetaBrainBrowserState(
            selectedPath: try DocumentPath("/old"),
            expandedPathIDs: ["/old"],
            selectedDocument: DocumentPresentation(
                document: try storedDocument(path: try DocumentPath("/old"), title: "Old", body: "old")
            ),
            selectedDirectory: MetaBrainTreeNode(
                path: try DocumentPath("/old-directory"),
                name: "old-directory",
                entryHasChildren: true
            ),
            searchResults: [
                SearchResultPresentation(result: try searchResult(path: try DocumentPath("/old")))
            ],
            errorMessage: "old error"
        ),
        openStore: { _ in fakeStore }
    )

    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))

    let notesPath = try DocumentPath("/notes")
    #expect(model.state.location == fakeStore.location)
    #expect(model.state.tree.first?.path == notesPath)
    #expect(model.state.tree.first?.children.first?.path == path)
    #expect(model.state.selectedPath == nil)
    #expect(model.state.expandedPathIDs.isEmpty)
    #expect(model.state.selectedDocument == nil)
    #expect(model.state.selectedDirectory == nil)
    #expect(model.state.searchResults.isEmpty)
    #expect(model.state.errorMessage == nil)
    #expect(fakeStore.treeLoadCount == 1)
}

@Test @MainActor func failedOpenClearsStaleBrowserStateAndSurfacesError() async throws {
    let path = try DocumentPath("/notes/today")
    let document = try storedDocument(path: path, title: "Today", body: "find this")
    let successfulStore = FakeStoreClient(
        entries: [
            DocumentTreeEntry(
                path: path,
                name: "today",
                hasChildren: false,
                documentID: document.id
            )
        ],
        documents: [path: document],
        results: [try searchResult(path: path)]
    )
    let openFailure = OpenFailureSwitch()
    let model = MetaBrainBrowserModel { _ in
        if openFailure.shouldFail {
            throw TestStoreError.locked
        }

        return successfulStore
    }

    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))
    await model.selectPath(path)
    await model.search("find")
    openFailure.shouldFail = true

    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/locked.metabrain", isDirectory: true))

    #expect(model.state.location == nil)
    #expect(model.state.tree.isEmpty)
    #expect(model.state.selectedPath == nil)
    #expect(model.state.expandedPathIDs.isEmpty)
    #expect(model.state.selectedDocument == nil)
    #expect(model.state.selectedDirectory == nil)
    #expect(model.state.searchResults.isEmpty)
    #expect(model.state.isOpening == false)
    #expect(model.state.isLoadingDocument == false)
    #expect(model.state.isSearching == false)
    #expect(model.state.errorMessage == TestStoreError.locked.errorDescription)

    await model.search("find")
    #expect(model.state.errorMessage == MetaBrainAppSupportError.noOpenStore.description)
}

@Test @MainActor func searchErrorsClearStaleResultsAndSurfaceMessage() async throws {
    let path = try DocumentPath("/notes/today")
    let fakeStore = FakeStoreClient(
        entries: [
            DocumentTreeEntry(
                path: path,
                name: "today",
                hasChildren: false,
                documentID: try DocumentID(rawValue: "doc-today")
            )
        ],
        results: [try searchResult(path: path)]
    )
    let model = MetaBrainBrowserModel(openStore: { _ in fakeStore })
    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))
    await model.search("find")
    fakeStore.searchError = TestStoreError.searchUnavailable

    await model.search("find again")

    #expect(model.state.searchResults.isEmpty)
    #expect(model.state.isSearching == false)
    #expect(model.state.errorMessage == TestStoreError.searchUnavailable.errorDescription)
}

@Test @MainActor func selectingDocumentAndDirectoryUpdatesBrowserState() async throws {
    let notesPath = try DocumentPath("/notes")
    let todayPath = try DocumentPath("/notes/today")
    let document = try storedDocument(path: todayPath, title: "Today", body: "# Today")
    let fakeStore = FakeStoreClient(
        entries: [
            DocumentTreeEntry(
                path: notesPath,
                name: "notes",
                hasChildren: true
            ),
            DocumentTreeEntry(
                path: todayPath,
                name: "today",
                hasChildren: false,
                documentID: document.id
            )
        ],
        documents: [todayPath: document]
    )
    let model = MetaBrainBrowserModel(openStore: { _ in fakeStore })
    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))

    await model.selectPath(notesPath)
    #expect(model.state.selectedDirectory?.path == notesPath)
    #expect(model.state.selectedDocument == nil)

    await model.selectPath(todayPath)
    #expect(model.state.selectedPath == todayPath)
    #expect(model.state.selectedDocument?.title == "Today")
    #expect(model.state.selectedDocument?.body == "# Today")
    #expect(model.state.selectedDirectory == nil)
    #expect(model.state.expandedPathIDs.contains(notesPath.rawValue))
}

@Test @MainActor func missingDocumentSelectionShowsError() async throws {
    let path = try DocumentPath("/notes/missing")
    let fakeStore = FakeStoreClient(entries: [
        DocumentTreeEntry(
            path: path,
            name: "missing",
            hasChildren: false,
            documentID: try DocumentID(rawValue: "doc-missing")
        )
    ])
    let model = MetaBrainBrowserModel(openStore: { _ in fakeStore })
    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))

    await model.selectPath(path)

    #expect(model.state.selectedDocument == nil)
    #expect(model.state.errorMessage == MetaBrainAppSupportError.missingDocument(path.rawValue).description)
}

@Test @MainActor func searchClearsEmptyQueriesAndNavigatesResults() async throws {
    let path = try DocumentPath("/notes/today")
    let document = try storedDocument(path: path, title: "Today", body: "find this")
    let result = try searchResult(path: path)
    let fakeStore = FakeStoreClient(
        entries: [
            DocumentTreeEntry(
                path: path,
                name: "today",
                hasChildren: false,
                documentID: document.id
            )
        ],
        documents: [path: document],
        results: [result]
    )
    let model = MetaBrainBrowserModel(openStore: { _ in fakeStore })
    await model.openMetaBrainFolder(URL(fileURLWithPath: "/tmp/.metabrain", isDirectory: true))

    await model.search("  ")
    #expect(model.state.searchResults.isEmpty)

    await model.search("find", limit: 7)
    #expect(fakeStore.searchedText == "find")
    #expect(fakeStore.searchedLimit == 7)
    #expect(model.state.searchResults.map(\.path) == [path])

    let selectedResult = try #require(model.state.searchResults.first)
    await model.navigate(to: selectedResult)

    #expect(model.state.selectedPath == path)
    #expect(model.state.selectedDocument?.body == "find this")
}

private func storedDocument(
    path: DocumentPath,
    title: String?,
    body: String
) throws -> StoredDocument {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return StoredDocument(
        id: try DocumentID(rawValue: "doc-\(path.name.lowercased())"),
        path: path,
        title: title,
        body: body,
        tags: ["tag"],
        metadata: ["kind": "test"],
        references: [],
        currentVersion: 1,
        createdAt: now,
        updatedAt: now
    )
}

private func searchResult(path: DocumentPath) throws -> SearchResult {
    SearchResult(
        documentID: try DocumentID(rawValue: "doc-\(path.name.lowercased())"),
        path: path,
        title: path.name,
        chunkOrdinal: 0,
        snippet: "result for \(path.name)",
        score: 1
    )
}
