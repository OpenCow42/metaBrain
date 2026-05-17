import AppKit
import MetaBrainAppSupport
import MetaBrainCore
import SwiftUI
import Textual

@MainActor
struct ContentView: View {
    @StateObject private var model: MetaBrainBrowserModel
    @State private var isSearchPresented = false

    init(model: MetaBrainBrowserModel = MetaBrainBrowserModel()) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailPane(model: model, openAction: showOpenPanel)
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button(action: showOpenPanel) {
                    Label("Open Database", systemImage: "folder")
                }
                .help("Open a .metabrain folder")

                Button {
                    isSearchPresented = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(model.state.location == nil)
                .help("Search the open metaBrain database")
            }
        }
        .sheet(isPresented: $isSearchPresented) {
            SearchSheet(model: model, isPresented: $isSearchPresented)
        }
        .onReceive(NotificationCenter.default.publisher(for: .metaBrainOpenDatabaseRequested)) { _ in
            showOpenPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .metaBrainFindRequested)) { _ in
            guard model.state.location != nil else {
                model.reportError(MetaBrainAppSupportError.noOpenStore.description)
                return
            }

            isSearchPresented = true
        }
    }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open metaBrain Database"
        panel.message = "Choose a .metabrain folder containing store.leveldb."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = defaultOpenDirectory()

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        Task {
            await model.openMetaBrainFolder(selectedURL)
            if model.state.location?.metaBrainFolderURL == selectedURL.standardizedFileURL {
                UserDefaults.standard.set(
                    selectedURL.standardizedFileURL.path,
                    forKey: Self.lastMetaBrainFolderDefaultsKey
                )
            }
        }
    }

    private func defaultOpenDirectory() -> URL {
        if let storedPath = UserDefaults.standard.string(forKey: Self.lastMetaBrainFolderDefaultsKey) {
            let storedURL = URL(fileURLWithPath: storedPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: storedURL.path) {
                return storedURL.deletingLastPathComponent()
            }
        }

        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let localMetaBrainURL = currentDirectoryURL
            .appendingPathComponent(".metabrain", isDirectory: true)
        if FileManager.default.fileExists(atPath: localMetaBrainURL.path) {
            return currentDirectoryURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static let lastMetaBrainFolderDefaultsKey = "MetaBrainApp.lastMetaBrainFolderPath"
}

private struct SidebarView: View {
    @ObservedObject var model: MetaBrainBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if model.state.isOpening {
                ProgressView("Opening database...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.state.location == nil {
                ContentUnavailableView(
                    "No Database",
                    systemImage: "folder",
                    description: Text("Open a .metabrain folder to browse documents.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.state.tree.isEmpty {
                ContentUnavailableView(
                    "No Documents",
                    systemImage: "tray",
                    description: Text("This metaBrain store does not have indexed documents yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.state.tree) { node in
                        TreeNodeView(node: node, model: model)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("metaBrain")
                    .font(.headline)
                Text(model.state.location?.metaBrainFolderURL.path ?? "No database open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct TreeNodeView: View {
    let node: MetaBrainTreeNode
    @ObservedObject var model: MetaBrainBrowserModel

    var body: some View {
        if node.children.isEmpty {
            treeRow
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.state.expandedPathIDs.contains(node.id) },
                    set: { model.setExpanded($0, for: node.id) }
                )
            ) {
                ForEach(node.children) { child in
                    TreeNodeView(node: child, model: model)
                }
            } label: {
                treeRow
            }
        }
    }

    private var treeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(node.isDocument ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background {
            if model.state.selectedPath == node.path {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .onTapGesture {
            Task {
                await model.selectPath(node.path)
            }
        }
        .accessibilityLabel(node.path.rawValue)
    }

    private var displayName: String {
        node.name == "/" ? "Root" : node.name
    }

    private var iconName: String {
        if node.isDocument {
            return node.children.isEmpty ? "doc.text" : "doc.text.below.ecg"
        }

        return node.children.isEmpty ? "folder" : "folder.fill"
    }
}

private struct DetailPane: View {
    @ObservedObject var model: MetaBrainBrowserModel
    var openAction: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if let errorMessage = model.state.errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.state.errorMessage)
    }

    @ViewBuilder
    private var content: some View {
        if model.state.isOpening {
            ProgressView("Opening database...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.state.location == nil {
            ContentUnavailableView {
                Label("Open a metaBrain database", systemImage: "folder")
            } description: {
                Text("Choose a .metabrain folder to browse, preview, and search its documents.")
            } actions: {
                Button("Open Database...", action: openAction)
                    .buttonStyle(.borderedProminent)
            }
        } else if let document = model.state.selectedDocument {
            DocumentDetailView(document: document)
                .overlay {
                    if model.state.isLoadingDocument {
                        ProgressView()
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
        } else if let directory = model.state.selectedDirectory {
            DirectoryDetailView(directory: directory)
        } else if model.state.tree.isEmpty {
            ContentUnavailableView(
                "No Documents",
                systemImage: "tray",
                description: Text("This database has no indexed documents to show.")
            )
        } else {
            ContentUnavailableView(
                "Select a Document",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose an item in the sidebar, or press Command-F to search.")
            )
        }
    }
}

private struct DocumentDetailView: View {
    let document: DocumentPresentation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(document.title?.isEmpty == false ? document.title! : document.path.name)
                        .font(.title.bold())
                        .textSelection(.enabled)

                    Text(document.path.rawValue)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                metadata

                Divider()

                StructuredText(markdown: document.body)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("Version \(document.currentVersion)", systemImage: "clock.arrow.circlepath")
                Label("Created \(document.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                Label("Updated \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "square.and.pencil")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !document.tags.isEmpty {
                FlowLine(items: document.tags.sorted()) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tertiary, in: Capsule())
                }
            }

            if !document.metadata.isEmpty {
                FlowLine(items: document.metadata.keys.sorted()) { key in
                    Text("\(key)=\(document.metadata[key] ?? "")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DirectoryDetailView: View {
    let directory: MetaBrainTreeNode

    var body: some View {
        ContentUnavailableView {
            Label(directory.name == "/" ? "Root" : directory.name, systemImage: "folder")
        } description: {
            Text("\(directory.path.rawValue) contains \(directory.children.count) item\(directory.children.count == 1 ? "" : "s").")
        }
    }
}

private struct SearchSheet: View {
    @ObservedObject var model: MetaBrainBrowserModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search metaBrain", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)

                if model.state.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(14)

            Divider()

            results
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            isSearchFocused = true
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.state.location == nil {
            ContentUnavailableView(
                "No Database",
                systemImage: "folder",
                description: Text("Open a .metabrain folder before searching.")
            )
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search Documents",
                systemImage: "magnifyingglass",
                description: Text("Type a term to search the open metaBrain database.")
            )
        } else if model.state.isSearching && model.state.searchResults.isEmpty {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.state.errorMessage {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if model.state.searchResults.isEmpty && !model.state.isSearching {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No indexed documents matched this query.")
            )
        } else {
            List(model.state.searchResults) { result in
                Button {
                    Task {
                        await model.navigate(to: result)
                        isPresented = false
                    }
                } label: {
                    SearchResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else {
                return
            }

            await model.search(text)
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResultPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.title?.isEmpty == false ? result.title! : result.path.name)
                    .font(.headline)
                Spacer()
                Text(String(format: "%.2f", result.score))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(result.path.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(result.snippet)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8, y: 3)
    }
}

private struct FlowLine<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
