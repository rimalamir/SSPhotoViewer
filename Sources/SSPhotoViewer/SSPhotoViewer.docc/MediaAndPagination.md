# Media and Pagination

Model unknown media safely and extend the viewer without coupling it to the home collection.

## Media resources

``SSPhotoViewerItem/Media`` distinguishes images from videos while preserving a
single stable item identity.

```swift
.image(fullImageURL)
.video(videoURL, posterURL: posterURL)
```

Use ``SSPhotoViewerItem/mediaKind``, ``SSPhotoViewerItem/isVideo``, and
``SSPhotoViewerItem/preferredThumbnailURL`` in home UI instead of repeating
case matching in every feature.

## Unknown aspect ratio

`aspectRatio` is optional. Geometry resolves in this priority order:

1. Caller-supplied aspect ratio.
2. Decoded full-image dimensions.
3. Video track dimensions after applying its preferred transform.
4. Thumbnail/poster dimensions only when real geometry cannot be resolved.

The preview may render before final geometry is known, but the opening animation
does not begin until both conditions are ready. It is therefore safe to omit
dimensions from API DTOs, at the cost of waiting for media metadata on the first
cold presentation.

## Viewer and home sequences

Treat these as separate projections:

```text
repository media
├── homeItems   (what this screen renders)
└── viewerItems (what fullscreen paging may visit)
```

They may have different filters and orders. They communicate through stable IDs,
not matching integer indices.

## Loader contract

``SSPhotoViewerPageLoader`` receives monotonic page numbers beginning at `1`.
The initial host sequence is page `0`.

```swift
private func loadPage(_ number: Int) async -> SSPhotoViewerPage {
    let response = await repository.page(number)
    let viewerPage = response.items.map(makeViewerItem)

    await MainActor.run {
        appendUnique(response.items.map(makeHomeItem), to: &homeItems)
        appendUnique(viewerPage, to: &viewerItems)
    }

    return SSPhotoViewerPage(
        items: viewerPage,
        hasMore: response.hasMore
    )
}
```

Update host-owned collections before returning when using the stable-ID binding.
This ensures a selection change caused by the new page can map back to current
host data.

## Automatic requests

The package requests a page when:

- selected media approaches the current end;
- the lazy strip's mounted look-ahead reaches the end;
- custom chrome invokes ``SSPhotoViewerChromeContext/requestNextPage()``.

Only one page task is active at a time. Duplicate IDs are removed before append.
The viewer updates ``SSPhotoViewerPaginationState`` for custom UI.

Selecting the final loaded media directly through the built-in strip also
evaluates this boundary. ``SSPhotoViewerChromeContext/select(index:)`` and
``SSPhotoViewerChromeContext/select(id:)`` use the same selection path, so a
custom strip that selects the last item requests more data as well. A custom
strip whose own scroll position reaches the end before selection changes should
also call ``SSPhotoViewerChromeContext/requestNextPage()``.

## Eager caller push

The application can append media without waiting for the viewer to request it.
Update the `items` value passed to ``SSPhotoViewerHost``. While presented, the
viewer observes that append-only suffix, removes duplicate IDs, and updates its
pager and custom chrome. This is reactive state propagation, not polling.

For a push-only integration, no page loader is required. For a hybrid integration
that supports both eager loading and viewer-driven requests, pass
``SSPhotoViewerPaginationCursor``:

```swift
@State private var viewerItems = initialItems
@State private var cursor = SSPhotoViewerPaginationCursor(
    nextPageNumber: 1,
    hasMore: true
)

SSPhotoViewerHost(
    isPresented: $isPresented,
    selectedID: $selectedID,
    items: viewerItems,
    paginationCursor: cursor,
    configuration: .init(pageLoader: loadPage)
) {
    home
}
```

After the grid or repository accepts an eager page, append its viewer projection
and advance the cursor in the same main-actor update:

```swift
viewerItems.append(contentsOf: freshViewerItems)
cursor = SSPhotoViewerPaginationCursor(
    nextPageNumber: acceptedPageNumber + 1,
    hasMore: response.hasMore
)
```

If the cursor advances beyond a viewer request currently in flight, the package
cancels that stale request and preserves the newer cursor. The repository should
still coalesce or make page requests idempotent because eager and viewer paths
can reach the same boundary concurrently before state propagation completes.

External item updates are append-only for an active presentation. To replace,
remove, or reorder the viewer sequence, dismiss and present a new sequence.

## Custom strip data

Build custom strips from ``SSPhotoViewerChromeContext/items``, not an array
captured during initial presentation. That context sequence includes pages the
viewer has accepted.

```swift
ForEach(context.items) { item in
    Button {
        context.select(id: item.id)
    } label: {
        Thumbnail(item: item)
    }
}
```

The context is a snapshot. SwiftUI rebuilds the custom bar with a new context
when loaded items, selection, zoom, display mode, or pagination status changes.

## Cancellation and errors

The page loader currently expresses completion as ``SSPhotoViewerPage`` rather
than throwing. Handle retry/backoff in the application repository and return an
empty page with `hasMore: true` when the UI should allow a later retry. Return
`hasMore: false` only when the sequence is genuinely exhausted.

Long-running loaders should respect task cancellation through the async APIs they
call. The viewer cancels its active page task when it disappears.
