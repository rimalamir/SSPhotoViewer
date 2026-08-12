# Changelog

## Unreleased

### Changed

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
- Added iOS Simulator package CI for the library and test target.
- Added a debug diagnostic for a selected ID that is not present in the viewer
  sequence instead of leaving that integration mistake silent.

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
