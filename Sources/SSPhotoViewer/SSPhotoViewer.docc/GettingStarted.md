# Getting Started

Add a fullscreen viewer without surrendering ownership of your home screen.

## Create media

Each ``SSPhotoViewerItem`` needs a unique, stable string ID and a full media URL.
Optional metadata lets the package begin transitions earlier and show useful
static visuals before a large resource is ready.

```swift
let media: [SSPhotoViewerItem] = [
    SSPhotoViewerItem(
        id: "lake",
        media: .image(fullImageURL),
        aspectRatio: 4.0 / 3.0,
        thumbnailURL: thumbnailURL,
        thumbnailPreservesMediaAspectRatio: true,
        accessibilityLabel: "Blue lake surrounded by mountains"
    ),
    SSPhotoViewerItem(
        id: "walkthrough",
        media: .video(videoURL, posterURL: posterURL),
        accessibilityLabel: "Walkthrough video"
    )
]
```

Treat identity as domain data. Do not regenerate IDs when sorting, filtering, or
appending pages.

## Add a host

The default host is a same-hierarchy composition root and does not present a
sheet. If the host is already inside a sheet and the viewer must cover that
presentation, use ``SSPhotoViewerPresentationStyle/fullScreen``. That mode uses
the caller's scene-bound native full-screen presentation.

```swift
struct Gallery: View {
    @State private var isPresented = false
    @State private var selectedID = "lake"
    let media: [SSPhotoViewerItem]

    var body: some View {
        SSPhotoViewerHost(
            isPresented: $isPresented,
            selectedID: $selectedID,
            items: media
        ) {
            home
        }
    }

    private var home: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) {
            ForEach(media) { item in
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
                    isPresented = true
                }
            }
        }
    }
}
```

Set presentation state without `withAnimation`. ``SSPhotoViewerHost`` inserts
the viewer with an identity transition and the viewer performs the only visual
animation.

## Choose a selection binding

The stable-ID initializer is safer for independent collections:

```swift
SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedID: $selectedID,
    items: viewerItems
) { home }
```

The index initializer remains useful when the application already owns viewer
selection as an integer:

```swift
SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedIndex: $viewerIndex,
    items: viewerItems
) { home }
```

An index always refers to `viewerItems`. If home has another order, translate
the tapped ID before presenting.

## Add configuration incrementally

Start with defaults. Add only the product behavior you own:

```swift
let configuration = SSPhotoViewerConfiguration(
    fallbackDestination: .source,
    initialDisplayMode: .minimal,
    onAction: handleAction
)
.customTopBar { context in
    ViewerHeader(context: context)
}
.customBottomBar { context in
    ViewerActions(context: context)
}
```

Dynamic builders override static `topBar` and `bottomBar` values. Package
defaults are used when no custom value exists unless their corresponding
`showsDefault...` flag is disabled.

## Understand the interaction defaults

The initial minimal mode displays media without auxiliary chrome. Single tap
enters detail mode, double tap zooms, pinch adjusts the current zoom, horizontal
drag pages, and a thresholded vertical drag dismisses. Zoom state belongs to one
media ID and resets when that page is left.

## Next steps

- Read <doc:HandoffSources> before integrating a lazy or moving home layout.
- Read <doc:MediaAndPagination> before adding network pagination.
- Read <doc:CustomChromeAndVideoControls> for custom strips and controls.
