import AVFoundation
import SwiftUI
import SSPhotoViewer

/// Adapter-facing readiness contract for a registered source visual.
///
/// This alias keeps consuming apps on the public adapter boundary; they do not
/// need to import the lower-level ``SSPhotoViewer`` target.
public typealias ImageViewerSourceReadiness = SSPhotoViewerSourceReadiness
/// Adapter-facing hook for authenticated or app-owned image loading.
public typealias ImageViewerImageLoader = SSPhotoViewerImageLoader

/// App-facing media resources. The adapter converts these to package media.
public enum ImageViewerMedia: @unchecked Sendable, Hashable {
    /// An image URL used as identity/metadata; supply its decoded image through
    /// the policy's app-owned image loader.
    case image(URL)
    /// A URL-backed video. AVFoundation performs playback transport.
    case video(URL, posterURL: URL? = nil)
    /// An app-configured asset for authentication or custom resource loading.
    case videoAsset(AVAsset, posterURL: URL? = nil)

    public static func == (lhs: ImageViewerMedia, rhs: ImageViewerMedia) -> Bool {
        switch (lhs, rhs) {
        case let (.image(a), .image(b)): return a == b
        case let (.video(a, ap), .video(b, bp)): return a == b && ap == bp
        case let (.videoAsset(a, ap), .videoAsset(b, bp)): return a === b && ap == bp
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .image(let url): hasher.combine(0); hasher.combine(url)
        case .video(let url, let poster): hasher.combine(1); hasher.combine(url); hasher.combine(poster)
        case .videoAsset(let asset, let poster): hasher.combine(2); hasher.combine(ObjectIdentifier(asset)); hasher.combine(poster)
        }
    }

    fileprivate var ssPhotoViewerMedia: SSPhotoViewerItem.Media {
        switch self {
        case .image(let url): .image(url)
        case .video(let url, let posterURL): .video(url, posterURL: posterURL)
        case .videoAsset(let asset, let posterURL): .videoAsset(asset, posterURL: posterURL)
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
    public var imageLoader: ImageViewerImageLoader?
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
        imageLoader: ImageViewerImageLoader? = nil,
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
        self.imageLoader = imageLoader
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
            imageLoader: imageLoader,
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
    ///
    /// Set `readiness` from the same state that drives `content`. Keep it
    /// reactive: pass `.loading` while the thumbnail is unavailable and change
    /// it to `.ready` in the next render after the thumbnail can be drawn.
    /// `.ready` suppresses the package's preparation overlay; it does not skip
    /// the viewer's own preview-readiness check.
    @ViewBuilder
    @MainActor
    public func source<Content: View>(
        for asset: Asset,
        isHidden: Bool = false,
        /// Describes whether the app-owned source visual is drawable.
        readiness: ImageViewerSourceReadiness = .unknown,
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
    ///
    /// The overlay is used only while `readiness` is not `.ready`. The app still
    /// owns the visual and must update readiness when that visual becomes
    /// available.
    @ViewBuilder
    @MainActor
    public func source<Content: View, PreparationOverlay: View>(
        for asset: Asset,
        isHidden: Bool = false,
        /// Describes whether the app-owned source visual is drawable.
        readiness: ImageViewerSourceReadiness = .unknown,
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
