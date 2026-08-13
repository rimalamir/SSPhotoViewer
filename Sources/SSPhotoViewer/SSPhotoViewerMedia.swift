import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum Interaction: Equatable {
    case idle
    case vertical
    case horizontal
}

struct ZoomState {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

private struct PinchBaseline: Equatable {
    let scale: CGFloat
}

struct ReturnFrame {
    let item: SSPhotoViewerItem
    var frame: CGRect
    var cornerRadius: CGFloat
}

enum ReturnDirection {
    case horizontal
    case vertical
}

struct SSPhotoViewerMediaPage: View {
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
    let imageLoader: SSPhotoViewerImageLoader?
    let cachedImageLookup: SSPhotoViewerCachedImageLookup?

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
                    imageLoader: imageLoader,
                    cachedImageLookup: cachedImageLookup,
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

struct SSPhotoViewerVideoControls: View {
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

struct SSPhotoViewerThumbnailSurface: View {
    let item: SSPhotoViewerItem
    let imageLoader: SSPhotoViewerImageLoader?
    let cachedImageLookup: SSPhotoViewerCachedImageLookup?
    @State private var image: UIImage?

    init(
        item: SSPhotoViewerItem,
        imageLoader: SSPhotoViewerImageLoader? = nil,
        cachedImageLookup: SSPhotoViewerCachedImageLookup? = nil
    ) {
        self.item = item
        self.imageLoader = imageLoader
        self.cachedImageLookup = cachedImageLookup
        _image = State(
            initialValue: item.preferredThumbnailURL.flatMap {
                cachedImageLookup?($0)
            }
        )
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
        .task(id: item) {
            image = nil
            if let thumbnailURL = item.thumbnailURL {
                image = await imageLoader?(thumbnailURL)
            } else {
                switch item.media {
                case .image(let url):
                    image = await imageLoader?(url)
                case .video(let url, let posterURL):
                    image = if let posterURL {
                        await imageLoader?(posterURL)
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

struct SSPhotoViewerMediaSurface: View {
    let item: SSPhotoViewerItem
    let imageContentMode: ContentMode
    let placeholderColor: Color
    let isPlaybackEnabled: Bool
    let usesStaticVisual: Bool
    let usesThumbnailVisual: Bool
    let showsPlaybackControls: Bool
    let imageLoader: SSPhotoViewerImageLoader?
    let cachedImageLookup: SSPhotoViewerCachedImageLookup?
    let requiresAuthoritativeAspectRatio: Bool
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
        imageLoader: SSPhotoViewerImageLoader? = nil,
        cachedImageLookup: SSPhotoViewerCachedImageLookup? = nil,
        requiresAuthoritativeAspectRatio: Bool = false,
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
        self.imageLoader = imageLoader
        self.cachedImageLookup = cachedImageLookup
        self.requiresAuthoritativeAspectRatio = requiresAuthoritativeAspectRatio
        self.onReady = onReady
        self.onPlayerReady = onPlayerReady
        self.onAspectRatioReady = onAspectRatioReady

        let seedURL: URL?
        if usesThumbnailVisual {
            seedURL = item.thumbnailURL ?? item.preferredThumbnailURL
        } else {
            switch item.media {
            case .image(let url):
                seedURL = url
            case .video(_, let posterURL),
                 .videoAsset(_, let posterURL):
                seedURL = item.thumbnailURL ?? posterURL
            }
        }
        _image = State(
            initialValue: seedURL.flatMap { cachedImageLookup?($0) }
        )
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
        .task(id: item) {
            player?.pause()
            player = nil
            didSignalReady = false

            // A cached seed is already rendered at the opening frame. Claim
            // readiness immediately when its geometry is authoritative; the
            // async loader below can still refresh the image without creating
            // a placeholder transaction.
            if let image,
               image.size.width > 0,
               image.size.height > 0 {
                onAspectRatioReady?(image.size.width / image.size.height)
                let seedIsAuthoritative = !usesThumbnailVisual
                    || item.thumbnailURL == nil
                    || item.aspectRatio != nil
                    || item.thumbnailPreservesMediaAspectRatio
                if !requiresAuthoritativeAspectRatio || seedIsAuthoritative {
                    signalReady()
                }
            }

            switch item.media {
            case .image(let url):
                if usesThumbnailVisual, let thumbnailURL = item.thumbnailURL {
                    let preview = await loadImage(from: thumbnailURL)
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
                        if !requiresAuthoritativeAspectRatio ||
                            item.thumbnailPreservesMediaAspectRatio {
                            signalReady()
                        }
                    }

                    if let full = await loadImage(from: url) {
                        // Keep the handoff surface on the exact source preview.
                        // The fullscreen page loads and displays `full`; this
                        // surface only needs its authoritative dimensions so
                        // its container can morph to the correct destination.
                        if !item.thumbnailPreservesMediaAspectRatio {
                            onAspectRatioReady?(full.size.width / full.size.height)
                        }
                        if preview == nil {
                            image = full
                            signalReady()
                        } else if requiresAuthoritativeAspectRatio {
                            signalReady()
                        }
                    }
                } else if let decoded = await loadImage(from: url) {
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
                    poster = await loadImage(from: previewURL)
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

    private func loadImage(from url: URL) async -> UIImage? {
        if let imageLoader {
            return await imageLoader(url)
        }
        return nil
    }
}

private enum SSPhotoViewerMediaLoader {
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

}
