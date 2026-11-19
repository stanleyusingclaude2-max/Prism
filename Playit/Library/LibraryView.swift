import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PlayitCore

private enum LibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case videos, images, folders
    var id: Self { self }
    var title: String {
        switch self { case .videos: return "所有视频"; case .images: return "所有图片"; case .folders: return "文件夹" }
    }
    var kind: MediaKind? {
        switch self { case .videos: return .video; case .images: return .image; case .folders: return nil }
    }
}

private struct FolderRoute: Hashable { let path: String }
private struct PhotoSelection: Identifiable { let id: String }
private struct LibraryQueryRequest: Hashable, Sendable {
    let category: LibraryCategory
    let search: String
    let folder: String?
    let sort: MediaSort
    let direction: SortDirection
    let revision: Int
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    let onPlay: (MediaItem, [MediaItem]) -> Void
    let onTransfer: () -> Void
    @State private var category: LibraryCategory = .videos
    @State private var routes: [FolderRoute] = []

    var body: some View {
        NavigationStack(path: $routes) {
            browser(folder: nil)
                .navigationDestination(for: FolderRoute.self) { route in browser(folder: route.path) }
        }
        .tint(Theme.accent)
        .font(AppTypography.body)
        .task { await store.refresh() }
        .onChange(of: store.folderRemoval) { _, removal in
            if let index = routes.firstIndex(where: { removal.paths.contains($0.path) }) {
                routes.removeSubrange(index...)
            }
        }
    }

    private func browser(folder: String?) -> some View {
        LibraryBrowser(
            store: store, folderPath: folder, category: $category,
            onNavigate: { routes.append(FolderRoute(path: $0)) },
            onFolderDeleted: { path in
                if let index = routes.firstIndex(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
                    routes.removeSubrange(index...)
                }
            },
            onPlay: onPlay, onTransfer: onTransfer
        )
    }
}

private struct LibraryBrowser: View {
    @ObservedObject var store: LibraryStore
    let folderPath: String?
    @Binding var category: LibraryCategory
    let onNavigate: (String) -> Void
    let onFolderDeleted: (String) -> Void
    let onPlay: (MediaItem, [MediaItem]) -> Void
    let onTransfer: () -> Void

    @AppStorage("library.sort") private var sortRaw = MediaSort.importedAt.rawValue
    @AppStorage("library.direction") private var directionRaw = SortDirection.descending.rawValue
    @State private var query = ""
    @State private var folders: [MediaFolder] = []
    @State private var showImporter = false
    @State private var showCreateFolder = false
    @State private var showsAbout = false
    @State private var newFolderName = ""
    @State private var renameItem: MediaItem?
    @State private var renameValue = ""
    @State private var deleteItems: [MediaItem] = []
    @State private var folderToDelete: MediaFolder?
    @State private var isDeletingFolder = false
    @State private var moveItems: [MediaItem] = []
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var selectedPhoto: PhotoSelection?
    @State private var results: [MediaItem] = []
    @State private var resultsCategory: LibraryCategory = .videos
    @State private var resultsFolder: String?
    @State private var isSearching = true

    private var sort: MediaSort { MediaSort(rawValue: sortRaw) ?? .importedAt }
    private var direction: SortDirection { SortDirection(rawValue: directionRaw) ?? .descending }
    /// Inside a folder the browser always shows that folder's own contents; the
    /// "all videos / all images" summaries belong to the library root.
    private var effectiveCategory: LibraryCategory { folderPath == nil ? category : .folders }
    private var request: LibraryQueryRequest {
        LibraryQueryRequest(category: effectiveCategory, search: query, folder: folderPath, sort: sort,
                            direction: direction, revision: store.queryRevision)
    }
    private var filteredItems: [MediaItem] {
        resultsCategory == effectiveCategory && resultsFolder == folderPath ? results : []
    }
    private var filteredFolders: [MediaFolder] {
        guard effectiveCategory == .folders else { return [] }
        return folders.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }
    private var selectedItems: [MediaItem] { store.items.filter { selection.contains($0.id) } }
    private var photoItems: [MediaItem] { filteredItems.filter { $0.kind == .image } }
    private var hasResults: Bool { !filteredItems.isEmpty || !filteredFolders.isEmpty }
    private var countText: String {
        switch effectiveCategory {
        case .videos: return "\(filteredItems.count) 个视频"
        case .images: return "\(filteredItems.count) 张图片"
        case .folders:
            if query.isEmpty { return "\(filteredFolders.count) 个文件夹 · \(filteredItems.count) 个文件" }
            return "找到 \(filteredFolders.count + filteredItems.count) 项"
        }
    }

    // Each opaque property gives the compiler a separate type-checking boundary.
    var body: some View { browserWithErrorAlert }

    private var browserContent: some View {
        resultsContent
            // Pinned below the navigation bar, while the list stays the primary
            // scroll view so the large title and the search field can collapse.
            .safeAreaInset(edge: .top, spacing: 0) {
                if folderPath == nil {
                    categoryPicker
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .background(Theme.bg)
                }
            }
    }

    @ViewBuilder private var resultsContent: some View {
        if hasResults {
            if effectiveCategory == .images && !isSelecting { photoGrid }
            else { mediaList }
        } else {
            GeometryReader { geometry in
                ScrollView {
                    emptyState.frame(minHeight: max(200, geometry.size.height - 48))
                }
                .refreshable { await store.refresh() }
            }
        }
    }

    private var browserLayout: some View {
        browserContent
            .background(Theme.bg)
            .navigationTitle(folderPath.map { ($0 as NSString).lastPathComponent } ?? "Prism")
            .navigationBarTitleDisplayMode(folderPath == nil ? .large : .inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text(searchPlaceholder))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar { navigationToolbar }
            .prismBrandToolbar(isVisible: folderPath == nil) { showsAbout = true }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomStatus }
    }

    private var browserWithTasks: some View {
        browserLayout
            .task(id: "\(folderPath ?? ""): \(store.revision): \(isDeletingFolder)") { await reloadFolders() }
            .task(id: request) { await updateResults() }
            // Files only disappear through a rescan or a folder deletion, and both
            // bump the revision. Comparing the whole item list on every update did not scale.
            .onChange(of: store.revision) { _, _ in
                selection.formIntersection(Set(store.items.map(\.id)))
            }
    }

    private var browserWithImporter: some View {
        browserWithTasks
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true,
                          onCompletion: importSelectedFiles)
    }

    private var browserWithSheets: some View {
        browserWithImporter
            .sheet(isPresented: movePresented) {
                MoveDestinationSheet(store: store, onMove: moveSelectedItems)
            }
            .sheet(isPresented: $showsAbout) { AboutView() }
            .fullScreenCover(item: $selectedPhoto) { photo in
                PhotoViewer(store: store, items: photoItems, initialID: photo.id)
            }
    }

    private var browserWithCreateAlert: some View {
        browserWithSheets.alert("新建文件夹", isPresented: $showCreateFolder) {
            TextField("文件夹名称", text: $newFolderName)
                .accessibilityIdentifier("folder.nameInput")
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建", action: createFolder)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("folder.create")
        }
    }

    private var browserWithRenameAlert: some View {
        browserWithCreateAlert.alert("重命名", isPresented: renamePresented) {
            TextField("文件名称", text: $renameValue)
            Button("取消", role: .cancel) { renameItem = nil }
            Button("保存", action: saveRename)
                .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("不填写扩展名时会保留原来的格式。") }
    }

    private var browserWithFileDeleteDialog: some View {
        browserWithRenameAlert.confirmationDialog("删除 \(deleteItems.count) 个文件？",
                                                  isPresented: fileDeletePresented, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteSelectedFiles)
                .accessibilityIdentifier("file.confirmDelete")
        } message: { Text("文件将从 Prism 的本地媒体库中删除，变空的文件夹会自动清理。") }
    }

    private var browserWithFolderDeleteDialog: some View {
        browserWithFileDeleteDialog.confirmationDialog("删除文件夹“\(folderToDelete?.name ?? "")”？",
                                                       isPresented: folderDeletePresented, titleVisibility: .visible) {
            Button("删除文件夹", role: .destructive, action: deleteSelectedFolder)
                .accessibilityIdentifier("folder.confirmDelete")
            Button("取消", role: .cancel) { folderToDelete = nil }
                .accessibilityIdentifier("folder.cancelDelete")
        } message: {
            Text("此文件夹及其中的所有文件、子文件夹都将从 Prism 删除，无法撤销。")
        }
    }

    private var browserWithErrorAlert: some View {
        browserWithFolderDeleteDialog.alert("操作未完成", isPresented: errorPresented) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var movePresented: Binding<Bool> {
        Binding(get: { !moveItems.isEmpty }, set: { if !$0 { moveItems = [] } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })
    }

    private var fileDeletePresented: Binding<Bool> {
        Binding(get: { !deleteItems.isEmpty }, set: { if !$0 { deleteItems = [] } })
    }

    private var folderDeletePresented: Binding<Bool> {
        Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    private func reloadFolders() async {
        guard !isDeletingFolder, !Task.isCancelled else { return }
        let snapshot = await store.folders(in: folderPath)
        guard !Task.isCancelled else { return }
        folders = snapshot
    }

    private func importSelectedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): Task { await store.importFiles(urls, into: folderPath) }
        case .failure(let error): store.errorMessage = error.localizedDescription
        }
    }

    private func moveSelectedItems(to folder: String?) {
        let items = moveItems
        moveItems = []
        Task {
            await store.move(items, to: folder)
            selection.removeAll()
            isSelecting = false
        }
    }

    private func createFolder() {
        let name = newFolderName
        newFolderName = ""
        Task {
            await store.createFolder(named: name, in: folderPath)
            category = .folders
        }
    }

    private func saveRename() {
        guard let item = renameItem else { return }
        let name = renameValue
        renameItem = nil
        Task { await store.rename(item, to: name) }
    }

    private func deleteSelectedFiles() {
        let items = deleteItems
        deleteItems = []
        Task {
            await store.delete(items)
            selection.removeAll()
            isSelecting = false
        }
    }

    private var categoryPicker: some View {
        Picker("媒体类型", selection: Binding(
            get: { category },
            set: { value in
                selection.removeAll(); isSelecting = false
                category = value
            }
        )) {
            ForEach(LibraryCategory.allCases) { item in Text(item.title).tag(item) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("library.category")
        .frame(minHeight: 36)
    }

    /// The count and sort menu scroll away with the content instead of taking a fixed row.
    private var listHeader: some View {
        HStack {
            Text(countText).font(AppTypography.caption).foregroundStyle(Theme.muted)
            Spacer()
            Menu {
                Picker("排序方式", selection: $sortRaw) {
                    ForEach(MediaSort.allCases, id: \.self) { value in
                        Text(value.title).tag(value.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Picker("顺序", selection: $directionRaw) {
                    Text("升序").tag(SortDirection.ascending.rawValue)
                    Text("降序").tag(SortDirection.descending.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    DesignIcon(name: "IconSort", size: 16)
                    Text(sort.title + (direction == .ascending ? " ↑" : " ↓")).font(AppTypography.caption)
                }
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("排序方式，\(sort.title)，\(direction == .ascending ? "升序" : "降序")")
            .accessibilityIdentifier("library.sort")
        }
    }

    private var searchPlaceholder: String {
        if folderPath != nil { return "搜索此文件夹及子文件夹" }
        switch category {
        case .videos: return "搜索视频名称"
        case .images: return "搜索图片名称"
        case .folders: return "搜索文件夹或文件"
        }
    }

    private var mediaList: some View {
        List {
            listHeader
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 16))
            ForEach(filteredFolders) { folder in folderRow(folder) }
            ForEach(filteredItems) { item in
                mediaRow(item)
                    .listRowBackground(Theme.bg)
                    .listRowSeparatorTint(Theme.border)
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteItems = [item] } label: { Label("删除", systemImage: "trash") }
                        Button { moveItems = [item] } label: { Label("移动", systemImage: "folder") }.tint(Theme.raised)
                    }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("library.list")
    }

    private func folderRow(_ folder: MediaFolder) -> some View {
        HStack(spacing: 8) {
            Button { onNavigate(folder.path) } label: {
                HStack(spacing: 12) {
                    DesignIcon(name: "IconFolder", size: 28)
                        .foregroundStyle(Theme.muted).frame(width: 56, height: 56)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name).font(AppTypography.subheadline).foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text("\(folder.videoCount) 个视频 · \(folder.imageCount) 张图片")
                            .font(AppTypography.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    DesignIcon(name: "IconChevron", size: 14).foregroundStyle(Theme.subtle)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("folder.\(folder.path)")
            Menu { folderActions(folder) } label: {
                DesignIcon(name: "IconMore", size: 22).foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
            }
            .frame(width: 44, height: 44).fixedSize()
            .accessibilityLabel("\(folder.name) 的操作")
            .accessibilityIdentifier("folder.options.\(folder.path)")
        }
        .disabled(isDeletingFolder)
        .contextMenu { folderActions(folder) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { folderActions(folder) }
        .listRowBackground(Theme.bg)
        .listRowSeparatorTint(Theme.border)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12))
    }

    private func folderActions(_ folder: MediaFolder) -> some View {
        Button(role: .destructive) { folderToDelete = folder } label: {
            Label("删除文件夹", systemImage: "trash")
        }
        .disabled(isDeletingFolder)
        .accessibilityIdentifier("folder.delete.\(folder.path)")
    }

    private func deleteSelectedFolder() {
        guard let folder = folderToDelete, !isDeletingFolder else { return }
        folderToDelete = nil
        isDeletingFolder = true
        Task {
            let deleted = await store.deleteFolder(folder)
            if deleted { folders.removeAll { $0.path == folder.path || $0.path.hasPrefix(folder.path + "/") } }
            isDeletingFolder = false
            if deleted { onFolderDeleted(folder.path) }
        }
    }

    private func mediaRow(_ item: MediaItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { open(item) } label: {
                HStack(alignment: .center, spacing: 12) {
                    if isSelecting {
                        Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 44)
                    }
                    MediaThumbnail(item: item, url: store.url(for: item))
                        .frame(width: 96, height: 64)
                        .clipped()
                        .fixedSize()
                    MediaRowDetails(item: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 64, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(rowAccessibilityLabel(for: item))
            .accessibilityIdentifier("media.\(item.filename)")
            if !isSelecting {
                Menu { fileActions(item) } label: {
                    DesignIcon(name: "IconMore", size: 22).foregroundStyle(Theme.muted).frame(width: 44, height: 44)
                }
                .frame(width: 44, height: 44)
                .fixedSize()
                .accessibilityLabel("\(item.filename) 的操作")
                .accessibilityIdentifier("file.options.\(item.relativePath)")
            }
        }
        .frame(height: 64)
        .contextMenu { fileActions(item) }
    }

    private func rowAccessibilityLabel(for item: MediaItem) -> String {
        var parts = [item.filename, item.kind == .video ? item.displayDuration : "图片", item.displaySize]
        if let position = item.playbackPosition, item.kind == .video {
            parts.append("上次看到 " + MediaFormatting.time(position))
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder private func fileActions(_ item: MediaItem) -> some View {
        Button { renameValue = item.filename; renameItem = item } label: { Label("重命名", systemImage: "pencil") }
        Button { moveItems = [item] } label: { Label("移动到文件夹", systemImage: "folder") }
            .accessibilityIdentifier("file.move.\(item.relativePath)")
        ShareLink(item: store.url(for: item)) { Label("分享文件", systemImage: "square.and.arrow.up") }
        Button { selection = [item.id]; isSelecting = true } label: { Label("多选", systemImage: "checkmark.circle") }
        Button(role: .destructive) { deleteItems = [item] } label: { Label("删除", systemImage: "trash") }
            .accessibilityIdentifier("file.delete.\(item.relativePath)")
    }

    /// A Photos-style grid: square cells, no captions. Names stay in the context
    /// menu and in VoiceOver.
    private var photoGrid: some View {
        ScrollView {
            listHeader
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 2)], spacing: 2) {
                ForEach(filteredItems) { item in
                    Button { open(item) } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                MediaThumbnail(item: item, url: store.url(for: item), showsDuration: false)
                            }
                            .clipped()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { fileActions(item) }
                    .accessibilityLabel("\(item.filename)，\(item.displaySize)")
                    .accessibilityIdentifier("media.\(item.filename)")
                }
            }
            .padding(.bottom)
        }
        .refreshable { await store.refresh() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            if store.isLoading || isSearching {
                ProgressView(store.isLoading ? "正在读取媒体库…" : "正在检索…").tint(Theme.accent)
            } else if !query.isEmpty {
                Image(systemName: "magnifyingglass").font(AppTypography.largeTitle).foregroundStyle(Theme.muted)
                Text("没有找到“\(query)”").font(AppTypography.headline).foregroundStyle(Theme.text)
                Text("试试其他名称，或切换媒体类型。").font(AppTypography.subheadline).foregroundStyle(Theme.muted)
                Button("清除搜索") { query = "" }.buttonStyle(.bordered)
            } else {
                Image(systemName: effectiveCategory == .folders ? "folder" : effectiveCategory == .images ? "photo.on.rectangle" : "film.stack")
                    .font(.system(size: 40)).foregroundStyle(Theme.muted)
                Text(folderPath != nil ? "文件夹是空的" : effectiveCategory == .images ? "还没有图片" : effectiveCategory == .folders ? "整理你的本地媒体" : "把喜欢的片段带过来")
                    .font(AppTypography.headline).foregroundStyle(Theme.text)
                Text("使用右上角“+”导入文件，或前往“传文件”从电脑传入。")
                    .font(AppTypography.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(24)
    }

    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isSelecting.toggle()
                if !isSelecting { selection.removeAll() }
            } label: {
                Text(isSelecting ? "完成" : "选择").font(AppTypography.subheadline)
            }
            .foregroundStyle(isSelecting ? Theme.accent : Theme.text)
            .disabled(!isSelecting && filteredItems.isEmpty)
            .accessibilityLabel(isSelecting ? "完成选择" : "选择文件")
            .accessibilityIdentifier("library.select")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showImporter = true } label: { Label("导入视频或图片", systemImage: "doc.badge.plus") }
                Button { newFolderName = ""; showCreateFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("folder.new")
                Button(action: onTransfer) { Label("从电脑传入", systemImage: "desktopcomputer") }
                if let folderPath {
                    Divider()
                    Button(role: .destructive) { folderToDelete = MediaFolder(path: folderPath) } label: {
                        Label("删除当前文件夹", systemImage: "trash")
                    }
                    .disabled(isDeletingFolder)
                    .accessibilityIdentifier("folder.deleteCurrent")
                }
                Divider()
                Button { showsAbout = true } label: { Label("关于与开源许可", systemImage: "info.circle") }
                    .accessibilityIdentifier("library.about")
            } label: { DesignIcon(name: "IconPlus", size: 22) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).foregroundStyle(Theme.onAccent)
            .accessibilityLabel("导入和新建").accessibilityIdentifier("library.import")
        }
    }

    @ViewBuilder private var bottomStatus: some View {
        if isDeletingFolder {
            HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text("正在删除文件夹…").font(AppTypography.caption); Spacer() }
                .padding().background(Theme.surface)
        } else if store.isImporting {
            HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text(store.importProgress).font(AppTypography.caption); Spacer() }
                .padding().background(Theme.surface)
        } else if isSelecting {
            HStack {
                Text("已选 \(selection.count) 项").font(AppTypography.subheadline).foregroundStyle(Theme.text)
                Spacer()
                Button("全选") { selection = Set(filteredItems.map(\.id)) }.font(AppTypography.subheadline)
                Button { moveItems = selectedItems } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
                    .disabled(selection.isEmpty).accessibilityLabel("移动所选文件")
                Button(role: .destructive) { deleteItems = selectedItems } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                    .disabled(selection.isEmpty).accessibilityLabel("删除所选文件")
            }
            .padding(.horizontal, 20).background(Theme.surface)
        }
    }

    private func open(_ item: MediaItem) {
        // Leave the search field so the keyboard does not return over the player.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if isSelecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if item.kind == .video {
            onPlay(item, filteredItems.filter { $0.kind == .video })
        }
        else { selectedPhoto = PhotoSelection(id: item.id) }
    }

    private func updateResults() async {
        let request = request
        isSearching = true
        if !request.search.isEmpty {
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
        }
        let snapshot = store.items
        let result = await Task.detached(priority: .userInitiated) {
            let filtered = MediaQuery(kind: request.category.kind, search: request.search, folderPath: request.folder, sort: request.sort, direction: request.direction).apply(to: snapshot)
            if request.category == .folders && request.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return filtered.filter { $0.folderPath == (request.folder ?? "") }
            }
            return filtered
        }.value
        guard !Task.isCancelled else { return }
        results = result
        resultsCategory = request.category
        resultsFolder = request.folder
        isSearching = false
    }
}

private struct MediaRowDetails: View {
    let item: MediaItem

    var body: some View {
        ViewThatFits(in: .vertical) {
            // Keep the folder context when the title fits in the available
            // slot. A wrapping title or large text uses the compact variant.
            VStack(alignment: .leading, spacing: 3) {
                filename
                metadata
                Text(item.folderPath.isEmpty ? "本地媒体库" : item.folderPath.replacingOccurrences(of: "/", with: " / "))
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                filename
                metadata
            }
            .fixedSize(horizontal: false, vertical: true)

            // The whole filename remains available in the row's accessibility
            // label and file actions when even the compact layout will not fit.
            filename
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filename: some View {
        Text(item.filename)
            .font(AppTypography.subheadline.weight(.medium))
            .foregroundStyle(Theme.text)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        Text(item.displayMetadata)
            .font(AppTypography.caption2)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MoveDestinationSheet: View {
    @ObservedObject var store: LibraryStore
    let onMove: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [MediaFolder] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Button { onMove(nil) } label: { Label("本地媒体库", systemImage: "tray") }
                    .listRowBackground(Theme.surface)
                ForEach(folders) { folder in
                    Button { onMove(folder.path) } label: { Label(folder.path.replacingOccurrences(of: "/", with: " / "), systemImage: "folder") }
                        .accessibilityIdentifier("move.destination.\(folder.path)")
                        .listRowBackground(Theme.surface)
                }
                if isLoading { ProgressView("正在读取文件夹…").listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("移动到文件夹").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { folders = await store.allFolders(); isLoading = false }
        }
        .tint(Theme.accent)
    }
}

private extension MediaSort {
    var title: String {
        switch self { case .name: return "名称"; case .importedAt: return "导入时间"; case .duration: return "时长"; case .fileSize: return "文件大小" }
    }
}

#if DEBUG
private struct MediaRowLayoutPreview: View {
    private let samples: [MediaItem] = [
        MediaItem(relativePath: "旅行/手机竖拍_一个很长很长需要换行但不应该撑高单元格的视频名称_01.mp4", kind: .video, byteCount: 24_600_000, duration: 18.8, pixelWidth: 1080, pixelHeight: 1920),
        MediaItem(relativePath: "横屏片段.mov", kind: .video, byteCount: 86_200_000, duration: 32.4, pixelWidth: 3840, pixelHeight: 2160, playbackPosition: 12),
        MediaItem(relativePath: "图片/超长文件名的竖向照片_原始尺寸不应影响网格或行高.heic", kind: .image, byteCount: 3_600_000, pixelWidth: 1200, pixelHeight: 4000)
    ]

    var body: some View {
        List {
            ForEach(Array(samples.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .center, spacing: 12) {
                    MediaThumbnailArtwork(item: item, image: image(portrait: index != 1))
                        .frame(width: 96, height: 64)
                        .clipped()
                    MediaRowDetails(item: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 64)
                    DesignIcon(name: "IconMore")
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                        .fixedSize()
                }
                .frame(height: 64)
                .listRowBackground(Theme.bg)
                .listRowSeparatorTint(Theme.border)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func image(portrait: Bool) -> UIImage {
        let size = portrait ? CGSize(width: 90, height: 320) : CGSize(width: 320, height: 90)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.lightGray.setFill()
            context.fill(CGRect(x: size.width * 0.25, y: size.height * 0.25, width: size.width * 0.5, height: size.height * 0.5))
        }
    }
}

#Preview("媒体行 · 竖视频与长文件名") {
    MediaRowLayoutPreview().frame(width: 393, height: 500)
}

#Preview("媒体行 · 辅助功能大字") {
    MediaRowLayoutPreview().environment(\.dynamicTypeSize, .accessibility3).frame(width: 393, height: 500)
}
#endif
