# Handoff Sources

Register accurate live geometry and preserve visual ownership across presentation and dismissal.

## Source registration

Apply ``SwiftUICore/View/ssPhotoViewerSource(id:isHidden:)`` to the exact visual
surface—not its unrelated labels or row container.

```swift
RemoteThumbnail(item: item)
    .frame(width: 96, height: 96)
    .clipped()
    .ssPhotoViewerSource(id: item.id)
```

The modifier reports a global `CGRect` preference while the view is mounted.
Opacity-based hiding preserves layout and preference delivery, allowing the
source to move or reflow while the fullscreen viewer exists.

## Presentation ownership

The package waits for two independent conditions:

1. A preview hero can render a visual.
2. Final media aspect ratio is known so destination geometry is correct.

The source remains visible during that preparation. Once the preview hero is
rendered at the exact source frame, the hero begins moving and the host hides
only the matching source ID. The fullscreen page loads behind the hero and takes
ownership only when it can replace the hero at identical geometry.

This avoids both common cold-cache defects:

- an opaque unloaded hero covering the thumbnail;
- a hero beginning with a guessed square destination and changing ratio later.

## Preparation overlays

The default source modifier displays a rounded indeterminate progress indicator
while preview or geometry work is pending. Supply custom product UI with the
builder overload:

```swift
thumbnail.ssPhotoViewerSource(id: item.id) {
    ProgressView()
        .padding(12)
        .background(.regularMaterial, in: Circle())
}
```

The overlay is scoped to the source ID and cleaned up after successful ownership
transfer, cancellation, timeout, or host disappearance.

## Dismissal ownership

On threshold dismissal, the viewer captures the exact interactive media frame,
including zoom, pan, drag offset, scale, and corner radius. A static return hero
renders at that frame before the fullscreen page relinquishes ownership. The
hero then contracts and moves toward the newest source frame.

At the destination the hero uses fill/crop treatment compatible with common
thumbnail grids. The real source is restored only after the viewer is removed.

## Moving layouts

Source frames are live, not presentation snapshots. If home rotates, scrolls,
or reflows while fullscreen is open, dismissal uses the latest mounted frame.
This produces reference-style behavior without passing a mutable `CGRect`
object into the viewer.

## Lazy containers and fallbacks

Lazy views report geometry only while mounted. A scrolled-off source is not a
valid return target. ``SSPhotoViewerFallbackDestination`` defines what happens:

- ``SSPhotoViewerFallbackDestination/source`` uses the source when available,
  then exits beyond the final visible source.
- ``SSPhotoViewerFallbackDestination/offscreenAfterLastVisible`` explicitly
  selects the offscreen behavior.
- ``SSPhotoViewerFallbackDestination/fixed(_:)`` uses a global fixed rectangle.

For remotely paginated media, append the new page to home before returning the
viewer page when you expect those items to acquire source frames later.

## Visual continuity recommendations

- Use the same thumbnail URL in home and ``SSPhotoViewerItem/thumbnailURL``.
- Prefer a thumbnail with the full media's orientation and aspect ratio.
- Keep `thumbnailPreservesMediaAspectRatio` false for square or editorial crops.
- Supply video posters.
- Keep the source's clipping treatment stable while the viewer is open.
- Never remove the source from the hierarchy merely because presentation starts.
