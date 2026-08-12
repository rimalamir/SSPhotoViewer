# SSPhotoViewer

`SSPhotoViewer` is a SwiftUI photo and video viewer with Photos-style fullscreen
paging, zooming, interactive dismissal, source-to-viewer handoff animations,
video playback, pagination, and completely caller-owned home screens.

The package is deliberately **BYOH: bring your own home**. It does not own your
grid, timeline, messages, navigation, repository, filtering, or persistence. It
wraps that UI in the same SwiftUI hierarchy and temporarily takes ownership of
the selected media while fullscreen.

This repository contains the reusable package only. The companion demo apps
are maintained separately in the `SSPhotoViewerExamples` repository.


https://github.com/user-attachments/assets/5b85f7a2-6b64-4f7a-aa70-50be8611c090


## What the package supports

- Remote or local image URLs.
- Remote or local video URLs with optional posters.
- Unknown image/video aspect ratios resolved from real media at runtime.
- Optional lightweight thumbnails for faster cold-cache handoffs.
- Horizontal paging with page-local zoom reset.
- Pinch and double-tap zoom with bounded panning.
- Interactive free-direction drag after a vertical dismissal begins.
- Source-aware dismissal back to the current live home frame.
- Offscreen or fixed fallback dismissal destinations.
- A centered, lazy media strip that participates in pagination.
- Independent home and viewer media sequences.
- Viewer-driven asynchronous pagination.
- Package default chrome or media-aware custom top/bottom chrome.
- Package default video controls or fully custom play/pause, seek, and mute UI.
- Minimal and detail modes controlled by taps or custom chrome.
- iOS 26 Liquid Glass in the package defaults with material fallbacks on iOS 17–25.
- Accessibility labels and app-owned semantic actions.
- A bounded visible page window suitable for large media sequences.

## Requirements

- iOS 17 or later.
- Swift 5.10 tools or later.
- SwiftUI.
- Xcode capable of building the selected iOS SDK.

The package uses iOS 26 APIs only behind availability checks.

## Installation

Add the package repository URL in Xcode:

1. Open **File → Add Package Dependencies**.
2. Enter `https://github.com/rimalamir/SSPhotoViewer.git`.
3. Select a version rule.
4. Add the `SSPhotoViewerAdapter` product to your app target.

For local development, add this repository root as a local package. The root
contains `Package.swift` and exposes the `SSPhotoViewerAdapter` library product.

The lower-level `SSPhotoViewer` target is an internal implementation dependency
of the adapter and is intentionally not exposed as an SPM product. App chat and
gallery targets should import only `SSPhotoViewerAdapter`.

Example applications are available in the companion repository:
`https://github.com/rimalamir/SSPhotoViewerExamples`.

```swift
import SSPhotoViewerAdapter
import SwiftUI
```

## The ownership model

The visual handoff has three owners:

```text
Presentation:  home source → preview hero → fullscreen page
Dismissal:     fullscreen page → return hero → home source
```

`SSPhotoViewerHost` keeps these layers in one SwiftUI hierarchy. A source stays
mounted while the transition hero prepares. The package hides only the selected
source after the hero can render it, and restores the source only after dismissal
finishes. The host is an overlay around your `home` view: it does not impose a
frame, background, safe-area inset, or container layout on that view. Place the
host where the app owns the screen's desired size; the package expands only the
active fullscreen viewer layer.

These are visual invariants for every presentation style:

- Presentation is source-to-viewer; dismissal is the same handoff in reverse.
- The media returns to the exact selected source that opened it, when that source
  is available. It must not jump to a different thumbnail or create a second
  copy of the media during the handoff.
- The backdrop fade is continuous. It must not flash, reset, or be owned by two
  independent presentation layers.
- The viewer's media layout, zoom, video controls, pagination strip, and chrome
  are unchanged by the presentation container.
- The host remains layout-neutral: no safe-area, navigation-bar, tab-bar, sheet,
  split-view, or Stage Manager geometry is modified outside the active viewer.

The presentation container may change how the viewer covers its host, but it is
not allowed to change these visual semantics. In particular, a native
`fullScreenCover` must not be combined with a second return-thumbnail animation.

### Choose a presentation style

Use the default `.sameHierarchy` style for normal integrations. It preserves the
source-aware hero animation, keeps the viewer in the same SwiftUI hierarchy,
and is the recommended choice.

```swift
SSPhotoViewerHost(
    isPresented: $isViewerPresented,
    selectedID: $selectedID,
    items: items
) {
    YourScreen()
}
```

Use `.fullScreen` only when the host is already inside a sheet or another
presentation boundary and the viewer must cover that presentation. It uses the
scene-bound native full-screen presentation and does not manage a global
`UIWindow`. The native cover owns the outer presentation boundary; the viewer
still owns its content, opening handoff, and gradual backdrop fade.
The cover background is transparent and its system swipe-to-dismiss is disabled
so there is one visual transition owner. The full-screen path uses the same
source-aware opening and return handoff as `.sameHierarchy`; the native cover
transition itself is disabled so it cannot add a slide from below or a second
thumbnail animation.

```swift
SSPhotoViewerHost(
    isPresented: $isViewerPresented,
    selectedID: $selectedID,
    items: items,
    presentationStyle: .fullScreen
) {
    SheetGalleryView()
}
```

Do not wrap `isViewerPresented = true` in `withAnimation`. The same-hierarchy
viewer owns its transition and uses `.transition(.identity)` to avoid a second
animation owner. The full-screen style uses the system presentation transition.
The two styles may differ in their outer container transition, but they must
preserve the visual invariants above and must never change the viewer's design.

## Adapter viewer API

`SSPhotoViewerAdapter` is the public viewer facade. Chat and gallery import this
product directly and provide their app-owned `ImageViewerAsset` values. They do
not create another adapter and do not import the private lower-level viewer
target.

```swift
import SSPhotoViewerAdapter

struct AppImage: ImageViewerAsset {
    let imageViewerID: String
    let imageViewerMedia: ImageViewerMedia
    let imageViewerThumbnailURL: URL?
    let imageViewerAccessibilityLabel: String?
}
```

The app supplies its asset type and owns the shared presentation/selection
bindings:

```swift
struct MediaScene: View {
    let assets: [AppImage]
    @State private var isViewerPresented = false
    @State private var selectedID = ""

    var body: some View {
        let adapter = ImageViewerAdapter(
            assets: assets,
            isPresented: $isViewerPresented,
            selectedID: $selectedID,
            policy: ImageViewerPresentationPolicy<AppImage>(
                presentationStyle: .sameHierarchy,
                showsDefaultTopBar: false,
                showsDefaultPaginationStrip: true,
                showsDefaultActionBar: false,
                showsVideoControls: true
            )
        )

        adapter.host {
            NavigationStack {
                GalleryView(assets: assets, adapter: adapter)
            }
        }
    }
}
```

Both chat and gallery use the same `ImageViewerAdapter` instance. The adapter
converts assets, maps presentation policy, builds the private viewer
configuration, owns source registration, and writes the app-owned
selection/presentation bindings:

```swift
struct GalleryView: View {
    let assets: [AppImage]
    let adapter: ImageViewerAdapter<AppImage>

    var body: some View {
        ForEach(assets, id: \.imageViewerID) { asset in
            adapter.source(for: asset) {
                AssetThumbnail(asset)
            }
            .onTapGesture {
                adapter.present(asset)
            }
        }
    }
}
```

### Source readiness and the preparation loader

Readiness belongs to the app because the app owns the thumbnail view and its
image-loading phase. It is separate from viewer readiness: the package still
waits for its own handoff preview and final media geometry before moving the
hero.

Report the state that matches the visual rendered by the source:

```swift
struct AssetThumbnailSource: View {
    let asset: AppImage
    let adapter: ImageViewerAdapter<AppImage>
    @ObservedObject var imageLoader: ThumbnailLoader

    var body: some View {
        adapter.source(
            for: asset,
            readiness: imageLoader.image == nil
                ? .loading
                : .ready,
            preparationOverlay: {
                ProgressView()
                    .accessibilityLabel("Loading thumbnail")
            }
        ) {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
    }
}
```

Use the states as follows:

- `.ready`: the source content is already drawable. No preparation loader is
  shown, even when a custom `preparationOverlay` is supplied.
- `.loading`: the source content is not drawable yet. The default spinner or
  the supplied custom overlay is shown while the source remains mounted.
- `.unknown`: the default for existing integrations. Use it when the app does
  not have a trustworthy source image phase; the package behaves conservatively
  and may show the preparation loader.

Readiness must be derived from the same state that renders the source and must
update reactively. Do not mark a placeholder as `.ready` unless that placeholder
is the exact visual you want the opening hero to use. Do not use `.ready` to
mean that the full-resolution viewer asset is cached; it only means the
app-owned source visual is available.

The direct package modifier has the same contract:

```swift
thumbnail
    .ssPhotoViewerSource(
        id: item.id,
        readiness: thumbnailImage == nil ? .loading : .ready
    )
```

Readiness is optional and backward-compatible. Omitting it is equivalent to
`.unknown`.

When using `SSPhotoViewerAdapter`, the public name is
`ImageViewerSourceReadiness`. It is a typealias for the same three-state
contract, so an adapter consumer does not import the lower-level viewer target:

```swift
let readiness: ImageViewerSourceReadiness = .ready
adapter.source(for: asset, readiness: readiness) {
    AppThumbnail(asset: asset)
}
```

The consuming app is expected to provide stable IDs, media URLs, optional
geometry/thumbnail metadata, and the presentation policy. App repositories,
authorization, chat models, gallery models, and navigation remain outside the
package. The adapter is the only public viewer surface.

### Root placement for iPhone and iPad

For `.sameHierarchy`, place the host around the complete screen or scene root,
above your navigation or tab container. This is important for iPad
`NavigationSplitView`, `TabView`, and Stage Manager: the viewer can cover the
sidebar, detail column, and tab bar only when the host overlays that root. A
host placed inside a detail column or tab can cover only that child because
SwiftUI does not allow a child view to draw over a sibling or its parent chrome.

If the complete screen is already presented as a sheet, use
`presentationStyle: .fullScreen` on the host inside that sheet when the viewer
must cover the sheet and the scene window.

```swift
struct MediaScene: View {
    @State private var isViewerPresented = false
    @State private var selectedID = "photo-1"

    let items: [SSPhotoViewerItem]

    var body: some View {
        SSPhotoViewerHost(
            isPresented: $isViewerPresented,
            selectedID: $selectedID,
            items: items
        ) {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView {
                    Sidebar()
                } detail: {
                    Gallery(items: items, selectedID: $selectedID,
                            isViewerPresented: $isViewerPresented)
                }
            } else {
                NavigationStack {
                    Gallery(items: items, selectedID: $selectedID,
                            isViewerPresented: $isViewerPresented)
                }
            }
            #endif
        }
    }
}
```

The package remains navigation-agnostic: `Sidebar`, `Gallery`, and the
navigation container remain application-owned. In a multiwindow or Stage
Manager app, attach one host to each scene's root rather than managing a global
`UIWindow` overlay. If the screen itself is a sheet, use `.fullScreen` only for
the viewer host inside that sheet.

## Quick start

Use stable media identity, place the host around the complete screen root, and
register the visual thumbnail as a source.

```swift
struct LibraryScreen: View {
    @State private var isViewerPresented = false
    @State private var selectedID = "photo-1"

    private let items: [SSPhotoViewerItem] = [
        SSPhotoViewerItem(
            id: "photo-1",
            media: .image(URL(string: "https://example.com/full/photo-1.jpg")!),
            thumbnailURL: URL(string: "https://example.com/thumb/photo-1.jpg"),
            accessibilityLabel: "Mountain lake at sunrise"
        )
    ]

    var body: some View {
        SSPhotoViewerHost(
            isPresented: $isViewerPresented,
            selectedID: $selectedID,
            items: items
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) {
                ForEach(items) { item in
                    AsyncImage(url: item.preferredThumbnailURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .ssPhotoViewerSource(id: item.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = item.id
                        isViewerPresented = true
                    }
                }
            }
        }
    }
}
```

## Creating media items

### Images

```swift
let item = SSPhotoViewerItem(
    id: asset.id,
    media: .image(asset.fullURL),
    aspectRatio: asset.width.map { width in
        guard let height = asset.height, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    } ?? nil,
    thumbnailURL: asset.thumbnailURL,
    thumbnailPreservesMediaAspectRatio: asset.thumbnailIsUncropped,
    accessibilityLabel: asset.altText
)
```

`aspectRatio` is width divided by height. It is optional. If omitted, the
package waits for decoded full-image dimensions before calculating final viewer
geometry. Supplying it is an optimization that can reduce cold-cache latency.

### Videos

```swift
let item = SSPhotoViewerItem(
    id: video.id,
    media: .video(video.url, posterURL: video.posterURL),
    aspectRatio: nil,
    thumbnailURL: video.smallPosterURL,
    accessibilityLabel: "Short video from the beach"
)
```

For unknown video geometry, the package resolves the transformed video track
dimensions. A poster provides immediate static UI for strips and handoffs. A
posterless video still plays, but its thumbnail surface has no static image until
a frame can be resolved.

### Thumbnail rules

- `thumbnailURL` is a lightweight static visual, not the fullscreen resource.
- Set `thumbnailPreservesMediaAspectRatio` only for an uncropped rendition.
- A server-side square crop should leave that flag `false`.
- Final fullscreen geometry never trusts a cropped thumbnail when the real
  image/video ratio can be resolved.
- `preferredThumbnailURL` chooses `thumbnailURL`, then video poster, then the
  full image URL. It returns `nil` for a posterless video.

## Registering source views

Apply `.ssPhotoViewerSource(id:)` to the exact visual rectangle the fullscreen
media should return to:

```swift
thumbnail
    .frame(width: 120, height: 120)
    .clipped()
    .ssPhotoViewerSource(id: item.id)
```

Avoid applying it to an entire row when only a smaller image is the destination.
The source can live in `LazyVGrid`, `LazyVStack`, `List`, a message bubble, or a
custom layout. The package continuously receives frames only from mounted views.

### Custom preparation UI

When cold media needs a moment before handoff, the default source overlay is a
small indeterminate circular progress indicator. Replace it per source:

```swift
thumbnail.ssPhotoViewerSource(id: item.id) {
    ProgressView()
        .controlSize(.regular)
        .padding(12)
        .background(.regularMaterial, in: Circle())
        .accessibilityLabel("Opening photo")
}
```

The package removes this overlay on success, cancellation, timeout, or source
disappearance. The real source is not hidden merely because presentation was
requested; it remains visible until the transition hero owns the pixels.

## Selection: index or stable ID

Two host initializers are available.

### Stable ID — recommended

```swift
SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedID: $selectedID,
    items: viewerItems
) {
    home
}
```

Use this when home and viewer arrays may differ by filtering or ordering. Set
the tapped home item's ID, then present. The ID must exist in `viewerItems`.

### Viewer index

```swift
SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedIndex: $selectedIndex,
    items: viewerItems
) {
    home
}
```

`selectedIndex` always means an index in the **viewer sequence**. If a home item
is tapped, map its ID into `viewerItems` before setting the index:

```swift
guard let viewerIndex = viewerItems.firstIndex(where: { $0.id == homeItem.id })
else { return }

selectedIndex = viewerIndex
isPresented = true
```

## Pagination and independent data sources

The viewer can request pages without owning home pagination.

```swift
@State private var homeItems: [SSPhotoViewerItem] = initialHome
@State private var viewerItems: [SSPhotoViewerItem] = initialViewer

private func loadViewerPage(_ number: Int) async -> SSPhotoViewerPage {
    let response = await repository.mediaPage(number)
    let homePage = response.items                 // app policy
    let viewerPage = response.items.filter(canViewFullscreen)

    await MainActor.run {
        appendUnique(homePage, to: &homeItems)
        appendUnique(viewerPage, to: &viewerItems)
    }

    return SSPhotoViewerPage(
        items: viewerPage,
        hasMore: response.hasMore
    )
}
```

Then provide it:

```swift
let configuration = SSPhotoViewerConfiguration(
    pageLoader: loadViewerPage
)
```

The caller may also push eagerly loaded media into an already-presented viewer.
Append to the `viewerItems` passed to `SSPhotoViewerHost`; SwiftUI delivers the
new value and the package merges the append-only suffix immediately. There is
no polling loop.

When eager push and viewer-driven pull are both enabled, also pass a cursor so
the viewer does not request pages the repository has already accepted:

```swift
@State private var viewerItems = initialViewer
@State private var viewerCursor = SSPhotoViewerPaginationCursor(
    nextPageNumber: 1,
    hasMore: true
)

SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedID: $selectedID,
    items: viewerItems,
    paginationCursor: viewerCursor,
    configuration: SSPhotoViewerConfiguration(
        pageLoader: loadViewerPage
    )
) {
    home
}

private func acceptEagerPage(
    _ page: SSPhotoViewerPage,
    number: Int
) {
    appendUnique(page.items, to: &viewerItems)
    viewerCursor = SSPhotoViewerPaginationCursor(
        nextPageNumber: number + 1,
        hasMore: page.hasMore
    )
}
```

Advancing `paginationCursor` can cancel an older in-flight viewer request for a
page the eager path has already supplied. Keep repository requests idempotent or
coalesced because the application and viewer can approach the same boundary in
the same run-loop interval.

Pagination rules:

1. Initial host items are page `0`.
2. Loader requests begin at page `1` and increase monotonically.
3. Duplicate IDs returned by a page are ignored.
4. The package prefetches near the current end and near the strip's mounted end.
5. Custom strips can call `context.requestNextPage()` explicitly.
6. Selecting the final items through the built-in strip or `context.select(...)`
   also evaluates the prefetch boundary.
7. Externally appended host items are accepted without a viewer request.
8. In hybrid eager/pull mode, advance `paginationCursor` with each accepted page.
9. The home may display the same, more, fewer, or differently ordered media.
10. If paginated viewer media should dismiss to home, update home first so its
   source can eventually mount and report a live frame.
11. Source geometry is not network data. It comes from currently mounted
   `.ssPhotoViewerSource(id:)` views.

## Custom top and bottom chrome

The typed fluent builders avoid `AnyView` at the call site:

```swift
let configuration = SSPhotoViewerConfiguration(
    pageLoader: loadViewerPage,
    onAction: handleAction
)
.customTopBar { context in
    HStack {
        Button(action: context.dismiss) {
            Image(systemName: "chevron.left")
        }

        Spacer()

        Text(context.item.accessibilityLabel ?? "Media")

        Spacer()

        Text("\(context.selectedIndex + 1)/\(context.itemCount)")
    }
}
.customBottomBar { context in
    MyMediaStrip(
        items: context.items,
        selectedID: context.item.id,
        onSelect: context.select(id:)
    )
}
```

`SSPhotoViewerChromeContext` exposes:

| State | Meaning |
| --- | --- |
| `item` | Current selected media |
| `items` | Complete currently loaded viewer sequence |
| `selectedIndex` | Current index in that sequence |
| `itemCount` | Loaded count |
| `isZoomed` | Current media zoom exceeds fitted scale |
| `isVideo` | Current item is video |
| `displayMode` | `.minimal` or `.detail` |
| `pagination` | Loading, `hasMore`, and next page number |

It also exposes safe commands:

- `dismiss()` — source-aware viewer dismissal.
- `select(index:)` and `select(id:)` — update viewer selection.
- `setDisplayMode(_:)` and `toggleDisplayMode()`.
- `requestNextPage()` — useful at a custom strip boundary.
- `perform(_:)` — route an app action through `onAction`.

Do not retain a context in a view model. It is a render-time snapshot with
commands tied to the current viewer instance.

### Static chrome

For media-independent content, `topBar` and `bottomBar` accept `AnyView`. Dynamic
builders take precedence over static bars. Set `showsDefaultTopBar` or
`showsDefaultBottomBar` to `false` to remove package defaults without creating an
empty view. When the default bottom bar is enabled,
`showsDefaultPaginationStrip` and `showsDefaultActionBar` independently control
its pagination strip and action controls. Video transport controls are separate
and remain controlled by `showsVideoControls`.

For example, keep video controls and pagination while removing the top bar and
default save/share controls:

```swift
let configuration = SSPhotoViewerConfiguration(
    showsDefaultTopBar: false,
    showsDefaultPaginationStrip: true,
    showsDefaultActionBar: false,
    showsVideoControls: true
)
```

## Actions

Default package actions and custom chrome can share one application handler:

```swift
let configuration = SSPhotoViewerConfiguration { action in
    switch action {
    case .save(let item):
        save(item)
    case .share(let item):
        share(item)
    case .custom("delete", let item):
        delete(item)
    case .custom(let id, let item):
        handleCustomAction(id, item)
    }
}
```

Because `SSPhotoViewerAction` carries the item, handlers do not need to race a
separate selected-index lookup.

## Custom video controls

Videos start muted. The active page owns one player and pauses it as soon as
selection moves to another page. Custom controls receive live state and commands:

```swift
let configuration = SSPhotoViewerConfiguration()
    .customVideoControls { context in
        HStack(spacing: 10) {
            Button(action: context.togglePlayback) {
                Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
            }

            Slider(
                value: Binding(
                    get: { context.currentTime },
                    set: { context.seek(to: $0) }
                ),
                in: 0...max(context.duration, 1)
            )

            Button(action: context.toggleMute) {
                Image(
                    systemName: context.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill"
                )
            }
        }
    }
```

The context belongs to `context.item`; it is removed when an image becomes
selected or another player takes ownership. Available state includes
`playbackState`, `isPlaying`, `isMuted`, `currentTime`, `duration`, and the
underlying `AVPlayer.TimeControlStatus` for advanced UI.

The package-owned transport displays elapsed time before the seek slider and
total duration after it. Until duration metadata is available, the total label
is `--:--`. Custom video-control builders own their layout and can format the
same values from the context.

Set `showsVideoControls` to `false` when the app intentionally provides no
transport UI.

## Minimal and detail modes

The default initial mode is `.minimal`: auxiliary views are hidden and media is
the focus. A single tap toggles detail mode; a double tap remains reserved for
zoom. Custom chrome can set the mode through its context.

```swift
context.setDisplayMode(.minimal)
context.toggleDisplayMode()
```

Use `initialDisplayMode: .detail` only for products where metadata and actions
must be immediately visible.

The package injects `@Environment(\.ssPhotoViewerIsZoomed)` into custom bottom
chrome. This is useful when the action bar should remain but a custom strip must
hide while zoomed.

## Standalone thumbnail strip

Use `SSPhotoViewerStrip` when a gallery or message layout needs the thumbnail
strip without fullscreen viewer ownership. It changes only the supplied
selection binding and horizontal scroll position; it does not ignore or add
safe-area insets.

```swift
SSPhotoViewerStrip(
    items: items,
    selectedIndex: $selectedIndex,
    imageLoader: { url in
        await appImagePipeline.image(for: url)
    },
    onRequestNextPage: loadNextPage
)
```

The callback is invoked when the selected or visible strip item reaches the
current end. The caller remains responsible for appending items and for
coordinating any loading state.

## Dismissal destinations

```swift
SSPhotoViewerConfiguration(
    fallbackDestination: .source
)
```

- `.source` returns to the live source when available and otherwise exits just
  beyond the final visible source.
- `.offscreenAfterLastVisible` explicitly selects offscreen fallback behavior.
- `.fixed(CGRect)` returns to a stable rectangle in global screen coordinates.

A source in a lazy container can only be used while mounted. If home scrolls or
reflows during fullscreen viewing, the package consumes the latest reported
frame rather than the frame captured at presentation.

## Interaction behavior

- Single tap: toggle minimal/detail mode.
- Double tap: zoom to cover around the tapped point; double tap again resets.
- Pinch: zoom from the current scale, not from a stale gesture baseline.
- Pan while zoomed: move inside media bounds.
- Horizontal pan at a zoom edge: resist, then hand off to paging.
- Horizontal page swipe: snap to adjacent media and reset the previous page zoom.
- Vertical drag: move and scale the current media while backdrop opacity falls.
- Zoomed vertical dismissal: first reach the zoom edge, release, then use the
  next gesture for dismissal.
- Downward drag past threshold: dismiss through the source handoff.
- Upward or below-threshold drag: snap back.

## Performance with large sequences

The viewer does not render every loaded item. The fullscreen pager keeps only
the selected page and immediate neighbors in the active page window. The strip
uses a lazy stack, and pagination is
append-only with an incremental ID-to-index map.

The package does not download, decode, or cache images. Supply `imageLoader` in
the viewer policy/configuration and let the app's media pipeline own networking,
authorization, decoding, caching, retries, and freshness.

For 1,000+ media items:

- Use stable IDs.
- Keep `thumbnailURL` genuinely small.
- Return pages rather than replacing the entire viewer array repeatedly.
- Keep home in `List`, `LazyVStack`, or `LazyVGrid`.
- Avoid expensive work in custom chrome `body` implementations.
- Profile your real CDN images and video bitrates; sequence size alone is not
  usually the dominant memory cost.

## Accessibility

- Supply a meaningful `accessibilityLabel` for each item.
- Mark tappable home media as buttons when using `onTapGesture`.
- Give custom chrome controls explicit labels.
- Do not encode selection using color alone in a custom strip.
- Keep custom control hit targets near 44×44 points or larger.
- Test VoiceOver order and accessibility Dynamic Type sizes in every custom bar.

## Media loading

The viewer is intentionally not a network client. Configure an app-owned
loader, for example one backed by Nuke, Kingfisher, Photos, local files, or an
authenticated URLSession:

```swift
let policy = ImageViewerPresentationPolicy<AppImage>(
    imageLoader: { url in
        await appImagePipeline.image(for: url)
    }
)
```

The loader returns the decoded `UIImage` the viewer should display. The app
controls full-resolution policy and can return a thumbnail first, then update
its own pipeline as needed. If no loader is supplied, URL-backed image and
poster surfaces remain placeholders; no implicit network request occurs.

For advanced video pipelines, provide an already-configured `AVAsset` instead
of a URL:

```swift
let asset = AVURLAsset(url: signedVideoURL)
let item = SSPhotoViewerItem(
    id: video.id,
    media: .videoAsset(asset, posterURL: posterURL)
)
```

The viewer creates and owns the `AVPlayer` lifecycle and controls. The app owns
how the asset is constructed, including authentication or custom resource
loading.

For advanced video pipelines, provide an already-configured `AVAsset` instead
of a URL:

```swift
let asset = AVURLAsset(url: signedVideoURL)
let item = SSPhotoViewerItem(
    id: video.id,
    media: .videoAsset(asset, posterURL: posterURL)
)
```

The viewer creates and owns the `AVPlayer` lifecycle and controls. The app owns
how the asset is constructed, including authentication or custom resource
loading.

## Public API map

- `ImageViewerAdapter` — the public viewer facade and app-owned bindings.
- `ImageViewerAsset` — the app asset contract.
- `ImageViewerMedia` — app-facing image/video resource input.
- `ImageViewerPresentationPolicy` — presentation, chrome, pagination, and action policy.
- `ImageViewerPage` — app-owned pagination result.
- `ImageViewerAction` — app-owned semantic actions.

The lower-level `SSPhotoViewer` target, host, item, chrome, and source APIs are
implementation details behind the adapter product and are not SPM products.

The DocC catalog under `Sources/SSPhotoViewer/SSPhotoViewer.docc` contains the
same contracts as focused integration guides suitable for Xcode Quick Help.

## Troubleshooting

### The viewer opens the wrong item

The home index was probably applied to a differently ordered viewer array. Use
the stable-ID host initializer or map `homeItem.id` into `viewerItems`.

### The item dismisses offscreen instead of returning to home

No source with that ID is currently mounted. Confirm IDs match and apply
`.ssPhotoViewerSource(id:)` to the image view. In a lazy container, scroll the
source back into the mounted region or select an explicit fallback destination.

### A cold open waits before moving

Provide a small `thumbnailURL` and, when known, `aspectRatio`. The source remains
visible while preview and final geometry become ready; the preparation overlay
communicates that work without exposing a blank handoff layer.

See [Source readiness and the preparation loader](#source-readiness-and-the-preparation-loader)
for the complete lifecycle and adapter/direct-package examples.

### The opening crop changes

The thumbnail is probably a server-side crop. That is supported, but do not set
`thumbnailPreservesMediaAspectRatio` to `true`. For the most continuous visual,
serve a thumbnail with the full media's orientation and aspect ratio.

### Custom strip pagination stops at the boundary

Use `context.items` as the strip data source and call
`context.requestNextPage()` as the strip approaches its end. Do not retain an
old context snapshot.

### Video controls appear on an image

Build controls only from `videoControlsBuilder`; the package mounts that builder
for the active video player and removes the player synchronously when selection
changes.
