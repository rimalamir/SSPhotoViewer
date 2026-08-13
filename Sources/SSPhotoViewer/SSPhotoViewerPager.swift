import AVFoundation
import SwiftUI

struct SSPhotoViewer: View {
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
                items.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        _zoom = State(
            initialValue: Dictionary(
                items.map { ($0.id, ZoomState()) },
                uniquingKeysWith: { first, _ in first }
            )
        )
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
            .onChange(of: items) { _, newItems in
                synchronizeExternallySuppliedItems(newItems)
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

    private func synchronizeExternallySuppliedItems(
        _ newItems: [SSPhotoViewerItem]
    ) {
        let reconciliation = SSPhotoViewerItemReconciliation.apply(
            incoming: newItems,
            to: loadedItems
        )
        loadedItems = reconciliation.items

        for replacement in reconciliation.replacements {
            zoom[replacement.previous.id] = ZoomState()
            zoom[replacement.incoming.id] = ZoomState()
            resolvedAspectRatios.removeValue(forKey: replacement.previous.id)
            resolvedAspectRatios.removeValue(forKey: replacement.incoming.id)
        }

        loadedIndexByID = SSPhotoViewerItemReconciliation.indexMap(
            for: loadedItems
        )

        guard reconciliation.replacements.contains(where: {
            $0.index == selectedIndex
        }) else { return }

        // A replaced current video must relinquish playback immediately. The
        // replacement page gets a fresh identity below and will create its own
        // player only after it becomes current.
        activeVideoPlayer?.pause()
        activeVideoPlayer = nil
        activeVideoPlayerID = nil
        fullscreenMediaReadyID = nil
        liveZoomPanOffset = .zero
        lastPanTranslation = .zero
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
        let indices: [Int] = pagerIndices
        return ZStack(alignment: .topLeading) {
            ForEach(indices, id: \.self) { (index: Int) in
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
                    interactiveOffset: index == selectedIndex ? liveZoomPanOffset : .zero,
                    imageLoader: configuration.imageLoader,
                    cachedImageLookup: configuration.cachedImageLookup
                )
                // Include the complete value, not only the stable ID. A host
                // can replace the media at an existing index; changing the
                // view identity tears down the old image/player task and
                // prevents stale content from surviving that replacement.
                .id(item)
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
        if let last = loadedItems.compactMap({ sourceFrames[$0.id] }).last {
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
                                    SSPhotoViewerThumbnailSurface(
                                        item: item,
                                        imageLoader: configuration.imageLoader,
                                        cachedImageLookup: configuration.cachedImageLookup
                                    )
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
            usesThumbnailVisual: true,
            imageLoader: configuration.imageLoader,
            cachedImageLookup: configuration.cachedImageLookup
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
            imageLoader: configuration.imageLoader,
            cachedImageLookup: configuration.cachedImageLookup,
            requiresAuthoritativeAspectRatio: true,
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

            let nearestID = frames.min {
                abs($0.value.midX - viewportWidth / 2)
                    < abs($1.value.midX - viewportWidth / 2)
            }?.key

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
