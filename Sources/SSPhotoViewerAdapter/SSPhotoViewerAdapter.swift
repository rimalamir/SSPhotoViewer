import SwiftUI
import SSPhotoViewer

/// App-facing media resources. The adapter converts these to package media.
public enum ImageViewerMedia: Hashable, Sendable {
    case image(URL)
    case video(URL, posterURL: URL? = nil)

    fileprivate var ssPhotoViewerMedia: SSPhotoViewerItem.Media {
        switch self {
        case .image(let url): .image(url)
        case .video(let url, let posterURL): .video(url, posterURL: posterURL)
        }
    }
}

/// The only asset contract the consuming app must provide to the adapter.
///
/// Keep app repositories, chat models, gallery models, and authorization rules
/// outside this module. The adapter converts this contract into
/// ``SSPhotoViewerItem`` values before the viewer sees them.
public protocol ImageViewerAsset {
    /// Stable identity shared by chat, gallery, source registration, and viewer selection.
    var imageViewerID: String { get }
    /// Full-resolution image or video resource.
    var imageViewerMedia: ImageViewerMedia { get }
    /// Optional width divided by height.
    var imageViewerAspectRatio: CGFloat? { get }
    /// Optional lightweight preview or video poster.
    var imageViewerThumbnailURL: URL? { get }
    /// Whether the thumbnail preserves the full media's uncropped geometry.
    var imageViewerThumbnailPreservesMediaAspectRatio: Bool { get }
    /// VoiceOver label for the asset.
    var imageViewerAccessibilityLabel: String? { get }
}

public extension ImageViewerAsset {
    var imageViewerAspectRatio: CGFloat? { nil }
    var imageViewerThumbnailURL: URL? { nil }
    var imageViewerThumbnailPreservesMediaAspectRatio: Bool { false }
    var imageViewerAccessibilityLabel: String? { nil }
}

extension ImageViewerAsset {
    /// The package-facing representation of this app asset.
    var ssPhotoViewerItem: SSPhotoViewerItem {
        SSPhotoViewerItem(
            id: imageViewerID,
            media: imageViewerMedia.ssPhotoViewerMedia,
            aspectRatio: imageViewerAspectRatio,
            thumbnailURL: imageViewerThumbnailURL,
            thumbnailPreservesMediaAspectRatio:
                imageViewerThumbnailPreservesMediaAspectRatio,
            accessibilityLabel: imageViewerAccessibilityLabel
        )
    }
}

/// App-facing viewer presentation style.
public enum ImageViewerPresentationStyle: Hashable, Sendable {
    case sameHierarchy
    case fullScreen

    fileprivate var ssPhotoViewerStyle: SSPhotoViewerPresentationStyle {
        switch self {
        case .sameHierarchy: .sameHierarchy
        case .fullScreen: .fullScreen
        }
    }
}

/// App-facing initial chrome mode.
public enum ImageViewerDisplayMode: Hashable, Sendable {
    case minimal
    case detail

    fileprivate var ssPhotoViewerMode: SSPhotoViewerDisplayMode {
        switch self {
        case .minimal: .minimal
        case .detail: .detail
        }
    }
}

/// App-facing fallback behavior for source dismissal.
public enum ImageViewerFallbackDestination: Equatable, Sendable {
    case source
    case offscreenAfterLastVisible
    case fixed(CGRect)

    fileprivate var ssPhotoViewerDestination: SSPhotoViewerFallbackDestination {
        switch self {
        case .source: .source
        case .offscreenAfterLastVisible: .offscreenAfterLastVisible
        case .fixed(let frame): .fixed(frame)
        }
    }
}

/// App-facing action emitted by the adapter.
public enum ImageViewerAction: Sendable {
    case save(itemID: String)
    case share(itemID: String)
    case custom(id: String, itemID: String)
}

/// One app-owned page returned by an adapter page loader.
public struct ImageViewerPage<Asset: ImageViewerAsset> {
    public let assets: [Asset]
    public let hasMore: Bool

    public init(assets: [Asset], hasMore: Bool) {
        self.assets = assets
        self.hasMore = hasMore
    }
}

/// App-owned policy translated by the adapter into package configuration.
///
/// The app chooses this policy once at the composition boundary. Chat and
/// gallery views do not import or construct ``SSPhotoViewerConfiguration``.
public struct ImageViewerPresentationPolicy<Asset: ImageViewerAsset> {
    public var presentationStyle: ImageViewerPresentationStyle
    public var fallbackDestination: ImageViewerFallbackDestination
    public var initialDisplayMode: ImageViewerDisplayMode
    public var showsDefaultTopBar: Bool
    public var showsDefaultBottomBar: Bool
    public var showsDefaultPaginationStrip: Bool
    public var showsDefaultActionBar: Bool
    public var showsVideoControls: Bool
    public var pageLoader: ((Int) async -> ImageViewerPage<Asset>)?
    public var onAction: (ImageViewerAction) -> Void

    public init(
        presentationStyle: ImageViewerPresentationStyle = .sameHierarchy,
        fallbackDestination: ImageViewerFallbackDestination = .source,
        initialDisplayMode: ImageViewerDisplayMode = .minimal,
        showsDefaultTopBar: Bool = true,
        showsDefaultBottomBar: Bool = true,
        showsDefaultPaginationStrip: Bool = true,
        showsDefaultActionBar: Bool = true,
        showsVideoControls: Bool = true,
        pageLoader: ((Int) async -> ImageViewerPage<Asset>)? = nil,
        onAction: @escaping (ImageViewerAction) -> Void = { _ in }
    ) {
        self.presentationStyle = presentationStyle
        self.fallbackDestination = fallbackDestination
        self.initialDisplayMode = initialDisplayMode
        self.showsDefaultTopBar = showsDefaultTopBar
        self.showsDefaultBottomBar = showsDefaultBottomBar
        self.showsDefaultPaginationStrip = showsDefaultPaginationStrip
        self.showsDefaultActionBar = showsDefaultActionBar
        self.showsVideoControls = showsVideoControls
        self.pageLoader = pageLoader
        self.onAction = onAction
    }

    /// Builds the package configuration without exposing it to app screens.
    func makeConfiguration() -> SSPhotoViewerConfiguration {
        let packagePageLoader: SSPhotoViewerPageLoader? = pageLoader.map { loader in
            { pageNumber in
                let page = await loader(pageNumber)
                return SSPhotoViewerPage(
                    items: page.assets.map(\.ssPhotoViewerItem),
                    hasMore: page.hasMore
                )
            }
        }

        return SSPhotoViewerConfiguration(
            pageLoader: packagePageLoader,
            fallbackDestination: fallbackDestination.ssPhotoViewerDestination,
            initialDisplayMode: initialDisplayMode.ssPhotoViewerMode,
            showsDefaultTopBar: showsDefaultTopBar,
            showsDefaultBottomBar: showsDefaultBottomBar,
            showsDefaultPaginationStrip: showsDefaultPaginationStrip,
            showsDefaultActionBar: showsDefaultActionBar,
            showsVideoControls: showsVideoControls,
            onAction: { action in
                switch action {
                case .save(let item): onAction(.save(itemID: item.id))
                case .share(let item): onAction(.share(itemID: item.id))
                case .custom(let id, let item):
                    onAction(.custom(id: id, itemID: item.id))
                }
            }
        )
    }
}

/// The app-facing composition boundary for chat, gallery, and other media surfaces.
///
/// Keep one instance at the screen or scene composition root and pass that
/// instance to chat and gallery views. The bindings remain app-owned; this
/// adapter only writes them in ``present(_:)`` and ``dismiss()``.
public struct ImageViewerAdapter<Asset: ImageViewerAsset> {
    /// The app-owned presentation binding shared by chat and gallery.
    public let isPresented: Binding<Bool>
    /// The app-owned stable selected asset ID shared by chat and gallery.
    public let selectedID: Binding<String>

    private let assets: [Asset]
    private let policy: ImageViewerPresentationPolicy<Asset>

    public init(
        assets: [Asset],
        isPresented: Binding<Bool>,
        selectedID: Binding<String>,
        policy: ImageViewerPresentationPolicy<Asset> = .init()
    ) {
        self.assets = assets
        self.isPresented = isPresented
        self.selectedID = selectedID
        self.policy = policy
    }

    /// The converted package-facing viewer sequence.
    private var viewerItems: [SSPhotoViewerItem] {
        assets.map(\.ssPhotoViewerItem)
    }

    /// Opens the viewer for an app asset.
    public func present(_ asset: Asset) {
        selectedID.wrappedValue = asset.imageViewerID
        isPresented.wrappedValue = true
    }

    /// Dismisses the viewer through the app-owned binding.
    public func dismiss() {
        isPresented.wrappedValue = false
    }

    /// Wraps the app's screen root with the configured viewer.
    @ViewBuilder
    @MainActor
    public func host<Content: View>(
        @ViewBuilder home: () -> Content
    ) -> some View {
        SSPhotoViewerHost(
            isPresented: isPresented,
            selectedID: selectedID,
            items: viewerItems,
            presentationStyle: policy.presentationStyle.ssPhotoViewerStyle,
            configuration: policy.makeConfiguration(),
            home: home
        )
    }

    /// Registers exactly one app-owned visual source for handoff.
    @ViewBuilder
    @MainActor
    public func source<Content: View>(
        for asset: Asset,
        isHidden: Bool = false,
        readiness: SSPhotoViewerSourceReadiness = .unknown,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .ssPhotoViewerSource(
                id: asset.imageViewerID,
                isHidden: isHidden,
                readiness: readiness
            )
    }

    /// Registers a source with an app-owned preparation overlay.
    @ViewBuilder
    @MainActor
    public func source<Content: View, PreparationOverlay: View>(
        for asset: Asset,
        isHidden: Bool = false,
        readiness: SSPhotoViewerSourceReadiness = .unknown,
        @ViewBuilder preparationOverlay: () -> PreparationOverlay,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .ssPhotoViewerSource(
                id: asset.imageViewerID,
                isHidden: isHidden,
                readiness: readiness,
                preparationOverlay: preparationOverlay
            )
    }
}
