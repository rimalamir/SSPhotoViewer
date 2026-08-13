import AVFoundation
import AVKit
import SwiftUI
import UIKit

private struct SSPhotoViewerIsZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SSPhotoViewerHiddenSourceIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct SSPhotoViewerPreparingSourceIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    /// A Boolean value that indicates whether the currently displayed media is zoomed.
    ///
    /// Read this value from custom bottom chrome when only part of that chrome
    /// should react to zoom. For example, a Photos-style bottom bar can hide its
    /// thumbnail strip while leaving share and delete actions visible:
    ///
    /// ```swift
    /// @Environment(\.ssPhotoViewerIsZoomed) private var isZoomed
    /// ```
    ///
    /// The package writes this value. Consumers should treat it as read-only.
    var ssPhotoViewerIsZoomed: Bool {
        get { self[SSPhotoViewerIsZoomedKey.self] }
        set { self[SSPhotoViewerIsZoomedKey.self] = newValue }
    }
}

private extension EnvironmentValues {
    var ssPhotoViewerHiddenSourceID: String? {
        get { self[SSPhotoViewerHiddenSourceIDKey.self] }
        set { self[SSPhotoViewerHiddenSourceIDKey.self] = newValue }
    }

    var ssPhotoViewerPreparingSourceID: String? {
        get { self[SSPhotoViewerPreparingSourceIDKey.self] }
        set { self[SSPhotoViewerPreparingSourceIDKey.self] = newValue }
    }
}

/// The kind of media represented by an ``SSPhotoViewerItem``.
public enum SSPhotoViewerMediaKind: Hashable, Sendable {
    /// A still image.
    case image
    /// A video, optionally accompanied by a poster image.
    case video
}

/// The viewer's two user-facing presentation modes.
///
/// The viewer opens in ``minimal`` mode. A single tap toggles to ``detail``,
/// where configured top chrome, bottom chrome, the media strip, and video
/// controls become visible as one coordinated transition.
public enum SSPhotoViewerDisplayMode: Hashable, Sendable {
    /// Media-only presentation with auxiliary chrome hidden.
    case minimal
    /// Media plus the configured auxiliary controls and information.
    case detail
}

/// Readiness reported by the app-owned visual registered for a handoff.
public enum SSPhotoViewerSourceReadiness: Hashable, Sendable {
    /// The source has not reported whether its visual is ready.
    case unknown
    /// The source is still loading its visual.
    case loading
    /// The source visual is already available to display.
    case ready
}

/// Controls how ``SSPhotoViewerHost`` presents the fullscreen viewer.
///
/// Both styles preserve the viewer's visual contract: presentation is the
/// source-to-viewer handoff, dismissal is its reverse, and the viewer content
/// itself does not change. The style only chooses the outer presentation
/// boundary.
public enum SSPhotoViewerPresentationStyle: Hashable, Sendable {
    /// Keeps the viewer in the caller's hierarchy for source-aware handoffs.
    case sameHierarchy
    /// Presents a scene-bound full-screen layer that can cover an active sheet.
    /// The native cover owns only the outer boundary; it must not be paired with
    /// another return-thumbnail dismissal animation.
    case fullScreen
}

/// A stable media value that the viewer can display and page between.
///
/// Identity is the most important part of this type. The same `id` connects a
/// home-screen source view, the fullscreen page, pagination updates, and the
/// return handoff. IDs must therefore be unique and stable for the lifetime of
/// the media object.
public struct SSPhotoViewerItem: Identifiable, Hashable, Sendable {
    /// The remote or local resource used for fullscreen rendering.
    public enum Media: @unchecked Sendable, Hashable {
        /// A still image resource.
        case image(URL)
        /// A video resource and an optional static poster.
        ///
        /// A poster is strongly recommended for immediate thumbnails and
        /// transition surfaces. Playback always uses the video URL.
        case video(URL, posterURL: URL? = nil)
        /// A caller-constructed asset for authenticated or custom resource loading.
        case videoAsset(AVAsset, posterURL: URL? = nil)

        public static func == (lhs: Media, rhs: Media) -> Bool {
            switch (lhs, rhs) {
            case let (.image(a), .image(b)): return a == b
            case let (.video(a, ap), .video(b, bp)): return a == b && ap == bp
            case let (.videoAsset(a, ap), .videoAsset(b, bp)):
                return a === b && ap == bp
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

        /// The URL of the full image or video resource.
        public var sourceURL: URL? {
            switch self {
            case .image(let url), .video(let url, _):
                return url
            case .videoAsset(let asset, _):
                return (asset as? AVURLAsset)?.url
            }
        }

        /// The video's static poster URL, or `nil` for images and posterless videos.
        public var posterURL: URL? {
            if case .video(_, let posterURL) = self {
                return posterURL
            }
            if case .videoAsset(_, let posterURL) = self { return posterURL }
            return nil
        }

        /// The resource's media kind.
        public var kind: SSPhotoViewerMediaKind {
            if case .video = self { return .video }
            return .image
        }

        var isVideo: Bool { kind == .video }
    }

    /// Stable identity shared by the home source and viewer sequence.
    public let id: String
    /// The full-resolution media resource.
    public let media: Media
    /// Optional layout hint. When omitted, the viewer resolves the ratio from
    /// the loaded image or video poster before presenting the page.
    public let aspectRatio: CGFloat?
    /// Optional lightweight preview used by thumbnail strips and source
    /// handoff surfaces. Fullscreen media always uses `media`.
    public let thumbnailURL: URL?
    /// Set this when the thumbnail is an uncropped rendition with the same
    /// orientation and aspect ratio as the full media. The opening handoff can
    /// then use the decoded preview dimensions immediately instead of waiting
    /// for the full-resolution asset to resolve its geometry.
    public let thumbnailPreservesMediaAspectRatio: Bool
    /// A VoiceOver label that describes the media without positional wording.
    public let accessibilityLabel: String?

    /// Creates an item for the fullscreen media sequence.
    ///
    /// - Parameters:
    ///   - id: Stable identity. Do not use a transient array index for remote data.
    ///   - media: The full image or video resource.
    ///   - aspectRatio: Optional width divided by height. Supplying it lets the
    ///     opening animation begin before the full resource is decoded.
    ///   - thumbnailURL: Optional lightweight transition and strip visual.
    ///   - thumbnailPreservesMediaAspectRatio: Set to `true` only when the
    ///     thumbnail is uncropped and has the same orientation and ratio as the
    ///     full media.
    ///   - accessibilityLabel: A concise semantic description for VoiceOver.
    public init(
        id: String,
        media: Media,
        aspectRatio: CGFloat? = nil,
        thumbnailURL: URL? = nil,
        thumbnailPreservesMediaAspectRatio: Bool = false,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.media = media
        self.aspectRatio = aspectRatio
        self.thumbnailURL = thumbnailURL
        self.thumbnailPreservesMediaAspectRatio = thumbnailPreservesMediaAspectRatio
        self.accessibilityLabel = accessibilityLabel
    }

    /// The media URL when the item uses URL-backed image/video content.
    /// Asset-backed videos may not have a URL.
    public var mediaURL: URL? { media.sourceURL }

    /// The media kind without requiring pattern matching on ``media``.
    public var mediaKind: SSPhotoViewerMediaKind { media.kind }

    /// Whether the item is a video.
    public var isVideo: Bool { media.kind == .video }

    /// The best static thumbnail URL known to the item.
    ///
    /// For images this falls back to the full image URL. For videos it uses
    /// ``thumbnailURL`` first and then the video's poster. A posterless video
    /// returns `nil` because its video URL is not an image resource.
    public var preferredThumbnailURL: URL? {
        if let thumbnailURL { return thumbnailURL }
        if let posterURL = media.posterURL { return posterURL }
        if case .image(let url) = media { return url }
        return nil
    }
}

/// One append-only page returned by a viewer pagination request.
public struct SSPhotoViewerPage: Sendable {
    /// New media to append. Duplicate IDs are ignored by the viewer.
    public let items: [SSPhotoViewerItem]
    /// Whether another page can be requested after this page.
    public let hasMore: Bool

    /// Creates a pagination result.
    public init(items: [SSPhotoViewerItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

/// An application-owned action emitted by the package's default or custom chrome.
public enum SSPhotoViewerAction: Sendable {
    /// Save the associated media.
    case save(SSPhotoViewerItem)
    /// Share the associated media.
    case share(SSPhotoViewerItem)
    /// A consumer-defined action identified by a stable string.
    case custom(id: String, item: SSPhotoViewerItem)
}

/// A snapshot of viewer state plus safe commands for custom top and bottom chrome.
///
/// The context is rebuilt as viewer state changes. Do not store it as long-lived
/// application state; render from it and invoke its commands from controls.
public struct SSPhotoViewerChromeContext {
    /// The selected media item.
    public let item: SSPhotoViewerItem
    /// The selected item's index in ``items``.
    public let selectedIndex: Int
    /// The number of currently loaded viewer items.
    public let itemCount: Int
    /// The viewer's complete currently loaded sequence, including appended pages.
    public let items: [SSPhotoViewerItem]
    /// Whether the current media is zoomed beyond its fitted scale.
    public let isZoomed: Bool
    /// Whether the current item is a video.
    public let isVideo: Bool
    /// The active minimal/detail mode.
    public let displayMode: SSPhotoViewerDisplayMode
    /// Current viewer pagination status.
    public let pagination: SSPhotoViewerPaginationState

    private let dismissAction: () -> Void
    private let selectIndexAction: (Int) -> Void
    private let selectIDAction: (String) -> Void
    private let setDisplayModeAction: (SSPhotoViewerDisplayMode) -> Void
    private let requestNextPageAction: () -> Void
    private let performAction: (SSPhotoViewerAction) -> Void

    /// Dismisses through the package's source-return handoff when possible.
    public func dismiss() {
        dismissAction()
    }

    /// Selects an item from ``items`` by index.
    ///
    /// Invalid indices are ignored. The package resets per-page zoom and stops
    /// video playback as selection changes.
    public func select(index: Int) {
        selectIndexAction(index)
    }

    /// Selects an item by stable media ID.
    ///
    /// Use this from custom strips when home and viewer arrays have different
    /// filtering or ordering.
    public func select(id: String) {
        selectIDAction(id)
    }

    /// Changes the viewer's auxiliary chrome mode.
    public func setDisplayMode(_ mode: SSPhotoViewerDisplayMode) {
        setDisplayModeAction(mode)
    }

    /// Toggles between ``SSPhotoViewerDisplayMode/minimal`` and
    /// ``SSPhotoViewerDisplayMode/detail``.
    public func toggleDisplayMode() {
        setDisplayModeAction(displayMode == .minimal ? .detail : .minimal)
    }

    /// Requests the next viewer page immediately when one is available.
    ///
    /// Normal paging and the built-in strip prefetch automatically. This
    /// command exists for custom strips that can reach their end independently.
    public func requestNextPage() {
        requestNextPageAction()
    }

    /// Sends an application-owned action through the configuration handler.
    public func perform(_ action: SSPhotoViewerAction) {
        performAction(action)
    }

    init(
        item: SSPhotoViewerItem,
        selectedIndex: Int,
        itemCount: Int,
        items: [SSPhotoViewerItem],
        isZoomed: Bool,
        displayMode: SSPhotoViewerDisplayMode,
        pagination: SSPhotoViewerPaginationState,
        dismiss: @escaping () -> Void,
        selectIndex: @escaping (Int) -> Void,
        selectID: @escaping (String) -> Void,
        setDisplayMode: @escaping (SSPhotoViewerDisplayMode) -> Void,
        requestNextPage: @escaping () -> Void,
        perform: @escaping (SSPhotoViewerAction) -> Void
    ) {
        self.item = item
        self.selectedIndex = selectedIndex
        self.itemCount = itemCount
        self.items = items
        self.isZoomed = isZoomed
        self.isVideo = item.media.isVideo
        self.displayMode = displayMode
        self.pagination = pagination
        self.dismissAction = dismiss
        self.selectIndexAction = selectIndex
        self.selectIDAction = selectID
        self.setDisplayModeAction = setDisplayMode
        self.requestNextPageAction = requestNextPage
        self.performAction = perform
    }
}

/// Current pagination state exposed to custom chrome.
public struct SSPhotoViewerPaginationState: Hashable, Sendable {
    /// Whether the viewer is waiting for ``SSPhotoViewerConfiguration/pageLoader``.
    public let isLoading: Bool
    /// Whether the latest page says more media is available.
    public let hasMore: Bool
    /// The next page number the viewer will request.
    ///
    /// Initial host items are page `0`; loader requests begin at page `1`.
    public let nextPageNumber: Int

    init(isLoading: Bool, hasMore: Bool, nextPageNumber: Int) {
        self.isLoading = isLoading
        self.hasMore = hasMore
        self.nextPageNumber = nextPageNumber
    }
}

/// Caller-owned progress for a viewer sequence that can also be loaded eagerly.
///
/// Pass this value to ``SSPhotoViewerHost`` when the application may append
/// media independently of the viewer's ``SSPhotoViewerConfiguration/pageLoader``.
/// Advancing the cursor tells the viewer which page is genuinely next and lets
/// it cancel an older in-flight request that the application has already
/// satisfied.
public struct SSPhotoViewerPaginationCursor: Hashable, Sendable {
    /// The next page number that has not yet been accepted by the caller.
    ///
    /// Initial host items are page `0`, so the initial value is normally `1`.
    public let nextPageNumber: Int
    /// Whether the caller's data source can provide another page.
    public let hasMore: Bool

    /// Creates caller-owned pagination progress.
    public init(nextPageNumber: Int, hasMore: Bool) {
        self.nextPageNumber = max(1, nextPageNumber)
        self.hasMore = hasMore
    }
}

/// A package-independent summary of video playback state.
public enum SSPhotoViewerPlaybackState: Hashable, Sendable {
    /// Playback is stopped or paused.
    case paused
    /// Playback is waiting for enough media data or another system condition.
    case waiting
    /// Playback is actively advancing.
    case playing
}

/// Live video transport state and actions supplied to custom video chrome.
public struct SSPhotoViewerVideoControlsContext {
    /// The video item these controls currently operate on.
    public let item: SSPhotoViewerItem
    /// The underlying AVFoundation status for advanced integrations.
    public let timeControlStatus: AVPlayer.TimeControlStatus
    /// Whether audio output is muted.
    public let isMuted: Bool
    /// Current playback position in seconds.
    public let currentTime: Double
    /// Seekable duration in seconds, or `0` until duration is known.
    public let duration: Double

    private let togglePlaybackAction: () -> Void
    private let toggleMuteAction: () -> Void
    private let seekAction: (Double) -> Void

    /// A framework-independent playback state for choosing custom icons.
    public var playbackState: SSPhotoViewerPlaybackState {
        switch timeControlStatus {
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waiting
        case .playing: .playing
        @unknown default: .paused
        }
    }

    /// Whether the player is actively playing.
    public var isPlaying: Bool { playbackState == .playing }

    /// Whether a play/pause button should currently display its pause action.
    public var showsPauseAction: Bool {
        timeControlStatus != .paused
    }

    /// Toggles between playing and paused states.
    public func togglePlayback() {
        togglePlaybackAction()
    }

    /// Toggles the player's muted state.
    public func toggleMute() {
        toggleMuteAction()
    }

    /// Seeks to an absolute playback time.
    ///
    /// Values are clamped by the underlying player to its seekable range.
    public func seek(to seconds: Double) {
        seekAction(seconds)
    }

    init(
        item: SSPhotoViewerItem,
        timeControlStatus: AVPlayer.TimeControlStatus,
        isMuted: Bool,
        currentTime: Double,
        duration: Double,
        togglePlayback: @escaping () -> Void,
        toggleMute: @escaping () -> Void,
        seek: @escaping (Double) -> Void
    ) {
        self.item = item
        self.timeControlStatus = timeControlStatus
        self.isMuted = isMuted
        self.currentTime = currentTime
        self.duration = duration
        self.togglePlaybackAction = togglePlayback
        self.toggleMuteAction = toggleMute
        self.seekAction = seek
    }
}

/// The destination used when the current media has no mounted source view.
public enum SSPhotoViewerFallbackDestination: Equatable, Sendable {
    /// Return to the live source when available; otherwise continue just beyond
    /// the last visible source in the dismissal direction.
    case source
    /// Always use a point just beyond the last mounted source view.
    case offscreenAfterLastVisible
    /// Return to a caller-supplied global-coordinate rectangle.
    ///
    /// This is useful for a persistent avatar or a non-scrolling media tray.
    case fixed(CGRect)
}

/// Loads viewer pages numbered from `1` upward.
public typealias SSPhotoViewerPageLoader = (Int) async -> SSPhotoViewerPage

/// Loads an image for the viewer. The app can provide authorization, its own
/// cache, decoding policy, or signed-request refresh at this boundary.
public typealias SSPhotoViewerImageLoader = (URL) async -> UIImage?

/// Performs an app-owned, memory-only lookup used to seed a transition.
///
/// The package does not cache, retain, evict, decode, or fetch through this
/// closure. The returned image is only a transient render seed; the async
/// loader remains responsible for the authoritative media value.
public typealias SSPhotoViewerCachedImageLookup = (URL) -> UIImage?

/// Builds media-aware top or bottom chrome.
public typealias SSPhotoViewerChromeBuilder = (SSPhotoViewerChromeContext) -> AnyView

/// Builds controls for the currently selected video player.
public typealias SSPhotoViewerVideoControlsBuilder = (SSPhotoViewerVideoControlsContext) -> AnyView

/// Customizes pagination, chrome, actions, and fallback handoff behavior.
///
/// `SSPhotoViewerConfiguration` is a value. Build it once from stable app
/// dependencies where practical; closures may capture repositories or feature
/// actions, but rendering state should come from the supplied contexts.
public struct SSPhotoViewerConfiguration {
    /// App-owned image loader. The package does not perform networking or
    /// maintain an image cache; return the decoded image from the app's media
    /// pipeline, including authorization and caching as needed.
    public var imageLoader: SSPhotoViewerImageLoader?
    /// Optional app-owned memory lookup used to avoid a blank opening frame.
    /// This is not a package cache and must not perform I/O.
    public var cachedImageLookup: SSPhotoViewerCachedImageLookup?
    /// Extends the viewer sequence as paging or the thumbnail strip approaches
    /// the current boundary.
    ///
    /// Initial `items` are page `0`; requests begin at page `1` and are
    /// monotonic. The BYOH home owns its own data display. When the returned
    /// media should also appear on home, append it to home and viewer data
    /// before returning the page so newly loaded items can register source
    /// geometry when they become visible. If the caller also loads pages
    /// eagerly, pass ``SSPhotoViewerPaginationCursor`` to the host so both
    /// paths share the same next-page position.
    public var pageLoader: SSPhotoViewerPageLoader?
    /// Return behavior when no currently mounted source exists.
    public var fallbackDestination: SSPhotoViewerFallbackDestination
    /// Initial minimal/detail mode. The default is ``SSPhotoViewerDisplayMode/minimal``.
    public var initialDisplayMode: SSPhotoViewerDisplayMode
    /// Whether the package supplies its top bar when no custom top bar exists.
    public var showsDefaultTopBar: Bool
    /// Whether the package supplies its bottom strip/actions when no custom bar exists.
    public var showsDefaultBottomBar: Bool
    /// Whether the default bottom bar includes the pagination strip.
    ///
    /// This is independent of ``showsVideoControls`` and the default action
    /// bar. The default is `true`.
    public var showsDefaultPaginationStrip: Bool
    /// Whether the default bottom bar includes save/share/action controls.
    ///
    /// The default is `true`.
    public var showsDefaultActionBar: Bool
    /// Whether video transport controls are shown in detail mode.
    public var showsVideoControls: Bool
    /// Static media-independent top chrome.
    ///
    /// ``topBarBuilder`` takes precedence when both are supplied.
    public var topBar: AnyView?
    /// Static media-independent bottom chrome.
    ///
    /// ``bottomBarBuilder`` takes precedence when both are supplied.
    public var bottomBar: AnyView?
    /// Media-aware top chrome rebuilt with current viewer state.
    public var topBarBuilder: SSPhotoViewerChromeBuilder?
    /// Media-aware bottom chrome rebuilt with current viewer state.
    public var bottomBarBuilder: SSPhotoViewerChromeBuilder?
    /// Custom play/pause, seek, and mute controls for the active video.
    public var videoControlsBuilder: SSPhotoViewerVideoControlsBuilder?
    /// Handles default and custom package actions.
    public var onAction: (SSPhotoViewerAction) -> Void

    /// Creates a viewer configuration.
    ///
    /// Prefer the typed ``customTopBar(_:)``, ``customBottomBar(_:)``, and
    /// ``customVideoControls(_:)`` modifiers when you do not otherwise need to
    /// store type-erased `AnyView` values.
    public init(
        pageLoader: SSPhotoViewerPageLoader? = nil,
        imageLoader: SSPhotoViewerImageLoader? = nil,
        cachedImageLookup: SSPhotoViewerCachedImageLookup? = nil,
        fallbackDestination: SSPhotoViewerFallbackDestination = .source,
        initialDisplayMode: SSPhotoViewerDisplayMode = .minimal,
        showsDefaultTopBar: Bool = true,
        showsDefaultBottomBar: Bool = true,
        showsDefaultPaginationStrip: Bool = true,
        showsDefaultActionBar: Bool = true,
        showsVideoControls: Bool = true,
        topBar: AnyView? = nil,
        bottomBar: AnyView? = nil,
        topBarBuilder: SSPhotoViewerChromeBuilder? = nil,
        bottomBarBuilder: SSPhotoViewerChromeBuilder? = nil,
        videoControlsBuilder: SSPhotoViewerVideoControlsBuilder? = nil,
        onAction: @escaping (SSPhotoViewerAction) -> Void = { _ in }
    ) {
        self.pageLoader = pageLoader
        self.imageLoader = imageLoader
        self.cachedImageLookup = cachedImageLookup
        self.fallbackDestination = fallbackDestination
        self.initialDisplayMode = initialDisplayMode
        self.showsDefaultTopBar = showsDefaultTopBar
        self.showsDefaultBottomBar = showsDefaultBottomBar
        self.showsDefaultPaginationStrip = showsDefaultPaginationStrip
        self.showsDefaultActionBar = showsDefaultActionBar
        self.showsVideoControls = showsVideoControls
        self.topBar = topBar
        self.bottomBar = bottomBar
        self.topBarBuilder = topBarBuilder
        self.bottomBarBuilder = bottomBarBuilder
        self.videoControlsBuilder = videoControlsBuilder
        self.onAction = onAction
    }

    /// Returns a copy using strongly typed media-aware top chrome.
    public func customTopBar<Content: View>(
        @ViewBuilder _ builder: @escaping (SSPhotoViewerChromeContext) -> Content
    ) -> Self {
        var copy = self
        copy.topBarBuilder = { AnyView(builder($0)) }
        return copy
    }

    /// Returns a copy using strongly typed media-aware bottom chrome.
    public func customBottomBar<Content: View>(
        @ViewBuilder _ builder: @escaping (SSPhotoViewerChromeContext) -> Content
    ) -> Self {
        var copy = self
        copy.bottomBarBuilder = { AnyView(builder($0)) }
        return copy
    }

    /// Returns a copy using strongly typed controls for active videos.
    public func customVideoControls<Content: View>(
        @ViewBuilder _ builder: @escaping (SSPhotoViewerVideoControlsContext) -> Content
    ) -> Self {
        var copy = self
        copy.videoControlsBuilder = { AnyView(builder($0)) }
        return copy
    }
}

/// Places a fullscreen viewer in the same SwiftUI hierarchy as any home screen.
///
/// This same-hierarchy composition is what lets the package animate between a
/// live source rectangle and fullscreen media without a competing sheet or
/// `fullScreenCover` transition. The host does not prescribe a grid, list,
/// message layout, navigation structure, or data repository.
public struct SSPhotoViewerHost<Home: View>: View {
    @Binding private var isPresented: Bool
    @Binding private var selectedIndex: Int
    private let items: [SSPhotoViewerItem]
    private let paginationCursor: SSPhotoViewerPaginationCursor?
    private let presentationStyle: SSPhotoViewerPresentationStyle
    private let configuration: SSPhotoViewerConfiguration
    private let home: Home

    @State private var sourceFrames: [String: CGRect] = [:]
    @State private var sourceReadiness: [String: SSPhotoViewerSourceReadiness] = [:]
    @State private var presentationSourceFrames: [String: CGRect] = [:]
    @State private var fullScreenPresentationReady = false
    @State private var hiddenSourceID: String?
    @State private var preparingSourceID: String?
    @State private var viewerOwnsSource = false
    @State private var openingPreparationTask: Task<Void, Never>?

    /// Creates a host whose selection is represented by an array index.
    ///
    /// - Parameters:
    ///   - isPresented: Controls whether the viewer exists above `home`.
    ///   - selectedIndex: Index in the viewer's `items`, not necessarily an
    ///     index in the home collection.
    ///   - items: Initial and externally appended viewer sequence.
    ///   - paginationCursor: Optional caller-owned progress for eager loading.
    ///   - configuration: Pagination and customization behavior.
    ///   - home: Any caller-owned home interface.
    public init(
        isPresented: Binding<Bool>,
        selectedIndex: Binding<Int>,
        items: [SSPhotoViewerItem],
        paginationCursor: SSPhotoViewerPaginationCursor? = nil,
        presentationStyle: SSPhotoViewerPresentationStyle = .sameHierarchy,
        configuration: SSPhotoViewerConfiguration = .init(),
        @ViewBuilder home: () -> Home
    ) {
        // `home` is responsible for rendering and paginating its own data;
        // `items` is the media snapshot supplied to the fullscreen viewer.
        _isPresented = isPresented
        _selectedIndex = selectedIndex
        self.items = items
        self.paginationCursor = paginationCursor
        self.presentationStyle = presentationStyle
        self.configuration = configuration
        self.home = home()
        // The opening hero must claim the source only after its visual is ready.
        // This also covers hosts that start with the viewer already presented.
        _hiddenSourceID = State(initialValue: nil)
    }

    /// Creates a host whose selection is represented by stable media identity.
    ///
    /// This initializer is recommended when the home and viewer use different
    /// filtering or ordering. `selectedID` must identify an item in `items`
    /// before `isPresented` becomes `true`. If pagination selects newly loaded
    /// items, update the bound `items` collection before the loader returns.
    /// Externally appended items are merged while the viewer is presented;
    /// provide `paginationCursor` when those eager updates coexist with a page
    /// loader.
    public init(
        isPresented: Binding<Bool>,
        selectedID: Binding<String>,
        items: [SSPhotoViewerItem],
        paginationCursor: SSPhotoViewerPaginationCursor? = nil,
        presentationStyle: SSPhotoViewerPresentationStyle = .sameHierarchy,
        configuration: SSPhotoViewerConfiguration = .init(),
        @ViewBuilder home: () -> Home
    ) {
        #if DEBUG
        if !items.isEmpty,
           !items.contains(where: { $0.id == selectedID.wrappedValue }) {
            assertionFailure(
                "SSPhotoViewer selectedID must identify an item before presentation"
            )
        }
        #endif

        let index = Binding<Int>(
            get: {
                items.firstIndex(where: { $0.id == selectedID.wrappedValue }) ?? 0
            },
            set: { newIndex in
                guard items.indices.contains(newIndex) else { return }
                selectedID.wrappedValue = items[newIndex].id
            }
        )

        self.init(
            isPresented: isPresented,
            selectedIndex: index,
            items: items,
            paginationCursor: paginationCursor,
            presentationStyle: presentationStyle,
            configuration: configuration,
            home: home
        )
    }

    public var body: some View {
        Group {
            switch presentationStyle {
            case .sameHierarchy:
                homeWithViewerOverlay
            case .fullScreen:
                homeWithFullScreenViewer
            }
        }
        .onChange(of: isPresented) { _, presented in
            // Source views stay in the hierarchy so their live frames remain
            // available for the hero transition. Only their visual layer is
            // hidden while the viewer owns the selected media, then restored after the
            // viewer completes its return handoff and dismisses.
            // Keep the source visible until the opening hero has loaded its
            // visual. Hiding it at presentation time exposes the hero's
            // initial black placeholder for one frame on a cold cache.
            hiddenSourceID = nil
            viewerOwnsSource = false
            if presented {
                fullScreenPresentationReady = presentationStyle != .fullScreen
                presentationSourceFrames = sourceFrames
                beginOpeningPreparation(for: sourceID(for: selectedIndex))
            } else {
                fullScreenPresentationReady = false
                endOpeningPreparation()
            }
        }
        .onChange(of: selectedIndex) { _, index in
            // `selectedIndex` and `isPresented` are commonly mutated in the
            // same tap. Do not let that initial index change hide the source
            // before the opening hero has actually claimed its pixels.
            guard isPresented else { return }
            if viewerOwnsSource {
                hiddenSourceID = sourceID(for: index)
            } else {
                beginOpeningPreparation(for: sourceID(for: index))
            }
        }
        .onPreferenceChange(SSPhotoViewerSourceFrameKey.self) {
            // Preferences represent currently mounted lazy-grid cells. Replace
            // the registry so scrolled-off thumbnails cannot become ghost
            // return destinations. During a large LazyVGrid diff SwiftUI can
            // briefly publish an empty preference before the mounted cells
            // report their new frames; do not erase a valid handoff target in
            // that transient frame.
            let validFrames = $0.filter { _, frame in
                frame.width > 0 && frame.height > 0 &&
                frame.minX.isFinite && frame.minY.isFinite
            }
            if !validFrames.isEmpty {
                sourceFrames = validFrames
            }
        }
        .onPreferenceChange(SSPhotoViewerSourceReadinessKey.self) {
            sourceReadiness.merge($0, uniquingKeysWith: { _, latest in latest })
            if let preparingSourceID,
               $0[preparingSourceID] == .ready {
                endOpeningPreparation()
            }
        }
        .onDisappear {
            endOpeningPreparation()
        }
    }

    private var homeWithViewerOverlay: some View {
        home
            .environment(\.ssPhotoViewerHiddenSourceID, hiddenSourceID)
            .environment(
                \.ssPhotoViewerPreparingSourceID,
                preparingSourceID
            )
            // An overlay keeps same-hierarchy handoffs while remaining
            // layout-neutral for the caller's home view.
            .overlay {
                if isPresented {
                    viewerContent
                        .transition(.identity)
                }
            }
    }

    private var homeWithFullScreenViewer: some View {
        home
            .environment(\.ssPhotoViewerHiddenSourceID, hiddenSourceID)
            .environment(
                \.ssPhotoViewerPreparingSourceID,
                preparingSourceID
            )
            // This is attached to the caller's current scene/presentation
            // hierarchy, not to a global UIWindow. It can therefore cover a
            // sheet while remaining safe for Stage Manager and multiwindow.
            .fullScreenCover(
                isPresented: $isPresented,
                onDismiss: {
                    endOpeningPreparation()
                }
            ) {
                Group {
                    if fullScreenPresentationReady {
                        viewerContent
                    } else {
                        Color.clear
                            .ignoresSafeArea()
                    }
                }
                .onAppear {
                    // Keep the native cover's entrance visually empty. The
                    // shared opening hero starts only after the cover has
                    // finished moving, so the image cannot slide in from the
                    // bottom at the same time as the thumbnail handoff.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        guard isPresented else { return }
                        fullScreenPresentationReady = true
                    }
                }
                    // Let the shared viewer backdrop own the gradual fade
                    // during opening, interactive dismissal, and return. The
                    // system cover must not add an opaque presentation layer.
                    .presentationBackground(.clear)
                    // The viewer owns the source-aware opening and dismissal
                    // handoffs. The native cover must not add a second slide.
                    .interactiveDismissDisabled(true)
            }
            // Keep the native cover as a window-covering container while
            // leaving the visual transition to the shared viewer hero.
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
    }

    private var viewerContent: some View {
        SSPhotoViewer(
            items: items,
            paginationCursor: paginationCursor,
            selectedIndex: $selectedIndex,
            sourceFrames: sourceFrames,
            presentationSourceFrames: presentationSourceFrames,
            configuration: configuration,
            usesSourceHandoff: true,
            onOpeningReady: {
                endOpeningPreparation()
                viewerOwnsSource = true
                hiddenSourceID = sourceID(for: selectedIndex)
            },
            onDismiss: {
                finishViewerDismissal()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea()
        .zIndex(100)
    }

    private func finishViewerDismissal() {
        endOpeningPreparation()

        isPresented = false
    }

    private func sourceID(for index: Int) -> String? {
        guard items.indices.contains(index) else { return nil }
        return items[index].id
    }

    private func beginOpeningPreparation(for id: String?) {
        endOpeningPreparation()

        guard let id,
              let frame = sourceFrames[id],
              frame.width > 0,
              frame.height > 0
        else { return }

        guard sourceReadiness[id] != .ready else { return }
        preparingSourceID = id
        openingPreparationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled,
                  isPresented,
                  !viewerOwnsSource,
                  preparingSourceID == id
            else { return }

            // A failed visual or geometry request must not leave the source
            // indefinitely busy beneath an unusable viewer.
            preparingSourceID = nil
            isPresented = false
            openingPreparationTask = nil
        }
    }

    private func endOpeningPreparation() {
        openingPreparationTask?.cancel()
        openingPreparationTask = nil
        preparingSourceID = nil
    }
}

/// A reusable horizontal thumbnail strip for caller-owned gallery, message,
/// or detail layouts.
///
/// The strip owns only its horizontal scrolling and selection binding. It does
/// not ignore safe areas, add safe-area insets, present a viewer, or change the
/// layout of its parent. Use ``SSPhotoViewerHost`` separately when a selected
/// item should open the fullscreen viewer.
public struct SSPhotoViewerStrip: View {
    /// The media represented by the strip, in display order.
    public let items: [SSPhotoViewerItem]
    /// The selected item index. Invalid values are ignored by the strip.
    @Binding public var selectedIndex: Int
    /// Called when the selected item reaches the end of the current sequence.
    /// Use this to append more items in a caller-owned data source.
    public var onRequestNextPage: (() -> Void)?
    /// App-owned image loader for URL-backed thumbnails and posters.
    ///
    /// The strip never performs implicit networking or caching. When this is
    /// `nil`, URL-backed thumbnail surfaces remain placeholders.
    public var imageLoader: SSPhotoViewerImageLoader?
    /// Optional app-owned memory-only lookup for immediate thumbnail seeding.
    public var cachedImageLookup: SSPhotoViewerCachedImageLookup?

    private let thumbnailHeight: CGFloat
    private let spacing: CGFloat

    /// Creates a standalone thumbnail strip.
    ///
    /// The view has no fixed outer height beyond its thumbnail row and can be
    /// placed inside any caller-owned safe-area layout.
    public init(
        items: [SSPhotoViewerItem],
        selectedIndex: Binding<Int>,
        thumbnailHeight: CGFloat = 40,
        spacing: CGFloat = 1,
        onRequestNextPage: (() -> Void)? = nil,
        imageLoader: SSPhotoViewerImageLoader? = nil,
        cachedImageLookup: SSPhotoViewerCachedImageLookup? = nil
    ) {
        self.items = items
        _selectedIndex = selectedIndex
        self.thumbnailHeight = max(1, thumbnailHeight)
        self.spacing = max(0, spacing)
        self.onRequestNextPage = onRequestNextPage
        self.imageLoader = imageLoader
        self.cachedImageLookup = cachedImageLookup
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        Button {
                            guard items.indices.contains(index) else { return }
                            selectedIndex = index
                            if index == items.index(before: items.endIndex) {
                                onRequestNextPage?()
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        } label: {
                            SSPhotoViewerThumbnailSurface(
                                item: item,
                                imageLoader: imageLoader,
                                cachedImageLookup: cachedImageLookup
                            )
                                .frame(
                                    width: thumbnailHeight * 12 / 16,
                                    height: thumbnailHeight
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 1,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 1,
                                        style: .continuous
                                    )
                                    .stroke(
                                        index == selectedIndex
                                            ? Color.white
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                                }
                        }
                        .id(item.id)
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            item.accessibilityLabel ?? "Media \(index + 1)"
                        )
                        .accessibilityValue(
                            index == selectedIndex ? "Selected" : ""
                        )
                        .onAppear {
                            if index == items.index(before: items.endIndex) {
                                onRequestNextPage?()
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: thumbnailHeight)
            .onAppear {
                guard items.indices.contains(selectedIndex) else { return }
                proxy.scrollTo(items[selectedIndex].id, anchor: .center)
            }
            .onChange(of: selectedIndex) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
        }
    }
}

public extension View {
    /// Registers this view as a source/destination for a media handoff.
    ///
    /// Apply the modifier to the visual region itself—not an entire row—using
    /// the exact same stable ID as ``SSPhotoViewerItem/id``. The package reads
    /// the view's live global frame while it is mounted. Lazy containers are
    /// supported; an item that is no longer mounted uses the configured fallback
    /// destination on dismissal.
    ///
    /// - Parameters:
    ///   - id: Stable ID shared with the viewer item.
    ///   - isHidden: An app-owned hiding condition in addition to the package's
    ///     automatic source ownership. Most integrations leave this `false`.
    ///   - readiness: Whether the app-owned source visual is already available.
    func ssPhotoViewerSource(
        id: String,
        isHidden: Bool = false,
        readiness: SSPhotoViewerSourceReadiness = .unknown
    ) -> some View {
        modifier(
            SSPhotoViewerSourceModifier(
                id: id,
                isHidden: isHidden,
                readiness: readiness,
                preparationOverlay: nil
            )
        )
    }

    /// Registers a handoff source with an app-defined preparation overlay.
    ///
    /// The overlay appears only after presentation is requested and before the
    /// preview hero takes ownership. It is removed on success, cancellation,
    /// timeout, and view disappearance. Use this overload to match a product's
    /// loading language without coupling the home layout to viewer internals.
    func ssPhotoViewerSource<PreparationOverlay: View>(
        id: String,
        isHidden: Bool = false,
        readiness: SSPhotoViewerSourceReadiness = .unknown,
        @ViewBuilder preparationOverlay: () -> PreparationOverlay
    ) -> some View {
        modifier(
            SSPhotoViewerSourceModifier(
                id: id,
                isHidden: isHidden,
                readiness: readiness,
                preparationOverlay: AnyView(preparationOverlay())
            )
        )
    }
}

private struct SSPhotoViewerSourceModifier: ViewModifier {
    let id: String
    let isHidden: Bool
    let readiness: SSPhotoViewerSourceReadiness
    let preparationOverlay: AnyView?

    @Environment(\.ssPhotoViewerHiddenSourceID) private var hiddenSourceID
        @Environment(\.ssPhotoViewerPreparingSourceID) private var preparingSourceID

    func body(content: Content) -> some View {
        content
            // Opacity does not remove layout or geometry preferences, so the
            // package can keep using the source frame without coupling the
            // home view to the viewer's internal handoff state.
            .opacity(isHidden || hiddenSourceID == id ? 0 : 1)
            .overlay {
                if !isHidden,
                   hiddenSourceID != id,
                   readiness != .ready,
                   preparingSourceID == id {
                    if let preparationOverlay {
                        preparationOverlay
                            .transition(.opacity)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                            .padding(9)
                            .background(.black.opacity(0.52), in: Circle())
                            .accessibilityLabel("Opening media")
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: preparingSourceID == id)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SSPhotoViewerSourceFrameKey.self,
                        value: [id: proxy.frame(in: .global)]
                    )
                }
            }
            .preference(
                key: SSPhotoViewerSourceReadinessKey.self,
                value: [id: readiness]
            )
    }
}

private struct SSPhotoViewerSourceReadinessKey: PreferenceKey {
    static let defaultValue: [String: SSPhotoViewerSourceReadiness] = [:]

    static func reduce(
        value: inout [String: SSPhotoViewerSourceReadiness],
        nextValue: () -> [String: SSPhotoViewerSourceReadiness]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SSPhotoViewerSourceFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct SSPhotoViewerStripFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
