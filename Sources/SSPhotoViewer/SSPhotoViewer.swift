import AVFoundation
import AVKit
import CryptoKit
import ImageIO
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

        fileprivate var isVideo: Bool { kind == .video }
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

/// Cache controls intended for sample apps and deterministic UI testing.
/// Call once from the app entry point when a fresh media run is required.
public enum SSPhotoViewerCache {
    /// Removes decoded images, on-device image data, and shared URL responses.
    ///
    /// This is intended for deterministic tests and sample applications. A
    /// production app should normally let the cache work across presentations.
    /// Call it at most once during app launch when a cold-cache run is required.
    @MainActor
    public static func reset() {
        SSPhotoViewerImageCache.images.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        Task {
            await SSPhotoViewerDiskImageCache.shared.removeAll()
        }
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

    fileprivate init(
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

    fileprivate init(isLoading: Bool, hasMore: Bool, nextPageNumber: Int) {
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

    fileprivate init(
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
        imageLoader: SSPhotoViewerImageLoader? = nil
    ) {
        self.items = items
        _selectedIndex = selectedIndex
        self.thumbnailHeight = max(1, thumbnailHeight)
        self.spacing = max(0, spacing)
        self.onRequestNextPage = onRequestNextPage
        self.imageLoader = imageLoader
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
                                imageLoader: imageLoader
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

private struct SSPhotoViewerStripFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SSPhotoViewer: View {
    let items: [SSPhotoViewerItem]
    let paginationCursor: SSPhotoViewerPaginationCursor?
    @Binding var selectedIndex: Int
    let sourceFrames: [String: CGRect]
    let presentationSourceFrames: [String: CGRect]
    let configuration: SSPhotoViewerConfiguration
    let usesSourceHandoff: Bool
    let onOpeningReady: () -> Void
    let onDismiss: () -> Void

    @State private var loadedItems: [SSPhotoViewerItem]
    // The strip emits geometry updates while it is moving. Keep the ID ->
    // index lookup incremental so those updates do not rebuild a dictionary
    // for the entire 1,000-item sequence on every frame.
    @State private var loadedIndexByID: [String: Int]
    @State private var zoom: [String: ZoomState]
    @State private var horizontalDrag: CGFloat = 0
    @State private var horizontalPanOffset: CGFloat = 0
    @State private var verticalDrag: CGFloat = 0
    @State private var verticalPanOffset: CGFloat = 0
    @State private var activeVerticalDrag: CGFloat = 0
    @State private var zoomPagingStartTranslation: CGFloat = 0
    @State private var zoomedVerticalPanPhase = false
    @State private var interaction: Interaction = .idle
    @State private var returningFrame: ReturnFrame?
    @State private var lastPanTranslation: CGSize = .zero
    @State private var liveZoomPanOffset: CGSize = .zero
    @State private var isDismissing = false
    @State private var dismissalBackdropOpacity: Double = 1
    @State private var returnHeroReady = false
    @State private var resolvedAspectRatios: [String: CGFloat] = [:]
    @State private var returnDestination: CGRect?
    @State private var isOpening = false
    @State private var openingFrame: ReturnFrame?
    @State private var openingDestination: CGRect?
    @State private var openingHeroReady = false
    @State private var openingAnimationStarted = false
    @State private var openingAnimationCompleted = false
    @State private var fullscreenMediaReadyID: String?
    @State private var openingBackdropOpacity: Double = 0
    @State private var detailProgress: CGFloat = 0
    @State private var hasMorePages = true
    @State private var nextPageNumber = 1
    @State private var pageLoadingTask: Task<Void, Never>?
    @State private var activePageNumber: Int?
    @State private var stripFrames: [String: CGRect] = [:]
    @State private var stripIsDragging = false
    @State private var stripViewportWidth: CGFloat = 0
    @State private var stripVisualIndex: Int?
    @State private var stripSettlingTask: Task<Void, Never>?
    @State private var stripIsSettling = false
    @State private var activeVideoPlayer: AVPlayer?
    @State private var activeVideoPlayerID: String?
    @State private var pageIsSettling = false

    private let movingPageSpacing: CGFloat = 12
    private let dismissalThreshold: CGFloat = 260
    private let maximumDismissalCornerRadius: CGFloat = 8
    private let detailModeCornerRadius: CGFloat = 8
    private let pageAnimationDuration = 0.28
    private let openingAnimationDuration = 0.24
    private let openingCompletionDelay = 0.24

    private var openingAnimation: Animation {
        .timingCurve(
            0.20,
            0.75,
            0.20,
            1.0,
            duration: openingAnimationDuration
        )
    }

    init(
        items: [SSPhotoViewerItem],
        paginationCursor: SSPhotoViewerPaginationCursor?,
        selectedIndex: Binding<Int>,
        sourceFrames: [String: CGRect],
        presentationSourceFrames: [String: CGRect],
        configuration: SSPhotoViewerConfiguration,
        usesSourceHandoff: Bool,
        onOpeningReady: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.paginationCursor = paginationCursor
        _selectedIndex = selectedIndex
        self.sourceFrames = sourceFrames
        self.presentationSourceFrames = presentationSourceFrames
        self.configuration = configuration
        self.usesSourceHandoff = usesSourceHandoff
        self.onOpeningReady = onOpeningReady
        self.onDismiss = onDismiss
        _loadedItems = State(initialValue: items)
        _loadedIndexByID = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }
            )
        )
        _zoom = State(initialValue: Dictionary(uniqueKeysWithValues: items.map { ($0.id, ZoomState()) }))
        _detailProgress = State(
            initialValue: configuration.initialDisplayMode == .detail ? 1 : 0
        )
        _hasMorePages = State(initialValue: paginationCursor?.hasMore ?? true)
        _nextPageNumber = State(
            initialValue: paginationCursor?.nextPageNumber ?? 1
        )

        let initialItem = items.indices.contains(selectedIndex.wrappedValue)
            ? items[selectedIndex.wrappedValue]
            : nil
        let initialSourceFrame = initialItem.flatMap { sourceFrames[$0.id] }
        if let initialItem, let initialSourceFrame,
           initialSourceFrame.width > 0, initialSourceFrame.height > 0 {
            _isOpening = State(initialValue: true)
            _openingFrame = State(
                initialValue: ReturnFrame(
                    item: initialItem,
                    frame: initialSourceFrame,
                    cornerRadius: 1
                )
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(backgroundOpacity)
                    .ignoresSafeArea()
                    // Keep the viewer backdrop in place until the return hero
                    // owns the pixels. Removing it when the frame is merely
                    // allocated exposes the home for one frame and flickers.
                    .opacity(returningFrame == nil || !returnHeroReady ? 1 : 0)

                pager(size: proxy.size)
                    .opacity(!isOpening &&
                        (returningFrame == nil || !returnHeroReady) ? 1 : 0)
                    .contentShape(Rectangle())
                    // Double tap owns the sequence when present. The single
                    // tap branch is evaluated only after the double-tap
                    // recognizer fails, so detail/minimal mode cannot consume
                    // the first half of a zoom gesture.
                    .highPriorityGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                guard interaction == .idle,
                                      !isOpening,
                                      returningFrame == nil
                                else { return }

                                toggleZoom(
                                    at: value.location,
                                    screen: proxy.size
                                )
                            }
                            .exclusively(before:
                                SpatialTapGesture(count: 1)
                                    .onEnded { _ in
                                        guard interaction == .idle,
                                              !isOpening,
                                              returningFrame == nil
                                        else { return }

                                        setDisplayMode(
                                            detailProgress > 0.5
                                                ? .minimal
                                                : .detail
                                        )
                                    }
                            )
                    )

                if let openingFrame {
                    openingHero(openingFrame, screen: proxy.frame(in: .global))
                        .opacity(openingHeroReady ? 1 : 0)
                }

                if let returningFrame {
                    returnHero(returningFrame, screen: proxy.frame(in: .global))
                        .opacity(returnHeroReady ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                dismissalGesture(screen: proxy.size, frame: proxy.frame(in: .global)),
                // Do not let the full-screen dismissal recognizer compete
                // with controls hosted in the bottom overlay, especially the
                // seek slider.
                including: .gesture
            )
            .overlay(alignment: .top) {
                if let topBar = configuredTopBar(
                    screen: proxy.size,
                    frame: proxy.frame(in: .global)
                ) {
                    topBar
                    .frame(maxWidth: .infinity)
                    .padding(.top, max(proxy.safeAreaInsets.top, 44) + 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(chromeOpacity)
                    .allowsHitTesting(chromeOpacity > 0.01)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if configuration.showsVideoControls,
                       let currentVideoPlayer,
                       let currentItem {
                        SSPhotoViewerVideoControls(
                            item: currentItem,
                            player: currentVideoPlayer,
                            customContent: configuration.videoControlsBuilder
                        )
                            .transition(.opacity)
                    }

                    if let bottomBar = configuredBottomBar(
                        screen: proxy.size,
                        frame: proxy.frame(in: .global)
                    ) {
                        bottomBar
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.ssPhotoViewerIsZoomed, isCurrentImageZoomed)
                    }
                }
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0.01)
            }
            .task {
                startOpeningIfNeeded(screen: proxy.size, frame: proxy.frame(in: .global))
                requestNextPageIfNeeded()
            }
            .onChange(of: selectedIndex) { _, _ in
                // Player readiness arrives asynchronously. Release the prior
                // page's player synchronously so its controls and audio cannot
                // survive while an image (or another video) becomes current.
                if activeVideoPlayerID != currentItem?.id {
                    activeVideoPlayer?.pause()
                    activeVideoPlayer = nil
                    activeVideoPlayerID = nil
                }

                // Custom BYOH chrome can drive the shared selection binding
                // directly. Keep pagination independent from the package's
                // default strip so a custom strip reaching its end still
                // triggers the viewer-owned loader.
                requestNextPageIfNeeded()
            }
            .onChange(of: items.count) { _, newCount in
                // A host may feed viewer pages continuously instead of using
                // pageLoader. Merge append-only additions into the viewer's
                // local window without replacing its current page state.
                // Compare the count only: comparing 1,000 Hashable items on
                // every live strip-selection update is unnecessary work. The
                // host contract for externally-fed pages is append-only.
                guard newCount > loadedItems.count else { return }

                var existingIDs = Set(loadedIndexByID.keys)
                let fresh = items.dropFirst(loadedItems.count).filter {
                    existingIDs.insert($0.id).inserted
                }
                guard !fresh.isEmpty else { return }

                let firstFreshIndex = loadedItems.count
                loadedItems.append(contentsOf: fresh)
                for (offset, item) in fresh.enumerated() {
                    loadedIndexByID[item.id] = firstFreshIndex + offset
                    zoom[item.id] = ZoomState()
                }
            }
            .onChange(of: paginationCursor) { _, cursor in
                guard let cursor else { return }
                synchronizePagination(with: cursor)
            }
            .onDisappear {
                activeVideoPlayer?.pause()
                activeVideoPlayer = nil
                activeVideoPlayerID = nil
                pageLoadingTask?.cancel()
                pageLoadingTask = nil
                activePageNumber = nil
                stripSettlingTask?.cancel()
                stripSettlingTask = nil
                stripIsSettling = false
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentItem: SSPhotoViewerItem? {
        loadedItems.indices.contains(selectedIndex) ? loadedItems[selectedIndex] : nil
    }

    private var currentVideoPlayer: AVPlayer? {
        guard currentItem?.media.isVideo == true,
              activeVideoPlayerID == currentItem?.id
        else { return nil }
        return activeVideoPlayer
    }

    private func chromeContext(
        screen: CGSize,
        frame: CGRect
    ) -> SSPhotoViewerChromeContext? {
        guard let currentItem else { return nil }
        return SSPhotoViewerChromeContext(
            item: currentItem,
            selectedIndex: selectedIndex,
            itemCount: loadedItems.count,
            items: loadedItems,
            isZoomed: isCurrentImageZoomed,
            displayMode: detailProgress > 0.5 ? .detail : .minimal,
            pagination: SSPhotoViewerPaginationState(
                isLoading: pageLoadingTask != nil,
                hasMore: hasMorePages,
                nextPageNumber: nextPageNumber
            ),
            dismiss: {
                requestDismiss(screen: screen, frame: frame)
            },
            selectIndex: { index in
                selectItem(at: index)
            },
            selectID: { id in
                guard let index = loadedIndexByID[id] else { return }
                selectItem(at: index)
            },
            setDisplayMode: { mode in
                setDisplayMode(mode)
            },
            requestNextPage: {
                requestNextPageIfNeeded(force: true)
            },
            perform: { action in
                configuration.onAction(action)
            }
        )
    }

    private func configuredTopBar(
        screen: CGSize,
        frame: CGRect
    ) -> AnyView? {
        if let chromeContext = chromeContext(screen: screen, frame: frame),
           let builder = configuration.topBarBuilder {
            return builder(chromeContext)
        }
        if let topBar = configuration.topBar { return topBar }
        return configuration.showsDefaultTopBar ? AnyView(defaultTopBar) : nil
    }

    private func configuredBottomBar(
        screen: CGSize,
        frame: CGRect
    ) -> AnyView? {
        if let chromeContext = chromeContext(screen: screen, frame: frame),
           let builder = configuration.bottomBarBuilder {
            return builder(chromeContext)
        }
        if let bottomBar = configuration.bottomBar { return bottomBar }
        guard configuration.showsDefaultPaginationStrip ||
                configuration.showsDefaultActionBar
        else { return nil }
        return configuration.showsDefaultBottomBar ? AnyView(defaultBottomBar) : nil
    }

    private var pagerIndices: [Int] {
        guard !loadedItems.isEmpty else { return [] }
        if interaction == .vertical {
            return [selectedIndex]
        }
        let lower = max(0, selectedIndex - 1)
        let upper = min(loadedItems.count - 1, selectedIndex + 1)
        return Array(lower...upper)
    }

    private func pager(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(pagerIndices, id: \.self) { index in
                let item = loadedItems[index]
                let detailTreatmentApplies = aspectRatio(for: item) < 1
                let pageIsZoomed = index == selectedIndex && isCurrentImageZoomed
                let pageCornerRadius = index == selectedIndex
                    ? imageCornerRadius
                    : (detailTreatmentApplies ? detailModeCornerRadius * detailProgress : 0)

                SSPhotoViewerMediaPage(
                    item: item,
                    zoom: Binding(
                        get: { zoom[item.id, default: ZoomState()] },
                        set: { zoom[item.id] = $0 }
                    ),
                    isCurrent: index == selectedIndex,
                    isPlaybackEnabled:
                        index == selectedIndex &&
                        interaction == .idle &&
                        !isDismissing,
                    cornerRadius: pageCornerRadius,
                    size: size,
                    aspectRatio: aspectRatio(for: item),
                    imageContentMode:
                        aspectRatio(for: item) >= 1 && interaction != .vertical
                            ? .fill
                            : .fit,
                    // Keep the media page full-size while paging. The visible
                    // separation comes from activePageSpacing in the pager;
                    // an inset here would resize the image itself.
                    horizontalInset: 0,
                    onAspectRatioReady: { ratio in
                        guard ratio.isFinite, ratio > 0 else { return }
                        resolvedAspectRatios[item.id] = ratio
                    },
                    onPlayerReady: { player in
                        // A player can finish preparing after its page is no
                        // longer selected. Never let that stale callback claim
                        // the controls or continue playback over another item.
                        guard index == selectedIndex,
                              currentItem?.id == item.id,
                              item.media.isVideo
                        else {
                            player.pause()
                            return
                        }
                        activeVideoPlayer = player
                        activeVideoPlayerID = item.id
                    },
                    onReady: {
                        guard index == selectedIndex else { return }
                        fullscreenMediaReadyID = item.id
                        finishOpeningIfReady()
                    },
                    interactiveOffset: index == selectedIndex ? liveZoomPanOffset : .zero
                )
                .id(item.id)
                .frame(width: size.width, height: size.height)
                .scaleEffect(
                    index == selectedIndex
                        ? imageScale
                        : (detailTreatmentApplies && !pageIsZoomed
                            ? 1 - detailProgress * 0.1
                            : 1)
                )
                .offset(
                    x: CGFloat(index - selectedIndex) * (size.width + activePageSpacing) + horizontalDrag,
                    y: index == selectedIndex ? verticalDrag : 0
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: pageCornerRadius,
                        style: .continuous
                    )
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var activePageSpacing: CGFloat {
        horizontalDrag == 0 && !pageIsSettling ? 0 : movingPageSpacing
    }

    private var backgroundOpacity: Double {
        if isOpening {
            return openingBackdropOpacity
        }

        if isDismissing {
            return dismissalBackdropOpacity
        }

        return interactiveBackdropOpacity(for: activeVerticalDrag)
    }

    private func interactiveBackdropOpacity(for drag: CGFloat) -> Double {
        let progress = min(abs(drag) / dismissalThreshold, 1)
        return 1 - pow(progress, 2.4) * 0.85
    }

    private var chromeIsVisible: Bool {
        // Horizontal paging keeps the detail chrome visible. It is hidden only
        // while the vertical dismissal/pan interaction is active.
        detailProgress > 0.01 && interaction != .vertical && returningFrame == nil && !isOpening
    }

    private var chromeOpacity: Double {
        chromeIsVisible ? Double(detailProgress) : 0
    }

    private var verticalCornerRadius: CGFloat {
        min(
            abs(activeVerticalDrag) / dismissalThreshold * maximumDismissalCornerRadius,
            maximumDismissalCornerRadius
        )
    }

    private var verticalDragScale: CGFloat {
        1 - min(abs(activeVerticalDrag) / dismissalThreshold, 1) * 0.15
    }

    private var imageScale: CGFloat {
        (detailTreatmentApplies && !isCurrentImageZoomed ? 1 - detailProgress * 0.1 : 1)
            * verticalDragScale
    }

    private var imageCornerRadius: CGFloat {
        if activeVerticalDrag != 0 {
            return verticalCornerRadius
        }

        return detailTreatmentApplies && !isCurrentImageZoomed
            ? detailModeCornerRadius * detailProgress
            : 0
    }

    private var isCurrentImageZoomed: Bool {
        guard let item = currentItem else { return false }
        return zoom[item.id, default: ZoomState()].scale > 1.01
    }

    private var detailTreatmentApplies: Bool {
        guard let item = currentItem else { return false }
        return aspectRatio(for: item) < 1
    }

    private func aspectRatio(for item: SSPhotoViewerItem) -> CGFloat {
        resolvedAspectRatios[item.id] ?? item.aspectRatio ?? 1
    }

    private func resistedVerticalDrag(_ translation: CGFloat) -> CGFloat {
        let direction: CGFloat = translation < 0 ? -1 : 1
        let magnitude = abs(translation)
        guard magnitude > dismissalThreshold else { return translation }

        let overshoot = magnitude - dismissalThreshold
        return direction * (dismissalThreshold + overshoot * 0.22)
    }

    private func resistedPageDrag(_ translation: CGFloat) -> CGFloat {
        let direction: CGFloat = translation < 0 ? -1 : 1
        return direction * min(abs(translation) * 0.72, 180)
    }

    private func dismissalGesture(screen: CGSize, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if let item = currentItem,
                   zoom[item.id, default: ZoomState()].scale > 1.01 {
                    if interaction == .horizontal {
                        horizontalDrag = resistedPageDrag(
                            value.translation.width - zoomPagingStartTranslation
                        )
                        return
                    }

                    if interaction == .idle {
                        let movement = abs(value.translation.width) + abs(value.translation.height)
                        guard movement >= 10 else { return }

                        // Keep horizontal movement in the zoom-pan path until
                        // the content reaches its edge; only then does the
                        // existing edge handoff promote it to paging.
                        if abs(value.translation.height) > abs(value.translation.width) {
                            interaction = .vertical
                            lastPanTranslation = .zero
                            liveZoomPanOffset = .zero
                            zoomedVerticalPanPhase = canPanZoomedVertically(
                                item: item,
                                translation: value.translation.height,
                                screen: screen
                            )
                        }
                    }

                    if interaction == .vertical, zoomedVerticalPanPhase {
                        var state = zoom[item.id, default: ZoomState()]
                        let delta = CGSize(
                            width: value.translation.width - lastPanTranslation.width,
                            height: value.translation.height - lastPanTranslation.height
                        )
                        let proposedOffset = CGSize(
                            width: state.offset.width + delta.width,
                            height: state.offset.height + delta.height
                        )
                        let clampedOffset = clampedZoomOffset(
                            proposedOffset,
                            scale: state.scale,
                            item: item,
                            screen: screen
                        )

                        state.offset = clampedOffset
                        zoom[item.id] = state
                        lastPanTranslation = value.translation
                        return
                    }

                    // A zoomed image can still enter the vertical dismissal
                    // path. Keep a little resistance after the threshold, just
                    // like horizontal paging resists at its edge.
                    if interaction == .vertical {
                        horizontalDrag = horizontalPanOffset + value.translation.width
                        let proposedOffset = verticalPanOffset + value.translation.height
                        verticalDrag = proposedOffset > dismissalThreshold
                            ? resistedVerticalDrag(proposedOffset)
                            : proposedOffset
                        activeVerticalDrag = verticalDrag
                        return
                    }

                    var state = zoom[item.id, default: ZoomState()]
                    let delta = CGSize(
                        width: value.translation.width - lastPanTranslation.width,
                        height: value.translation.height - lastPanTranslation.height
                    )
                    let proposedOffset = CGSize(
                        width: state.offset.width + liveZoomPanOffset.width + delta.width,
                        height: state.offset.height + liveZoomPanOffset.height + delta.height
                    )
                    let clampedOffset = clampedZoomOffset(
                        proposedOffset,
                        scale: state.scale,
                        item: item,
                        screen: screen
                    )
                    let crossedHorizontalEdge =
                        abs(delta.width) > abs(delta.height) &&
                        abs(proposedOffset.width - clampedOffset.width) > 0.5

                    if crossedHorizontalEdge {
                        state.offset = clampedOffset
                        zoom[item.id] = state
                        liveZoomPanOffset = .zero
                        interaction = .horizontal
                        zoomPagingStartTranslation = value.translation.width
                        horizontalDrag = resistedPageDrag(
                            proposedOffset.width - clampedOffset.width
                        )
                    }

                    liveZoomPanOffset = CGSize(
                        width: clampedOffset.width - state.offset.width,
                        height: clampedOffset.height - state.offset.height
                    )
                    lastPanTranslation = value.translation
                    return
                }

                if interaction == .idle {
                    let movement = abs(value.translation.width) + abs(value.translation.height)
                    guard movement >= 10 else { return }

                    interaction = abs(value.translation.height) > abs(value.translation.width)
                        ? .vertical
                        : .horizontal
                }

                if interaction == .vertical {
                    interaction = .vertical
                    horizontalDrag = horizontalPanOffset + value.translation.width
                    let proposedOffset = verticalPanOffset + value.translation.height
                    verticalDrag = proposedOffset > dismissalThreshold
                        ? resistedVerticalDrag(proposedOffset)
                        : proposedOffset
                    activeVerticalDrag = verticalDrag
                } else {
                    interaction = .horizontal
                    horizontalDrag = value.translation.width
                }
            }
            .onEnded { value in
                if let item = currentItem,
                   zoom[item.id, default: ZoomState()].scale > 1.01,
                   interaction == .vertical,
                   zoomedVerticalPanPhase {
                    // The first vertical gesture only brought the zoomed
                    // image to its edge. Dismissal starts on the next gesture.
                    zoomedVerticalPanPhase = false
                    liveZoomPanOffset = .zero
                    lastPanTranslation = .zero
                    interaction = .idle
                    return
                }

                if let item = currentItem,
                   zoom[item.id, default: ZoomState()].scale > 1.01,
                   interaction == .idle {
                    var state = zoom[item.id, default: ZoomState()]
                    let currentOffset = CGSize(
                        width: state.offset.width + liveZoomPanOffset.width,
                        height: state.offset.height + liveZoomPanOffset.height
                    )
                    let projectedDelta = CGSize(
                        width: value.predictedEndTranslation.width - value.translation.width,
                        height: value.predictedEndTranslation.height - value.translation.height
                    )
                    let projectedOffset = clampedZoomOffset(
                        CGSize(
                            width: currentOffset.width + projectedDelta.width,
                            height: currentOffset.height + projectedDelta.height
                        ),
                        scale: state.scale,
                        item: item,
                        screen: screen
                    )

                    // DragGesture supplies the system's projected end
                    // translation. Commit that projected, clamped offset in
                    // one ease-out transaction so a zoomed image coasts after
                    // release instead of stopping at the finger position.
                    withAnimation(.easeOut(duration: 0.24)) {
                        state.offset = projectedOffset
                        zoom[item.id] = state
                        liveZoomPanOffset = .zero
                    }
                    lastPanTranslation = .zero
                    interaction = .idle
                    return
                }

                if interaction == .vertical,
                   verticalDrag >= dismissalThreshold {
                    if usesSourceHandoff {
                        // Preserve the exact opacity reached under the finger.
                        // Switching to the dismissal phase must never reset the
                        // backdrop to its initial value and flash black again.
                        dismissalBackdropOpacity = interactiveBackdropOpacity(
                            for: activeVerticalDrag
                        )
                        isDismissing = true
                        // Capture the interactive geometry immediately. A delayed
                        // hero leaves a visible frame where the fullscreen page has
                        // faded but the return surface does not yet exist.
                        beginReturn(screen: screen, frame: frame, direction: .vertical)
                    } else {
                        beginPresentationDismissal()
                    }
                    return
                }

                if interaction == .vertical {
                    snapBack()
                    return
                }

                guard interaction == .horizontal else {
                    withAnimation(.easeOut(duration: pageAnimationDuration)) {
                        verticalDrag = 0
                    }
                    interaction = .idle
                    return
                }

                guard abs(value.translation.width) > 75 else {
                    snapBack()
                    return
                }

                if interaction == .horizontal {
                    let previous = selectedIndex
                    let next = selectedIndex + (value.translation.width < 0 ? 1 : -1)
                    guard loadedItems.indices.contains(next) else {
                        snapBack()
                        return
                    }

                    let targetOffset = value.translation.width < 0
                        ? -(screen.width + movingPageSpacing)
                        : screen.width + movingPageSpacing

                    pageIsSettling = true
                    withAnimation(.easeOut(duration: pageAnimationDuration)) {
                        horizontalDrag = targetOffset
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + pageAnimationDuration) {
                        if loadedItems.indices.contains(previous) {
                            zoom[loadedItems[previous].id] = ZoomState()
                        }
                        selectedIndex = next
                        if loadedItems.indices.contains(selectedIndex) {
                            zoom[loadedItems[selectedIndex].id] = ZoomState()
                        }
                        horizontalDrag = 0
                        horizontalPanOffset = 0
                        liveZoomPanOffset = .zero
                        verticalDrag = 0
                        verticalPanOffset = 0
                        activeVerticalDrag = 0
                        zoomPagingStartTranslation = 0
                        zoomedVerticalPanPhase = false
                        interaction = .idle
                        pageIsSettling = false
                        requestNextPageIfNeeded()
                    }
                }
            }
    }

    private func snapBack() {
        pageIsSettling = false
        withAnimation(.easeOut(duration: pageAnimationDuration)) {
            horizontalDrag = 0
            horizontalPanOffset = 0
            liveZoomPanOffset = .zero
            verticalDrag = 0
            verticalPanOffset = 0
            activeVerticalDrag = 0
            zoomPagingStartTranslation = 0
            zoomedVerticalPanPhase = false
            dismissalBackdropOpacity = 1
        }
        isDismissing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + pageAnimationDuration) {
            interaction = .idle
        }
    }

    private func selectItem(at index: Int) {
        guard loadedItems.indices.contains(index), index != selectedIndex else {
            requestNextPageIfNeeded()
            return
        }

        let previousIndex = selectedIndex
        if loadedItems.indices.contains(previousIndex) {
            zoom[loadedItems[previousIndex].id] = ZoomState()
        }

        selectedIndex = index
        zoom[loadedItems[index].id] = ZoomState()
        liveZoomPanOffset = .zero
        lastPanTranslation = .zero
        requestNextPageIfNeeded()
    }

    private func setDisplayMode(_ mode: SSPhotoViewerDisplayMode) {
        let target: CGFloat = mode == .detail ? 1 : 0
        guard abs(detailProgress - target) > 0.001 else { return }

        withAnimation(.easeInOut(duration: 0.24)) {
            detailProgress = target
        }
    }

    private func requestDismiss(screen: CGSize, frame: CGRect) {
        guard interaction == .idle,
              !isOpening,
              !isDismissing,
              returningFrame == nil,
              currentItem != nil
        else { return }

        activeVideoPlayer?.pause()
        if usesSourceHandoff {
            dismissalBackdropOpacity = backgroundOpacity
            isDismissing = true
            beginReturn(screen: screen, frame: frame, direction: .vertical)
        } else {
            beginPresentationDismissal()
        }
    }

    private func beginPresentationDismissal() {
        guard !isDismissing else { return }

        // A full-screen cover already supplies the presentation transition.
        // Fade the viewer in place, then release the cover exactly once. Do
        // not create a second return surface inside the cover.
        dismissalBackdropOpacity = backgroundOpacity
        isDismissing = true
        let dismissalDuration = 0.24
        withAnimation(.easeInOut(duration: dismissalDuration)) {
            dismissalBackdropOpacity = 0
            horizontalDrag = 0
            verticalDrag = 0
            activeVerticalDrag = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dismissalDuration) {
            onDismiss()
        }
    }

    private func toggleZoom(at location: CGPoint, screen: CGSize) {
        guard let item = currentItem else { return }
        var state = zoom[item.id, default: ZoomState()]

        if state.scale > 1.01 {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                state.scale = 1
                state.offset = .zero
                zoom[item.id] = state
            }
            return
        }

        let fitted = fittedMediaSize(for: item, in: screen)
        let targetScale = max(
            1,
            screen.width / fitted.width,
            screen.height / fitted.height
        )
        let proposedOffset = CGSize(
            width: (location.x - screen.width / 2) * (1 - targetScale),
            height: (location.y - screen.height / 2) * (1 - targetScale)
        )
        let anchoredOffset = clampedZoomOffset(
            proposedOffset,
            scale: targetScale,
            item: item,
            screen: screen
        )

        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            state.scale = targetScale
            state.offset = anchoredOffset
            zoom[item.id] = state
        }
    }

    private func clampedZoomOffset(
        _ offset: CGSize,
        scale: CGFloat,
        item: SSPhotoViewerItem,
        screen: CGSize
    ) -> CGSize {
        let fitted = fittedMediaSize(for: item, in: screen)
        let maxX = max(0, (fitted.width * scale - screen.width) / 2)
        let maxY = max(0, (fitted.height * scale - screen.height) / 2)

        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func canPanZoomedVertically(
        item: SSPhotoViewerItem,
        translation: CGFloat,
        screen: CGSize
    ) -> Bool {
        let state = zoom[item.id, default: ZoomState()]
        let fitted = fittedMediaSize(for: item, in: screen)
        let maxY = max(0, (fitted.height * state.scale - screen.height) / 2)

        if translation > 0 {
            return state.offset.height < maxY - 0.5
        }

        if translation < 0 {
            return state.offset.height > -maxY + 0.5
        }

        return false
    }

    private func fittedMediaSize(
        for item: SSPhotoViewerItem,
        in screen: CGSize
    ) -> CGSize {
        let screenRatio = screen.width / screen.height
        let ratio = aspectRatio(for: item)
        if ratio > screenRatio {
            return CGSize(width: screen.width, height: screen.width / ratio)
        }
        return CGSize(width: screen.height * ratio, height: screen.height)
    }

    private func beginReturn(
        screen: CGSize,
        frame: CGRect,
        direction: ReturnDirection
    ) {
        guard let item = currentItem else { return }

        let destination: CGRect
        if let exact = sourceFrames[item.id], exact.width > 0, exact.height > 0 {
            destination = exact
        } else if let captured = presentationSourceFrames[item.id],
                  captured.width > 0, captured.height > 0 {
            destination = captured
        } else {
            switch configuration.fallbackDestination {
            case .source:
                destination = fallbackOffscreenDestination(
                    frame: frame,
                    direction: direction
                )
            case .fixed(let fixed):
                destination = fixed
            case .offscreenAfterLastVisible:
                destination = fallbackOffscreenDestination(
                    frame: frame,
                    direction: direction
                )
            }
        }

        let zoomState = zoom[item.id, default: ZoomState()]
        let startScale = imageScale * zoomState.scale
        let fittedStartSize = fittedMediaSize(for: item, in: frame.size)
        let startSize = CGSize(
            width: fittedStartSize.width * startScale,
            height: fittedStartSize.height * startScale
        )
        let startFrame = CGRect(
            x: frame.midX + horizontalDrag - startSize.width / 2,
            y: frame.midY + verticalDrag - startSize.height / 2,
            width: startSize.width,
            height: startSize.height
        )
        let adjustedStartFrame = startFrame.offsetBy(
            dx: zoomState.offset.width + liveZoomPanOffset.width,
            dy: zoomState.offset.height + liveZoomPanOffset.height
        )
        returnHeroReady = false
        returnDestination = destination
        returningFrame = ReturnFrame(
            item: item,
            frame: adjustedStartFrame,
            cornerRadius: imageCornerRadius
        )

        // Do not transfer ownership here. The return surface may still be
        // loading its static preview; its onReady callback starts the handoff
        // only after that visual has rendered at the captured frame.
    }

    private func completeReturnHero() {
        guard !returnHeroReady else { return }
        guard let destination = returnDestination,
              returningFrame?.frame != nil else {
            onDismiss()
            return
        }

        // The return surface has rendered its static visual. Make it visible
        // at the captured interactive frame without animation first; otherwise
        // the opaque backdrop is briefly visible while the hero fades in.
        var ownershipTransfer = Transaction()
        ownershipTransfer.animation = nil
        withTransaction(ownershipTransfer) {
            returnHeroReady = true
        }

        // Resize and travel together from the exact interactive release frame.
        // A sequential resize-then-travel makes the hero appear to sink before
        // it moves back to its source cell.
        let returnAnimationDuration = 0.24
        withAnimation(.easeInOut(duration: returnAnimationDuration)) {
            returningFrame?.frame = destination
            returningFrame?.cornerRadius = 1
            dismissalBackdropOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + returnAnimationDuration) {
            onDismiss()
        }
    }

    private func fallbackOffscreenDestination(
        frame: CGRect,
        direction: ReturnDirection
    ) -> CGRect {
        if let last = loadedItems.reversed().compactMap({ sourceFrames[$0.id] }).last {
            switch direction {
            case .horizontal:
                return CGRect(
                    x: max(last.maxX + 12, frame.maxX + 12),
                    y: last.minY,
                    width: last.width,
                    height: last.height
                )
            case .vertical:
                return CGRect(
                    x: last.minX,
                    y: max(last.maxY + 12, frame.maxY + 12),
                    width: last.width,
                    height: last.height
                )
            }
        }

        let fallbackSize = CGSize(width: 1, height: 1)
        switch direction {
        case .horizontal:
            return CGRect(
                x: frame.maxX + 12,
                y: frame.midY,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        case .vertical:
            return CGRect(
                x: frame.midX,
                y: frame.maxY + 12,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }
    }

    private func startOpeningIfNeeded(screen: CGSize, frame: CGRect) {
        guard isOpening,
              openingDestination == nil,
              let openingFrame else { return }

        // When the caller does not know the ratio, wait for the opening
        // surface to report the loaded visual dimensions. This prevents a
        // temporary square geometry from becoming the opening animation.
        guard openingFrame.item.aspectRatio != nil
            || resolvedAspectRatios[openingFrame.item.id] != nil
        else { return }

        let fitted = fittedMediaSize(for: openingFrame.item, in: screen)
        openingDestination = CGRect(
            x: frame.midX - fitted.width / 2,
            y: frame.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func startOpeningAnimationIfReady() {
        guard isOpening,
              openingHeroReady,
              !openingAnimationStarted,
              let destination = openingDestination
        else { return }

        openingAnimationStarted = true
        withAnimation(openingAnimation) {
            openingFrame?.frame = destination
            openingFrame?.cornerRadius = 0
            openingBackdropOpacity = 1
        }

        // Commit the first movement frame before hiding the real source. The
        // preview hero and source intentionally overlap for this frame; that
        // is preferable to exposing the home background between owners.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
            guard isOpening, openingAnimationStarted else { return }
            onOpeningReady()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + openingCompletionDelay) {
            openingAnimationCompleted = true
            finishOpeningIfReady()
        }
    }

    private func finishOpeningIfReady() {
        guard isOpening,
              openingAnimationCompleted,
              let item = openingFrame?.item,
              fullscreenMediaReadyID == item.id
        else { return }

        isOpening = false
        openingFrame = nil
        openingDestination = nil
        openingHeroReady = false
        openingAnimationStarted = false
        openingAnimationCompleted = false
    }

    private var defaultTopBar: some View {
        Text(currentItem?.accessibilityLabel ?? "Media")
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var defaultBottomBar: some View {
        VStack(spacing: 0) {
            if configuration.showsDefaultPaginationStrip {
                let visualIndex = stripVisualIndex ?? selectedIndex
                let stripItemWidth = stripIsDragging || stripIsSettling
                    ? stripMovingThumbnailWidth
                    : stripRestingThumbnailWidth
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 1) {
                            Color.clear
                                .frame(width: max(0, (geometry.size.width - stripItemWidth) / 2))

                            ForEach(loadedItems.indices, id: \.self) { index in
                                let item = loadedItems[index]
                                Button {
                                    withAnimation(.easeOut(duration: pageAnimationDuration)) {
                                        selectedIndex = index
                                        zoom[item.id] = ZoomState()
                                    }
                                    proxy.scrollTo(item.id, anchor: .center)
                                    requestNextPageIfNeeded()
                                } label: {
                                    SSPhotoViewerThumbnailSurface(item: item)
                                        .frame(
                                            width: thumbnailWidth(
                                                for: item,
                                                isSelected: index == visualIndex
                                                    && !stripIsDragging
                                                    && !stripIsSettling
                                            ),
                                            height: 40
                                        )
                                        .contentShape(Rectangle())
                                        .background {
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: SSPhotoViewerStripFrameKey.self,
                                                    value: [
                                                        item.id: proxy.frame(in: .named("ssPhotoViewerStrip"))
                                                    ]
                                                )
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                                .stroke(
                                                    index == visualIndex ? Color.white : .clear,
                                                    lineWidth: 1
                                                )
                                        }
                                }
                                .id(item.id)
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.accessibilityLabel ?? "Media \(index + 1)")
                                .accessibilityValue(index == visualIndex ? "Selected" : "")
                            }

                            Color.clear
                                .frame(width: max(0, (geometry.size.width - stripItemWidth) / 2))
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(height: 40)
                        .onAppear { stripViewportWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in
                            stripViewportWidth = width
                        }
                        .coordinateSpace(name: "ssPhotoViewerStrip")
                        .simultaneousGesture(
                        // Keep ordinary taps on thumbnails out of the drag
                        // selection path. ScrollView still owns the actual
                        // high-velocity scrolling and deceleration.
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in
                                stripSettlingTask?.cancel()
                                stripSettlingTask = nil
                                stripIsSettling = false
                                stripIsDragging = true
                            }
                            .onEnded { _ in
                                stripIsDragging = false
                                stripIsSettling = true
                                scheduleStripSelectionSettle(
                                    frames: stripFrames,
                                    viewportWidth: geometry.size.width,
                                )
                            }
                        )
                    }
                    .frame(height: 40)
                    .background(Color.clear)
                    .onPreferenceChange(SSPhotoViewerStripFrameKey.self) { frames in
                    stripFrames = frames
                    // The strip has its own scroll position. It can reach the
                    // end of the currently loaded content before the nearest
                    // thumbnail has committed a new selectedIndex, so the
                    // selected-index prefetch alone is not sufficient here.
                    requestNextPageIfStripNeedsMore(frames: frames)
                    if stripIsDragging || stripIsSettling {
                        // Keep the viewer and selection border synchronized
                        // during both finger motion and native deceleration.
                        // The settling state intentionally keeps every
                        // thumbnail at the moving size until scrolling stops.
                        updateSelectedIndexFromStrip(
                            frames: frames,
                            viewportWidth: stripViewportWidth
                        )
                        if stripIsSettling {
                            scheduleStripSelectionSettle(
                                frames: frames,
                                viewportWidth: stripViewportWidth
                            )
                        }
                    }
                }
                    .onAppear {
                        guard loadedItems.indices.contains(selectedIndex) else { return }
                        stripVisualIndex = selectedIndex
                        proxy.scrollTo(loadedItems[selectedIndex].id, anchor: .center)
                    }
                    .onChange(of: selectedIndex) { _, index in
                    guard loadedItems.indices.contains(index) else { return }
                    if !stripIsDragging && !stripIsSettling {
                        stripVisualIndex = index
                    }
                    // A page owns its own zoom/pan state. Reset it whenever the
                    // strip or pager hands the viewer a different item.
                    zoom[loadedItems[index].id] = ZoomState()
                    liveZoomPanOffset = .zero
                    lastPanTranslation = .zero
                    guard !stripIsDragging else { return }
                    withAnimation(.easeOut(duration: pageAnimationDuration)) {
                        proxy.scrollTo(loadedItems[index].id, anchor: .center)
                    }
                }
                    .onChange(of: loadedItems.count) { _, _ in
                    guard loadedItems.indices.contains(selectedIndex),
                          !stripIsDragging,
                          !stripIsSettling
                    else { return }

                    // Pagination extends the same strip data source. Keep the
                    // active item centered while allowing the newly appended
                    // thumbnails to appear immediately after it.
                    stripVisualIndex = selectedIndex
                    withAnimation(.easeOut(duration: pageAnimationDuration)) {
                        proxy.scrollTo(
                            loadedItems[selectedIndex].id,
                            anchor: .center
                        )
                    }
                    }
                }
                .opacity(isCurrentImageZoomed ? 0 : 1)
                .allowsHitTesting(!isCurrentImageZoomed)
                .animation(.easeOut(duration: 0.16), value: isCurrentImageZoomed)
            }

            if configuration.showsDefaultActionBar {
                actionBar
            }
        }
        .frame(height: 100)
        .font(.headline)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var actionBar: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 18) {
                actionBarContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .padding(.horizontal, 18)
        } else {
            actionBarContent
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 18)
        }
    }

    private var actionBarContent: some View {
        HStack(spacing: 18) {
            glassActionButton {
                if let item = currentItem { configuration.onAction(.share(item)) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    // Optical correction: this symbol's square gives it a
                    // lower visual center than the neighboring glyphs.
                    .offset(y: -1)
            }

            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        glassActionButton {
                            if let item = currentItem { configuration.onAction(.custom(id: "favorite", item: item)) }
                        } label: {
                            Image(systemName: "heart")
                        }

                        glassActionButton {
                            if let item = currentItem { configuration.onAction(.custom(id: "info", item: item)) }
                        } label: {
                            Image(systemName: "info.circle")
                        }

                        glassActionButton {
                            if let item = currentItem { configuration.onAction(.custom(id: "adjust", item: item)) }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            } else {
                HStack(spacing: 14) {
                    glassActionButton {
                        if let item = currentItem { configuration.onAction(.custom(id: "favorite", item: item)) }
                    } label: {
                        Image(systemName: "heart")
                    }

                    glassActionButton {
                        if let item = currentItem { configuration.onAction(.custom(id: "info", item: item)) }
                    } label: {
                        Image(systemName: "info.circle")
                    }

                    glassActionButton {
                        if let item = currentItem { configuration.onAction(.custom(id: "adjust", item: item)) }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }

            glassActionButton {
                if let item = currentItem { configuration.onAction(.custom(id: "delete", item: item)) }
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    @ViewBuilder
    private func glassActionButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(iOS 26, *) {
            Button(action: action, label: label)
                .frame(width: 52, height: 52)
                .buttonStyle(.glass)
        } else {
            Button(action: action, label: label)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func returnHero(
        _ state: ReturnFrame,
        screen: CGRect
    ) -> some View {
        SSPhotoViewerMediaSurface(
            item: state.item,
            imageContentMode: .fill,
            placeholderColor: .clear,
            usesStaticVisual: true,
            usesThumbnailVisual: true
        ) {
            completeReturnHero()
        }
            .frame(width: state.frame.width, height: state.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius, style: .continuous))
            .position(
                x: state.frame.midX - screen.minX,
                y: state.frame.midY - screen.minY
            )
            .allowsHitTesting(false)
            .zIndex(2)
    }

    private func openingHero(
        _ state: ReturnFrame,
        screen: CGRect
    ) -> some View {
        SSPhotoViewerMediaSurface(
            item: state.item,
            imageContentMode: .fill,
            placeholderColor: .clear,
            usesStaticVisual: true,
            usesThumbnailVisual: true,
            onReady: {
                guard isOpening, !openingHeroReady else { return }

                openingHeroReady = true
                // Let the loaded preview render visibly at the source frame
                // before transferring ownership away from the home thumbnail.
                DispatchQueue.main.async {
                    startOpeningAnimationIfReady()
                }
            },
            onAspectRatioReady: { ratio in
                guard ratio.isFinite, ratio > 0 else { return }
                resolvedAspectRatios[state.item.id] = ratio
                if isOpening, openingDestination == nil {
                    startOpeningIfNeeded(
                        screen: screen.size,
                        frame: screen
                    )
                }
                startOpeningAnimationIfReady()
            }
        )
        .frame(width: state.frame.width, height: state.frame.height)
        .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius, style: .continuous))
        .position(
            x: state.frame.midX - screen.minX,
            y: state.frame.midY - screen.minY
        )
        .allowsHitTesting(false)
        .zIndex(2)
    }

    private func synchronizePagination(
        with cursor: SSPhotoViewerPaginationCursor
    ) {
        let externalNextPage = max(1, cursor.nextPageNumber)

        // If eager loading already accepted the page being requested, the
        // older pull is redundant. Cancellation prevents its eventual result
        // from overwriting newer `hasMore` state or appending stale media.
        if let activePageNumber,
           externalNextPage > activePageNumber {
            pageLoadingTask?.cancel()
            pageLoadingTask = nil
            self.activePageNumber = nil
        }

        nextPageNumber = max(nextPageNumber, externalNextPage)
        hasMorePages = cursor.hasMore
    }

    private func requestNextPageIfNeeded(force: Bool = false) {
        // Prefetch one item before the boundary. Waiting until the selected
        // item is already the last loaded item is too late: the horizontal
        // pager rejects the swipe because no adjacent page exists yet.
        guard loadedItems.count > 0,
              (force || selectedIndex >= loadedItems.count - 2),
              hasMorePages,
              pageLoadingTask == nil,
              let pageLoader = configuration.pageLoader else { return }
        // Page loaders receive a stable, monotonic page number. Deriving this
        // from the current item count couples pagination to an assumed page
        // size and breaks as soon as a host uses a different page size.
        let nextPage = nextPageNumber
        activePageNumber = nextPage

        pageLoadingTask = Task { [pageLoader] in
            let page = await pageLoader(nextPage)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let existing = Set(loadedItems.map(\.id))
                let fresh = page.items.filter { !existing.contains($0.id) }
                let firstFreshIndex = loadedItems.count
                loadedItems.append(contentsOf: fresh)
                for (offset, item) in fresh.enumerated() {
                    loadedIndexByID[item.id] = firstFreshIndex + offset
                }
                for item in fresh { zoom[item.id] = ZoomState() }
                let followingPage = nextPage + 1
                // An externally pushed cursor may have advanced while this
                // request was running. Never move it backward or let an older
                // response replace newer exhaustion state.
                if nextPageNumber <= followingPage {
                    hasMorePages = page.hasMore
                }
                nextPageNumber = max(nextPageNumber, followingPage)
                pageLoadingTask = nil
                activePageNumber = nil
            }
        }
    }

    private func requestNextPageIfStripNeedsMore(frames: [String: CGRect]) {
        guard loadedItems.count > 0,
              hasMorePages,
              pageLoadingTask == nil else { return }

        let furthestMountedIndex = frames.keys.compactMap { loadedIndexByID[$0] }.max()

        // LazyHStack mounts a small look-ahead window. Request while that
        // window reaches the final three loaded items so the next page is
        // available before the user can hit the hard end of the strip.
        guard let furthestMountedIndex,
              furthestMountedIndex >= loadedItems.count - 3 else { return }

        requestNextPageIfNeeded(force: true)
    }

    private func thumbnailWidth(
        for item: SSPhotoViewerItem,
        isSelected: Bool
    ) -> CGFloat {
        guard isSelected else { return stripMovingThumbnailWidth }
        return stripRestingThumbnailWidth
    }

    private var stripMovingThumbnailWidth: CGFloat { 40 * 9 / 16 }
    private var stripRestingThumbnailWidth: CGFloat { 40 * 12 / 16 }

    private func updateSelectedIndexFromStrip(
        frames: [String: CGRect],
        viewportWidth: CGFloat,
        commitThumbnailSelection: Bool = false
    ) {
        guard let nearest = frames.min(by: {
            abs($0.value.midX - viewportWidth / 2) < abs($1.value.midX - viewportWidth / 2)
        }),
        let index = loadedIndexByID[nearest.key]
        else { return }

        // The border follows the thumbnail nearest the viewport center during
        // the drag itself. Do not wait for native scroll settling to update it.
        let isDragging = stripIsDragging
        if isDragging {
            stripVisualIndex = index
        }

        guard index != selectedIndex || commitThumbnailSelection else { return }

        if commitThumbnailSelection {
            withAnimation(.easeInOut(duration: 0.2)) {
                stripVisualIndex = index
            }
        }

        guard index != selectedIndex else { return }

        guard !isDragging else {
            // During motion the selected page and border must follow the
            // centered thumbnail immediately. Animation here causes the
            // border to lag behind native ScrollView movement.
            selectedIndex = index
            zoom[nearest.key] = ZoomState()
            requestNextPageIfNeeded()
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            selectedIndex = index
            zoom[nearest.key] = ZoomState()
        }
        requestNextPageIfNeeded()
    }

    private func scheduleStripSelectionSettle(
        frames: [String: CGRect],
        viewportWidth: CGFloat
    ) {
        stripSettlingTask?.cancel()

        // This is only a quiet-period debounce. ScrollView owns the actual
        // velocity and deceleration; no synthetic velocity is applied here.
        stripSettlingTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            let nearestID = await Task.detached(priority: .userInitiated) {
                frames.min {
                    abs($0.value.midX - viewportWidth / 2)
                        < abs($1.value.midX - viewportWidth / 2)
                }?.key
            }.value

            guard !Task.isCancelled,
                  !stripIsDragging,
                  let nearestID,
                  let index = loadedIndexByID[nearestID]
            else { return }

            withAnimation(.easeInOut(duration: 0.2)) {
                stripVisualIndex = index
                stripIsSettling = false
            }

            stripSettlingTask = nil
            guard index != selectedIndex else { return }
            selectedIndex = index
            zoom[nearestID] = ZoomState()
            requestNextPageIfNeeded()
        }
    }
}

private enum Interaction: Equatable {
    case idle
    case vertical
    case horizontal
}

private struct ZoomState {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

private struct PinchBaseline: Equatable {
    let scale: CGFloat
}

private struct ReturnFrame {
    let item: SSPhotoViewerItem
    var frame: CGRect
    var cornerRadius: CGFloat
}

private enum ReturnDirection {
    case horizontal
    case vertical
}

private struct SSPhotoViewerMediaPage: View {
    let item: SSPhotoViewerItem
    @Binding var zoom: ZoomState
    let isCurrent: Bool
    let isPlaybackEnabled: Bool
    let cornerRadius: CGFloat
    let size: CGSize
    let aspectRatio: CGFloat
    let imageContentMode: ContentMode
    let horizontalInset: CGFloat
    let onAspectRatioReady: (CGFloat) -> Void
    let onPlayerReady: (AVPlayer) -> Void
    let onReady: () -> Void
    let interactiveOffset: CGSize

    @GestureState private var pinchBaseline: PinchBaseline?
    @State private var mediaReady = false

    private let maximumPinchScale: CGFloat = 5

    var body: some View {
        ZStack(alignment: .bottom) {
            mediaSurface
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinchBaseline) { _, baseline, _ in
                    if baseline == nil {
                        baseline = PinchBaseline(scale: zoom.scale)
                    }
                }
                .onChanged { value in
                    guard isCurrent else { return }

                    let baseScale = pinchBaseline?.scale
                        ?? zoom.scale / max(value.magnification, 0.001)
                    let proposedScale = min(
                        max(baseScale * value.magnification, 1),
                        maximumPinchScale
                    )

                    zoom.scale = proposedScale
                    zoom.offset = clampedZoomOffset(
                        zoom.offset,
                        scale: proposedScale
                    )
                }
                .onEnded { _ in
                    guard isCurrent else { return }
                    zoom.offset = clampedZoomOffset(
                        zoom.offset,
                        scale: zoom.scale
                    )
                }
        )
    }

    @ViewBuilder
    private var mediaSurface: some View {
                SSPhotoViewerMediaSurface(
                    item: item,
                    imageContentMode: imageContentMode,
                    isPlaybackEnabled: isPlaybackEnabled,
                    // Native AVPlayer controls are disabled so the package can
                    // keep one stable, zoom-independent control surface.
                    showsPlaybackControls: false,
                    onReady: {
                        mediaReady = true
                        onReady()
                    },
                    onPlayerReady: onPlayerReady,
                    onAspectRatioReady: onAspectRatioReady
                )
            .frame(width: fittedSize.width, height: fittedSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(zoom.scale)
            .offset(
                x: zoom.offset.width + interactiveOffset.width,
                y: zoom.offset.height + interactiveOffset.height
            )
            .frame(width: contentSize.width, height: contentSize.height)
            .opacity(mediaReady ? 1 : 0)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fittedSize: CGSize {
        let ratio = contentSize.width / contentSize.height
        if aspectRatio > ratio {
            return CGSize(
                width: contentSize.width,
                height: contentSize.width / aspectRatio
            )
        }
        return CGSize(
            width: contentSize.height * aspectRatio,
            height: contentSize.height
        )
    }

    private var contentSize: CGSize {
        CGSize(
            width: max(1, size.width - horizontalInset * 2),
            height: size.height
        )
    }

    private func clampedZoomOffset(
        _ proposed: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maxX = max(0, (fittedSize.width * scale - contentSize.width) / 2)
        let maxY = max(0, (fittedSize.height * scale - contentSize.height) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

private struct SSPhotoViewerVideoControls: View {
    let item: SSPhotoViewerItem
    let player: AVPlayer
    let customContent: ((SSPhotoViewerVideoControlsContext) -> AnyView)?

    @State private var isScrubbing = false
    @State private var scrubValue = 0.0
    // Button actions update AVPlayer directly. This revision only forces an
    // immediate SwiftUI redraw; the rendered values always come back from the
    // player rather than from a second, independently mutable source of truth.
    @State private var controlRevision = 0

    private var duration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    private var currentTime: Double {
        let value = player.currentTime().seconds
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(duration, 0))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let _ = controlRevision
            let context = controlsContext

            if let customContent {
                customContent(context)
            } else {
                defaultControls(context: context)
            }
        }
        .padding(.horizontal, 10)
        // This control lives on the viewer's black presentation surface even
        // when the host app is using Light appearance. Liquid Glass adapts its
        // material, but semantic foreground colors still resolve from the
        // inherited color scheme, so give this isolated control hierarchy the
        // viewer's dark semantic context.
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.primary)
        .tint(.primary)
        .contentShape(Capsule())
        .zIndex(20)
    }

    private var controlsContext: SSPhotoViewerVideoControlsContext {
        SSPhotoViewerVideoControlsContext(
            item: item,
            timeControlStatus: player.timeControlStatus,
            isMuted: player.isMuted,
            currentTime: currentTime,
            duration: duration,
            togglePlayback: togglePlayback,
            toggleMute: toggleMute,
            seek: seek
        )
    }

    @ViewBuilder
    private func defaultControls(
        context: SSPhotoViewerVideoControlsContext
    ) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 8) {
                    playPauseButton(context: context)
                        .frame(width: 52, height: 52)
                        .glassEffect(.regular.interactive(), in: .circle)

                    seekControl(context: context)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .glassEffect(.regular.interactive(), in: .capsule)

                    muteButton(context: context)
                        .frame(width: 52, height: 52)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 8) {
                playPauseButton(context: context)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.5))

                seekControl(context: context)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.18), lineWidth: 0.5))

                muteButton(context: context)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.5))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func playPauseButton(
        context: SSPhotoViewerVideoControlsContext
    ) -> some View {
        Button {
            context.togglePlayback()
        } label: {
            Image(systemName: context.showsPauseAction ? "pause.fill" : "play.fill")
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(context.showsPauseAction ? "Pause video" : "Play video")
        .accessibilityValue(context.showsPauseAction ? "Playing" : "Paused")
    }

    private func seekControl(
        context: SSPhotoViewerVideoControlsContext
    ) -> some View {
        HStack(spacing: 8) {
            Text(formatTime(isScrubbing ? scrubValue : context.currentTime))
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 34, alignment: .leading)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : context.currentTime },
                    set: { value in
                        scrubValue = value
                        if isScrubbing {
                            context.seek(to: value)
                        }
                    }
                ),
                in: 0...max(context.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubValue = context.currentTime
                    } else {
                        context.seek(to: scrubValue)
                    }
                }
            )
            .tint(.primary)
            .accessibilityLabel("Video position")
            .accessibilityValue(
                "\(formatTime(isScrubbing ? scrubValue : context.currentTime)) of " +
                "\(formatTime(context.duration))"
            )

            Text(formatTime(context.duration))
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds > 0 || duration > 0 else {
            return "--:--"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainder = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func muteButton(
        context: SSPhotoViewerVideoControlsContext
    ) -> some View {
        Button {
            context.toggleMute()
        } label: {
            Image(systemName: context.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(context.isMuted ? "Unmute video" : "Mute video")
    }

    private func togglePlayback() {
        if player.timeControlStatus == .paused {
            player.playImmediately(atRate: 1)
        } else {
            player.pause()
        }
        controlRevision &+= 1
    }

    private func toggleMute() {
        player.isMuted.toggle()
        controlRevision &+= 1
    }

    private func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

private struct SSPhotoViewerThumbnailSurface: View {
    let item: SSPhotoViewerItem
    @State private var image: UIImage?

    init(item: SSPhotoViewerItem) {
        self.item = item

        if let thumbnailURL = item.thumbnailURL {
            _image = State(
                initialValue: SSPhotoViewerImageCache.images.object(
                    forKey: thumbnailURL as NSURL
                )
            )
        } else {
            switch item.media {
            case .image(let url):
                _image = State(
                    initialValue: SSPhotoViewerImageCache.images.object(
                        forKey: url as NSURL
                    )
                )
            case .video(_, let posterURL):
                if let posterURL {
                    _image = State(
                        initialValue: SSPhotoViewerImageCache.images.object(
                            forKey: posterURL as NSURL
                        )
                    )
                }
            }
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .secondarySystemFill)

                if item.media.isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: item.id) {
            if let thumbnailURL = item.thumbnailURL {
                image = await SSPhotoViewerMediaLoader.image(from: thumbnailURL)
            } else {
                switch item.media {
                case .image(let url):
                    image = await SSPhotoViewerMediaLoader.image(from: url)
                case .video(let url, let posterURL):
                    image = if let posterURL {
                        await SSPhotoViewerMediaLoader.image(from: posterURL)
                    } else {
                        await SSPhotoViewerMediaLoader.firstVideoFrame(from: url)
                    }
                case .videoAsset(let asset, let posterURL):
                    image = if let posterURL {
                        await imageLoader?(posterURL)
                    } else {
                        await SSPhotoViewerMediaLoader.firstVideoFrame(from: asset)
                    }
                }
            }
        }
    }
}

private struct SSPhotoViewerVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsPlaybackControls: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
    }
}

private struct SSPhotoViewerMediaSurface: View {
    let item: SSPhotoViewerItem
    let imageContentMode: ContentMode
    let placeholderColor: Color
    let isPlaybackEnabled: Bool
    let usesStaticVisual: Bool
    let usesThumbnailVisual: Bool
    let showsPlaybackControls: Bool
    var onReady: (() -> Void)? = nil
    var onPlayerReady: ((AVPlayer) -> Void)? = nil
    var onAspectRatioReady: ((CGFloat) -> Void)? = nil
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var didSignalReady = false

    init(
        item: SSPhotoViewerItem,
        imageContentMode: ContentMode = .fit,
        placeholderColor: Color = .black,
        isPlaybackEnabled: Bool = false,
        usesStaticVisual: Bool = false,
        usesThumbnailVisual: Bool = false,
        showsPlaybackControls: Bool = true,
        onReady: (() -> Void)? = nil,
        onPlayerReady: ((AVPlayer) -> Void)? = nil,
        onAspectRatioReady: ((CGFloat) -> Void)? = nil
    ) {
        self.item = item
        self.imageContentMode = imageContentMode
        self.placeholderColor = placeholderColor
        self.isPlaybackEnabled = isPlaybackEnabled
        self.usesStaticVisual = usesStaticVisual
        self.usesThumbnailVisual = usesThumbnailVisual
        self.showsPlaybackControls = showsPlaybackControls
        self.onReady = onReady
        self.onPlayerReady = onPlayerReady
        self.onAspectRatioReady = onAspectRatioReady

        if case .image(let url) = item.media {
            let initialVisualURL = usesThumbnailVisual
                ? (item.thumbnailURL ?? url)
                : url
            _image = State(
                initialValue: SSPhotoViewerImageCache.images.object(
                    forKey: initialVisualURL as NSURL
                )
            )
        }
    }

    var body: some View {
        ZStack {
            placeholderColor
            switch item.media {
            case .image:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: imageContentMode)
                } else {
                    placeholderColor
                }
            case .video, .videoAsset:
                if usesStaticVisual, let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: imageContentMode)
                } else if let player, !usesStaticVisual {
                    SSPhotoViewerVideoPlayer(
                        player: player,
                        showsPlaybackControls: showsPlaybackControls
                    )
                } else {
                    placeholderColor
                }
            }
        }
        .task(id: item.id) {
            switch item.media {
            case .image(let url):
                if usesThumbnailVisual, let thumbnailURL = item.thumbnailURL {
                    let preview = await SSPhotoViewerMediaLoader.image(from: thumbnailURL)
                    if let preview {
                        image = preview
                        if item.thumbnailPreservesMediaAspectRatio {
                            // This is an explicit host guarantee that the
                            // preview is uncropped, so it can provide immediate
                            // opening geometry without waiting for full media.
                            onAspectRatioReady?(preview.size.width / preview.size.height)
                        }
                        // The preview is sufficient to establish the opening
                        // visual, but not authoritative geometry: CDN previews
                        // can be cropped or use the wrong video orientation.
                        signalReady()
                    }

                    if let full = await SSPhotoViewerMediaLoader.image(from: url) {
                        // Keep the handoff surface on the exact source preview.
                        // The fullscreen page loads and displays `full`; this
                        // surface only needs its authoritative dimensions so
                        // its container can morph to the correct destination.
                        onAspectRatioReady?(full.size.width / full.size.height)
                        if preview == nil {
                            image = full
                            signalReady()
                        }
                    }
                } else if let cached = SSPhotoViewerImageCache.images.object(forKey: url as NSURL) {
                    image = cached
                    onAspectRatioReady?(cached.size.width / cached.size.height)
                    signalReady()
                } else if let decoded = await SSPhotoViewerMediaLoader.image(from: url) {
                    image = decoded
                    onAspectRatioReady?(decoded.size.width / decoded.size.height)
                    signalReady()
                }
            case .video(let url, let posterURL):
                // A poster/thumbnail is only a visual fallback. Its dimensions
                // are not authoritative: a portrait video commonly has a
                // landscape CDN thumbnail. Resolve the video's preferred track
                // transform first so the page uses the actual display ratio.
                let videoRatio = await SSPhotoViewerMediaLoader.videoAspectRatio(from: url)
                if let videoRatio {
                    onAspectRatioReady?(videoRatio)
                }

                let poster: UIImage?
                if let previewURL = item.thumbnailURL ?? posterURL {
                    poster = await SSPhotoViewerMediaLoader.image(from: previewURL)
                } else {
                    poster = await SSPhotoViewerMediaLoader.firstVideoFrame(from: url)
                }
                if let poster {
                    image = poster
                    if videoRatio == nil {
                        onAspectRatioReady?(poster.size.width / poster.size.height)
                    }
                }

                if usesStaticVisual {
                    // The return hero must remain a single lightweight image
                    // layer. Starting another AVPlayer here competes with the
                    // fullscreen player and makes the handoff feel heavy.
                    signalReady()
                } else {
                    let newPlayer = AVPlayer(url: url)
                    // Video pages start silently. The native VideoPlayer controls
                    // still allow the user to opt into audio explicitly.
                    newPlayer.isMuted = true
                    player = newPlayer
                    onPlayerReady?(newPlayer)
                    if isPlaybackEnabled {
                        newPlayer.play()
                    }
                    signalReady()
                }
            case .videoAsset(let asset, let posterURL):
                let videoRatio = await SSPhotoViewerMediaLoader.videoAspectRatio(from: asset)
                if let videoRatio { onAspectRatioReady?(videoRatio) }
                let poster = if let previewURL = item.thumbnailURL ?? posterURL {
                    await loadImage(from: previewURL)
                } else {
                    await SSPhotoViewerMediaLoader.firstVideoFrame(from: asset)
                }
                if let poster {
                    image = poster
                    if videoRatio == nil { onAspectRatioReady?(poster.size.width / poster.size.height) }
                }
                if usesStaticVisual {
                    signalReady()
                } else {
                    let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    newPlayer.isMuted = true
                    player = newPlayer
                    onPlayerReady?(newPlayer)
                    if isPlaybackEnabled { newPlayer.play() }
                    signalReady()
                }
            }
        }
        .onChange(of: isPlaybackEnabled) { _, isEnabled in
            guard let player else { return }
            if isEnabled {
                // Adjacent video pages are intentionally prepared before they
                // become current. Their first readiness callback is rejected
                // by the viewer, so publish the already-created player again
                // when selection enables playback. This keeps the controls a
                // direct conditional of the current video's player.
                onPlayerReady?(player)
                player.isMuted = true
                player.play()
            } else {
                player.pause()
                player.isMuted = true
            }
        }
        .onDisappear {
            player?.pause()
            player?.isMuted = true
            player = nil
        }
    }

    private func signalReady() {
        guard !didSignalReady else { return }
        didSignalReady = true

        // Let the preview render before the opening hero hides the source.
        DispatchQueue.main.async {
            onReady?()
        }
    }
}

private enum SSPhotoViewerMediaLoader {
    static let maxImagePixelSize = 2048

    static func image(from url: URL) async -> UIImage? {
        if let cached = await MainActor.run(body: {
            SSPhotoViewerImageCache.images.object(forKey: url as NSURL)
        }) {
            return cached
        }

        let data: Data
        if let diskData = await SSPhotoViewerDiskImageCache.shared.data(for: url) {
            data = diskData
        } else if let networkData = try? await URLSession.shared.data(from: url).0 {
            data = networkData
            await SSPhotoViewerDiskImageCache.shared.store(networkData, for: url)
        } else {
            return nil
        }

        guard !data.isEmpty,
              !Task.isCancelled else {
            return nil
        }

        let cgImage = await Task.detached(priority: .userInitiated) {
            downsampledImage(data: data, maxPixelSize: maxImagePixelSize)
        }.value

        guard let cgImage, !Task.isCancelled else { return nil }
        let decoded = UIImage(cgImage: cgImage)

        await MainActor.run {
            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            SSPhotoViewerImageCache.images.setObject(
                decoded,
                forKey: url as NSURL,
                cost: cost
            )
        }
        return decoded
    }

    static func firstVideoFrame(from url: URL) async -> UIImage? {
        return await firstVideoFrame(from: AVURLAsset(url: url))
    }

    static func firstVideoFrame(from asset: AVAsset) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil),
              !Task.isCancelled else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func videoAspectRatio(from url: URL) async -> CGFloat? {
        return await videoAspectRatio(from: AVURLAsset(url: url))
    }

    static func videoAspectRatio(from asset: AVAsset) async -> CGFloat? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }

            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displaySize = naturalSize.applying(transform)
            let width = abs(displaySize.width)
            let height = abs(displaySize.height)

            guard width > 0, height > 0 else { return nil }
            return width / height
        } catch {
            return nil
        }
    }

    private static func downsampledImage(
        data: Data,
        maxPixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
        )
    }
}

/// A bounded on-device data cache beneath the decoded-image NSCache.
private actor SSPhotoViewerDiskImageCache {
    static let shared = SSPhotoViewerDiskImageCache()
    private static let maximumBytes = 256 * 1024 * 1024
    private static let directoryName = "SSPhotoViewer.Images"

    private static var directoryURL: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    func data(for url: URL) -> Data? {
        let fileURL = Self.fileURL(for: url)
        return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    func store(_ data: Data, for url: URL) {
        let directory = Self.directoryURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: Self.fileURL(for: url), options: .atomic)
            Self.pruneIfNeeded(in: directory)
        } catch {
            // Disk caching is opportunistic; memory and network loading remain
            // the source of truth when the device cache is unavailable.
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.directoryURL)
    }

    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent(digest).appendingPathExtension("data")
    }

    private static func pruneIfNeeded(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (file, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            guard total > maximumBytes else { break }
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}

@MainActor
private enum SSPhotoViewerImageCache {
    static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
}
