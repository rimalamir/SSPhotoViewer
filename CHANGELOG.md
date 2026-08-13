# Changelog

## Unreleased

### Changed

- Split the implementation into focused public-host, pager/gesture,
  media-rendering, and reconciliation components without changing the viewer's
  presentation or interaction contract.
- Added regression coverage for in-place item replacement, duplicate-ID append
  handling, and deterministic ID-index mapping.
- Reconciled in-place viewer item replacements while a presentation is active,
  including resetting stale zoom/player state and restarting media tasks when a
  host replaces content at an existing index.
- Added an optional app-owned synchronous memory lookup so cached source media
  can seed the opening handoff without a placeholder frame. The package still
  owns no image cache or memory policy.
- Prevented the opening hero from resizing after the thumbnail handoff. The
  opening now uses an explicitly ratio-preserving thumbnail or waits for the
  authoritative full-image geometry before animating.
- Documented that an app-owned image loader is required for URL-backed image
  and poster content; the package intentionally provides no universal default.
- Lowered the package tools requirement to Swift 5.10 so it can be adopted by
  projects that have not yet moved to Swift tools 6.
- Kept SSPhotoViewer focused on viewing and interaction: image networking,
  decoding policy, memory caching, disk caching, authorization, retries, and
  freshness now belong to the consuming app.
- Added the app-owned `SSPhotoViewerImageLoader` / `ImageViewerImageLoader`
  boundary. The viewer requests a decoded `UIImage`; it never performs an
  implicit image request.
- Removed the package-owned image cache and URL image loader.
- Added `videoAsset(AVAsset, posterURL:)` for app-configured video resources,
  while retaining the simple remote-URL video convenience.
- Fixed offscreen fallback selection to use the last mounted source in sequence
  order.
- Made duplicate-ID dictionary construction deterministic instead of trapping.
- Made dismissal prefer the currently mounted source geometry, using the
  presentation snapshot only when the live source is unavailable.
- Added regression coverage for app-owned image loading and asset-backed video.
- Added a debug diagnostic for a selected ID that is not present in the viewer
  sequence instead of leaving that integration mistake silent.
- Let the standalone thumbnail strip use the same app-owned image loader as
  the fullscreen viewer.

### Migration

Configure an app-owned loader in the viewer policy:

```swift
let policy = ImageViewerPresentationPolicy<AppImage>(
    imageLoader: { url in
        await appImagePipeline.image(for: url)
    }
)
```

The app pipeline should return the decoded image for thumbnails, posters, and
full-resolution stills. It may use any authenticated loader or cache strategy.
