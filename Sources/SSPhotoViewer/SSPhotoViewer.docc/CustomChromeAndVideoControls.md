# Custom Chrome and Video Controls

Build product-specific controls from package-owned state without duplicating viewer behavior.

## Typed builders

Use the fluent generic builders to keep `AnyView` out of feature code:

```swift
let configuration = SSPhotoViewerConfiguration(onAction: handleAction)
    .customTopBar { context in
        ViewerHeader(context: context)
    }
    .customBottomBar { context in
        ViewerFooter(context: context)
    }
    .customVideoControls { context in
        VideoTransport(context: context)
    }
```

The stored configuration still exposes type-erased builder properties for apps
that construct configuration dynamically.

## Chrome context

``SSPhotoViewerChromeContext`` combines render state with commands scoped to the
active viewer.

Use state to render:

- current `item` and complete loaded `items`;
- `selectedIndex` and `itemCount`;
- `isZoomed` and `isVideo`;
- `displayMode`;
- `pagination`.

Use commands for behavior:

- ``SSPhotoViewerChromeContext/dismiss()``;
- ``SSPhotoViewerChromeContext/select(index:)``;
- ``SSPhotoViewerChromeContext/select(id:)``;
- ``SSPhotoViewerChromeContext/setDisplayMode(_:)``;
- ``SSPhotoViewerChromeContext/toggleDisplayMode()``;
- ``SSPhotoViewerChromeContext/requestNextPage()``;
- ``SSPhotoViewerChromeContext/perform(_:)``.

These commands preserve package invariants such as page-local zoom reset,
video ownership, source-aware dismissal, and pagination prefetch.

## A custom header

```swift
struct ViewerHeader: View {
    let context: SSPhotoViewerChromeContext

    var body: some View {
        HStack {
            Button(action: context.dismiss) {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Close viewer")

            Spacer()

            VStack {
                Text(context.item.accessibilityLabel ?? "Media")
                Text("\(context.selectedIndex + 1) of \(context.itemCount)")
                    .font(.caption)
            }

            Spacer()

            Menu {
                Button("Share") {
                    context.perform(.share(context.item))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}
```

## Zoom-aware bottom chrome

The context directly reports zoom, and the package also injects an environment
value into custom bottom content. Use the environment when a nested strip should
hide independently from a persistent action bar.

```swift
struct ViewerFooter: View {
    let context: SSPhotoViewerChromeContext
    @Environment(\.ssPhotoViewerIsZoomed) private var isZoomed

    var body: some View {
        VStack {
            if !isZoomed {
                MediaStrip(context: context)
            }
            PersistentActions(context: context)
        }
    }
}
```

## Video control ownership

``SSPhotoViewerVideoControlsContext`` is created for the currently selected
video player only. Selection synchronously pauses and releases the old player,
preventing stale audio or controls from surviving over another page.

```swift
struct VideoTransport: View {
    let context: SSPhotoViewerVideoControlsContext

    var body: some View {
        HStack {
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
                Image(systemName: context.isMuted
                    ? "speaker.slash.fill"
                    : "speaker.wave.2.fill")
            }
        }
    }
}
```

The package starts playback muted. `playbackState` is independent of AVFoundation
and is usually sufficient for icon selection. `timeControlStatus` remains
available for advanced waiting-state treatment.

The package-owned transport control displays elapsed time before the seek slider
and total duration after it. Until AVFoundation reports a duration, the total
label is shown as `--:--`. Custom builders own their complete layout, so they
should render their own time labels from `currentTime` and `duration` when that
presentation is desired.

## Default visibility

Use these configuration flags:

- `showsDefaultTopBar` removes the default top bar when there is no custom one.
- `showsDefaultBottomBar` removes the default strip/actions.
- `showsVideoControls` removes package and custom transport UI.
- `initialDisplayMode` chooses the first minimal/detail state.

Custom builders take precedence over static bars, and static bars take
precedence over package defaults.

## Accessibility

Custom UI owns custom semantics. Label icon-only controls, maintain at least
comfortable touch targets, expose selected state in custom strips, and test
VoiceOver order. Use the item's label as description, not a generated position;
position can be announced separately from `selectedIndex` and `itemCount`.
