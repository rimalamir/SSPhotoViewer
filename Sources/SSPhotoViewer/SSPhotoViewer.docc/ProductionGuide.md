# Production Guide

Integrate SSPhotoViewer with large datasets, app-owned media pipelines,
accessibility, and GitHub distribution.

## Large collections

The fullscreen page window contains only current and adjacent pages. The bottom
strip uses a lazy horizontal stack. This keeps view count bounded even when the
loaded model contains hundreds or thousands of items.

Remaining costs are primarily:

- decoded image memory;
- network transfer and CDN decode size;
- active video buffering;
- custom chrome body work;
- home layout work for mounted cells.

Use small thumbnails, paged full media, stable IDs, and lazy home layouts. Avoid
rebuilding transformed arrays inside custom chrome on every strip movement.

## Media loading and caching

The package is a viewer, not a networking or image-cache layer. Provide an
app-owned ``SSPhotoViewerImageLoader`` through the configuration. The app owns
authorization, URL signing, decoding resolution, memory/disk caching, retry,
freshness, and invalid-response handling. If no image loader is provided,
URL-backed image and poster surfaces remain placeholders; the package performs
no implicit image request.

## App-owned media pipeline

The model carries stable media identity and URLs as metadata, but acquisition is
app-owned. Produce stable domain items after authorization and URL signing. If
signed URLs rotate, preserve item ID so selection and source identity remain
coherent.

The page loader is async and nonthrowing. Translate transport failures into app
retry policy. A loader can retain `hasMore: true` after a temporary failure so a
custom retry control can invoke `requestNextPage()`.

Eager grid loading and viewer boundary loading can coexist. Append eager media
to the viewer sequence and advance ``SSPhotoViewerPaginationCursor`` so the
package cancels stale pulls and requests the correct next page. The repository
should coalesce identical page requests because both triggers can fire before a
SwiftUI state update reaches the viewer.

## Video

Provide posters for immediate static visuals. The viewer pauses a player when
its page is no longer selected and starts videos muted. Custom controls should
derive icons from the live context rather than storing duplicate play/mute state.

## Accessibility checklist

- Every item has a useful `accessibilityLabel`.
- Every source tap target has button traits or a real `Button`.
- Every custom icon control has a label.
- Custom strips expose selected state without color alone.
- Chrome supports Dynamic Type without obscuring the media control path.
- Reduced Motion is considered in the consuming product's broader navigation.

## Source and identity checklist

- Home source ID exactly equals item ID.
- IDs are stable across pages and URL refreshes.
- The source modifier is on the visual frame.
- Independent arrays select by ID.
- Home updates before a page is returned when return-source availability matters.
- Fallback behavior is explicitly chosen for viewer-only media.

## GitHub package layout

The repository root must keep:

```text
Package.swift
Sources/SSPhotoViewer/
Tests/SSPhotoViewerTests/
```

Consumer applications should live in their own repositories and add this
repository through Swift Package Manager. Keeping this repository package-only
prevents app-specific project settings and user data from entering a release.

Before tagging a release:

1. Build at least one maintained consumer integration app against the release candidate.
2. Run focused package tests on an iOS Simulator.
3. Build DocC and resolve broken links or warnings.
4. Confirm no sample Derived Data or `xcuserdata` is tracked.
5. Review public symbol compatibility.
6. Tag using semantic versioning.

## Semantic versioning guidance

- Patch: bug fixes with no source-breaking API changes.
- Minor: additive public APIs, new customization points, new interactions.
- Major: renamed/removed symbols or changed behavioral contracts requiring
  consumer code changes.

Prefer additive context properties and configuration defaults. Keep existing
initializers source compatible whenever possible.
