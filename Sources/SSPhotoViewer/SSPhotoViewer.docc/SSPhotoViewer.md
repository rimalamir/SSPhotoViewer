# ``SSPhotoViewer``

Build Photos-style fullscreen image and video experiences around any SwiftUI home screen.

## Overview

SSPhotoViewer owns fullscreen media interaction while leaving product structure
and data ownership in the application. Wrap a grid, list, feed, conversation, or
custom layout in ``SSPhotoViewerHost`` and mark each visible media surface with
``SwiftUICore/View/ssPhotoViewerSource(id:isHidden:)``.

The package keeps the home and viewer in one SwiftUI hierarchy. That enables a
three-owner presentation handoff:

```text
home source → preview transition hero → fullscreen page
```

and the exact reverse during dismissal:

```text
fullscreen page → static return hero → home source
```

The home remains responsible for navigation, filtering, pagination display,
authorization, persistence, and product-specific actions.

### Core capabilities

- Image and video media backed by URLs.
- Optional thumbnails, video posters, and aspect-ratio hints.
- Runtime aspect-ratio resolution when metadata is unknown.
- Horizontal paging, pinch/double-tap zoom, bounded panning, and drag dismissal.
- Live source destinations that follow home layout changes.
- Viewer pagination independent from home ordering and filtering.
- Default or custom top, bottom, and video-control chrome.
- Minimal/detail modes and zoom-aware custom UI.
- Lazy page and strip rendering for large media sequences.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:HandoffSources>
- ``SSPhotoViewerHost``
- ``SSPhotoViewerItem``
- ``SwiftUICore/View/ssPhotoViewerSource(id:isHidden:)``

### Media and data

- <doc:MediaAndPagination>
- ``SSPhotoViewerItem/Media``
- ``SSPhotoViewerPage``
- ``SSPhotoViewerPageLoader``
- ``SSPhotoViewerPaginationState``
- ``SSPhotoViewerMediaKind``

### Custom interface

- <doc:CustomChromeAndVideoControls>
- ``SSPhotoViewerConfiguration``
- ``SSPhotoViewerChromeContext``
- ``SSPhotoViewerVideoControlsContext``
- ``SSPhotoViewerDisplayMode``
- ``SSPhotoViewerAction``
- ``SSPhotoViewerPlaybackState``

### Production integration

- <doc:ProductionGuide>
- ``SSPhotoViewerFallbackDestination``
- ``SSPhotoViewerCache``
- ``SwiftUICore/EnvironmentValues/ssPhotoViewerIsZoomed``
