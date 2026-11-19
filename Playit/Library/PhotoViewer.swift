import SwiftUI
import UIKit
import PlayitCore

struct PhotoViewer: View {
    /// Used for file locations only, so it is deliberately not observed: an
    /// observed store re-rendered every page whenever background metadata arrived.
    let store: LibraryStore
    let items: [MediaItem]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var chromeHidden = false

    init(store: LibraryStore, items: [MediaItem], initialID: String) {
        self.store = store
        self.items = items
        _selectedID = State(initialValue: initialID)
    }

    private var index: Int? { items.firstIndex { $0.id == selectedID } }
    private var current: MediaItem? { index.map { items[$0] } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Pages always fill the screen, so hiding the bars never resizes
                // (and so never resets the zoom of) the current photo.
                PhotoPager(store: store, items: items, selectedID: $selectedID, onSingleTap: toggleChrome)
                    .ignoresSafeArea()
                if !chromeHidden, let index {
                    VStack(spacing: 4) {
                        Text("\(index + 1) / \(items.count)")
                            .font(AppTypography.numeric(.subheadline))
                            .foregroundStyle(Theme.text)
                        Text(items[index].displayMetadata).font(AppTypography.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(current?.displayTitle ?? "图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.6), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { DesignIcon(name: "IconClose", size: 20) }
                        .accessibilityLabel("关闭图片")
                        .accessibilityIdentifier("photo.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let current {
                        ShareLink(item: store.url(for: current)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .tint(Theme.accent)
        .font(AppTypography.body)
        .preferredColorScheme(.dark)
        .statusBarHidden(chromeHidden)
        .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
        .onChange(of: items.isEmpty) { _, isEmpty in
            // Every photo was removed while the viewer was open.
            if isEmpty { dismiss() }
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
    }
}

/// A UIKit pager. Only the visible page and its neighbours exist, so swiping
/// costs the same with ten photos or ten thousand. SwiftUI's paging TabView
/// rebuilt the whole list of pages whenever the selection changed, which made
/// large libraries stall in the middle of a swipe.
private struct PhotoPager: UIViewControllerRepresentable {
    let store: LibraryStore
    let items: [MediaItem]
    @Binding var selectedID: String
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 16])
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.attach(to: pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.update(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var parent: PhotoPager
        private weak var pager: UIPageViewController?
        private var items: [MediaItem] = []
        private var positions: [String: Int] = [:]
        private var currentIndex = 0
        private var isTransitioning = false
        /// The list as it was before a library change that arrived mid-swipe.
        private var itemsBeforeDeferredReload: [MediaItem]?

        init(parent: PhotoPager) {
            self.parent = parent
            super.init()
        }

        func attach(to pager: UIPageViewController) {
            self.pager = pager
            setItems(parent.items)
            guard !items.isEmpty else { return }
            currentIndex = min(positions[parent.selectedID] ?? 0, items.count - 1)
            pager.setViewControllers([makePage(at: currentIndex)], direction: .forward, animated: false)
        }

        func update(parent: PhotoPager) {
            self.parent = parent
            let previous = items
            guard parent.items.map(\.id) != previous.map(\.id) else {
                // Same files in the same order; keep the newest metadata only.
                items = parent.items
                return
            }
            setItems(parent.items)
            reloadPages(previous: previous)
        }

        private func setItems(_ newItems: [MediaItem]) {
            items = newItems
            var map: [String: Int] = [:]
            map.reserveCapacity(newItems.count)
            for (index, item) in newItems.enumerated() where map[item.id] == nil {
                map[item.id] = index
            }
            positions = map
        }

        /// The library changed while the viewer is open, for example when a Wi-Fi
        /// transfer finished. Keep the photo on screen when it still exists;
        /// otherwise show the photo that took its place.
        private func reloadPages(previous: [MediaItem]) {
            guard let pager, !items.isEmpty else { return }
            if isTransitioning {
                if itemsBeforeDeferredReload == nil { itemsBeforeDeferredReload = previous }
                return
            }
            if let page = pager.viewControllers?.first as? PhotoPageController,
               let index = positions[page.itemID] {
                currentIndex = index
                let oldIndex = previous.firstIndex { $0.id == page.itemID }
                guard neighbours(of: oldIndex, in: previous) != neighbours(of: index, in: items) else { return }
                // A new page instance drops the pager's cached neighbours.
                pager.setViewControllers([makePage(at: index)], direction: .forward, animated: false)
                return
            }
            currentIndex = min(currentIndex, items.count - 1)
            pager.setViewControllers([makePage(at: currentIndex)], direction: .forward, animated: false)
            select(items[currentIndex].id)
        }

        private func neighbours(of index: Int?, in list: [MediaItem]) -> [String?] {
            guard let index else { return [nil, nil] }
            return [index > 0 ? list[index - 1].id : nil, index + 1 < list.count ? list[index + 1].id : nil]
        }

        /// Writes the selection back to SwiftUI after the current view update.
        private func select(_ id: String) {
            guard parent.selectedID != id else { return }
            Task { @MainActor [weak self] in
                self?.parent.selectedID = id
            }
        }

        private func makePage(at index: Int) -> PhotoPageController {
            let item = items[index]
            let page = PhotoPageController(item: item, url: parent.store.url(for: item))
            page.onSingleTap = { [weak self] in self?.parent.onSingleTap() }
            page.onAccessibilityScroll = { [weak self] direction in self?.step(direction) ?? false }
            return page
        }

        /// VoiceOver's three-finger swipe moves one photo and announces the position.
        private func step(_ direction: UIAccessibilityScrollDirection) -> Bool {
            let offset: Int
            switch direction {
            case .left, .next: offset = 1
            case .right, .previous: offset = -1
            default: return false
            }
            let target = currentIndex + offset
            guard let pager, !isTransitioning, items.indices.contains(target) else { return false }
            pager.setViewControllers([makePage(at: target)], direction: offset > 0 ? .forward : .reverse, animated: false)
            currentIndex = target
            select(items[target].id)
            UIAccessibility.post(notification: .pageScrolled, argument: "第 \(target + 1) 张，共 \(items.count) 张")
            return true
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PhotoPageController,
                  let index = positions[page.itemID], index > 0 else { return nil }
            return makePage(at: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PhotoPageController,
                  let index = positions[page.itemID], index + 1 < items.count else { return nil }
            return makePage(at: index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTransitioning = false
            if completed, let page = pageViewController.viewControllers?.first as? PhotoPageController,
               let index = positions[page.itemID] {
                currentIndex = index
                select(page.itemID)
            }
            if let previous = itemsBeforeDeferredReload {
                itemsBeforeDeferredReload = nil
                reloadPages(previous: previous)
            }
        }
    }
}

/// Cancels a page's loading when the pager lets go of the page.
private final class PageLoadingTasks {
    var tasks: [Task<Void, Never>] = []

    deinit {
        for task in tasks { task.cancel() }
    }
}

/// One photo page. The grid's thumbnail, when it is still in memory, appears
/// at once and the full-resolution image replaces it, as in Photos.
private final class PhotoPageController: UIViewController {
    let itemID: String
    var onSingleTap: () -> Void = {}
    var onAccessibilityScroll: (UIAccessibilityScrollDirection) -> Bool = { _ in false }

    private let item: MediaItem
    private let url: URL
    private let photo = ZoomablePhotoContainer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private let loading = PageLoadingTasks()
    private var hasFullImage = false

    init(item: MediaItem, url: URL) {
        self.item = item
        self.url = url
        itemID = item.id
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let page = PhotoPageView()
        page.onAccessibilityScroll = { [weak self] direction in self?.onAccessibilityScroll(direction) ?? false }
        view = page
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = item.filename
        view.accessibilityTraits = .image

        photo.frame = view.bounds
        photo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        photo.onSingleTap = { [weak self] in self?.onSingleTap() }
        view.addSubview(photo)

        spinner.color = Theme.uiAccent
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        failure.text = "无法预览此图片\n文件可能损坏，或图片编码暂不受系统支持。"
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.textColor = UIColor(named: "Muted") ?? .secondaryLabel
        failure.font = AppTypography.uiFont(for: .subheadline)
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failure)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])

        let thumbnail = MediaThumbnailLoader.thumbnailDimension
        let previewKey = ThumbnailStore.key(for: item, url: url, maxDimension: thumbnail)
        if let preview = ThumbnailStore.shared.memoryImage(forKey: previewKey, maxDimension: thumbnail) {
            photo.setImage(preview)
        }
        load()
    }

    private func load() {
        let item = item
        let url = url
        loading.tasks.append(Task { [weak self] in
            let image = await MediaThumbnailLoader.image(for: item, at: url,
                                                         maxDimension: MediaThumbnailLoader.photoDimension)
            guard !Task.isCancelled, let self else { return }
            self.show(image)
        })
        // Most photos decode quickly; a spinner only appears when one does not.
        loading.tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.hasFullImage, !self.photo.hasImage else { return }
            self.spinner.startAnimating()
        })
    }

    private func show(_ image: UIImage?) {
        spinner.stopAnimating()
        if let image {
            hasFullImage = true
            // The same picture at full resolution: a zoom on the preview is kept.
            photo.setImage(image, resetZoom: false)
        } else if !photo.hasImage {
            failure.isHidden = false
            view.accessibilityLabel = item.filename + "，无法预览"
        }
    }
}

/// The page's root view; it also turns VoiceOver's three-finger swipes into page changes.
private final class PhotoPageView: UIView {
    var onAccessibilityScroll: (UIAccessibilityScrollDirection) -> Bool = { _ in false }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onAccessibilityScroll(direction)
    }
}

private final class ZoomablePhotoContainer: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var lastSize = CGSize.zero
    var onSingleTap: () -> Void = {}
    var hasImage: Bool { imageView.image != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        // The page already fills the screen; centerImage() owns the insets, so a
        // magnified photo does not jump when the system safe area would apply.
        scroll.contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        addSubview(scroll)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        // Photos keep double-tap zoom, so a single tap toggles the bars after it fails.
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
    }

    @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onSingleTap() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage, resetZoom: Bool = true) {
        guard imageView.image !== image else { return }
        imageView.image = image
        if resetZoom { scroll.setZoomScale(1, animated: false) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        if lastSize != bounds.size {
            scroll.zoomScale = 1
            imageView.frame = bounds
            scroll.contentSize = bounds.size
            lastSize = bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let x = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        let y = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
