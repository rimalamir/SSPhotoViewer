import AVFoundation
import SwiftUI
import XCTest
@testable import SSPhotoViewer
@testable import SSPhotoViewerAdapter

final class SSPhotoViewerTests: XCTestCase {
    private let imageURL = URL(string: "https://example.com/full.jpg")!
    private let videoURL = URL(string: "https://example.com/video.mp4")!
    private let thumbnailURL = URL(string: "https://example.com/thumb.jpg")!
    private let posterURL = URL(string: "https://example.com/poster.jpg")!

    private struct AdapterAsset: ImageViewerAsset {
        let imageViewerID: String
        let imageViewerMedia: ImageViewerMedia
        var imageViewerThumbnailURL: URL? = nil
        var imageViewerAccessibilityLabel: String? = nil
    }

    private final class AdapterBindingState: @unchecked Sendable {
        var isPresented = false
        var selectedID = ""
    }

    func testImageItemExposesStablePublicMediaMetadata() {
        let item = SSPhotoViewerItem(
            id: "photo",
            media: .image(imageURL),
            aspectRatio: 4.0 / 3.0,
            accessibilityLabel: "A photo"
        )

        XCTAssertEqual(item.id, "photo")
        XCTAssertEqual(item.mediaURL, imageURL)
        XCTAssertEqual(item.mediaKind, .image)
        XCTAssertFalse(item.isVideo)
        XCTAssertEqual(item.preferredThumbnailURL, imageURL)
        XCTAssertEqual(item.aspectRatio, 4.0 / 3.0)
    }

    func testExplicitThumbnailTakesPriorityOverImageFallback() {
        let item = SSPhotoViewerItem(
            id: "photo",
            media: .image(imageURL),
            thumbnailURL: thumbnailURL
        )

        XCTAssertEqual(item.preferredThumbnailURL, thumbnailURL)
    }

    func testVideoUsesThumbnailThenPosterForStaticVisual() {
        let thumbnailItem = SSPhotoViewerItem(
            id: "thumbnail-video",
            media: .video(videoURL, posterURL: posterURL),
            thumbnailURL: thumbnailURL
        )
        let posterItem = SSPhotoViewerItem(
            id: "poster-video",
            media: .video(videoURL, posterURL: posterURL)
        )

        XCTAssertTrue(thumbnailItem.isVideo)
        XCTAssertEqual(thumbnailItem.mediaKind, .video)
        XCTAssertEqual(thumbnailItem.preferredThumbnailURL, thumbnailURL)
        XCTAssertEqual(posterItem.preferredThumbnailURL, posterURL)
    }

    func testAssetBackedVideoKeepsCustomAssetAndUsesSameMediaKind() {
        let asset = AVURLAsset(url: videoURL)
        let item = SSPhotoViewerItem(
            id: "asset-video",
            media: .videoAsset(asset, posterURL: posterURL)
        )

        XCTAssertTrue(item.isVideo)
        XCTAssertEqual(item.mediaKind, .video)
        XCTAssertEqual(item.mediaURL, videoURL)
        XCTAssertEqual(item.preferredThumbnailURL, posterURL)
    }

    func testPosterlessVideoDoesNotPretendVideoURLIsAnImage() {
        let item = SSPhotoViewerItem(
            id: "video",
            media: .video(videoURL)
        )

        XCTAssertNil(item.preferredThumbnailURL)
        XCTAssertEqual(item.mediaURL, videoURL)
    }

    func testPagePreservesAppendOnlyResult() {
        let item = SSPhotoViewerItem(id: "photo", media: .image(imageURL))
        let page = SSPhotoViewerPage(items: [item], hasMore: true)

        XCTAssertEqual(page.items, [item])
        XCTAssertTrue(page.hasMore)
    }

    func testItemReconciliationReplacesExistingPositionAndReportsIt() {
        let previous = SSPhotoViewerItem(
            id: "photo",
            media: .image(imageURL),
            aspectRatio: 4.0 / 3.0
        )
        let replacement = SSPhotoViewerItem(
            id: "photo",
            media: .image(URL(string: "https://example.com/full-2.jpg")!),
            aspectRatio: 16.0 / 9.0
        )

        let result = SSPhotoViewerItemReconciliation.apply(
            incoming: [replacement],
            to: [previous]
        )

        XCTAssertEqual(result.items, [replacement])
        XCTAssertEqual(result.replacements.count, 1)
        XCTAssertEqual(result.replacements[0].index, 0)
        XCTAssertEqual(result.replacements[0].previous, previous)
        XCTAssertEqual(result.replacements[0].incoming, replacement)
    }

    func testItemReconciliationAppendsOnlyNewIDs() {
        let first = SSPhotoViewerItem(id: "first", media: .image(imageURL))
        let second = SSPhotoViewerItem(id: "second", media: .image(thumbnailURL))

        let result = SSPhotoViewerItemReconciliation.apply(
            incoming: [first, second, second],
            to: [first]
        )

        XCTAssertEqual(result.items, [first, second])
        XCTAssertTrue(result.replacements.isEmpty)
    }

    func testItemReconciliationBuildsDeterministicIDMap() {
        let first = SSPhotoViewerItem(id: "first", media: .image(imageURL))
        let duplicateID = SSPhotoViewerItem(
            id: "first",
            media: .image(thumbnailURL)
        )
        let second = SSPhotoViewerItem(id: "second", media: .image(videoURL))

        XCTAssertEqual(
            SSPhotoViewerItemReconciliation.indexMap(
                for: [first, duplicateID, second]
            ),
            ["first": 0, "second": 2]
        )
    }

    func testSourceReadinessContractHasConservativeDefaultStates() {
        XCTAssertNotEqual(
            SSPhotoViewerSourceReadiness.unknown,
            SSPhotoViewerSourceReadiness.ready
        )
        XCTAssertNotEqual(
            SSPhotoViewerSourceReadiness.loading,
            SSPhotoViewerSourceReadiness.ready
        )
        XCTAssertEqual(
            Set([
                SSPhotoViewerSourceReadiness.unknown,
                .loading,
                .ready
            ]),
            Set([
                .unknown,
                .loading,
                .ready
            ])
        )
    }

    func testPaginationCursorRepresentsCallerOwnedEagerProgress() {
        let cursor = SSPhotoViewerPaginationCursor(
            nextPageNumber: 4,
            hasMore: false
        )

        XCTAssertEqual(cursor.nextPageNumber, 4)
        XCTAssertFalse(cursor.hasMore)
    }

    func testPaginationCursorNeverRequestsPageZero() {
        let cursor = SSPhotoViewerPaginationCursor(
            nextPageNumber: 0,
            hasMore: true
        )

        XCTAssertEqual(cursor.nextPageNumber, 1)
    }

    func testConfigurationDefaultsAreSafeForAViewerWithNoCustomization() {
        let configuration = SSPhotoViewerConfiguration()

        XCTAssertNil(configuration.pageLoader)
        XCTAssertEqual(configuration.fallbackDestination, .source)
        XCTAssertEqual(configuration.initialDisplayMode, .minimal)
        XCTAssertTrue(configuration.showsDefaultTopBar)
        XCTAssertTrue(configuration.showsDefaultBottomBar)
        XCTAssertTrue(configuration.showsDefaultPaginationStrip)
        XCTAssertTrue(configuration.showsDefaultActionBar)
        XCTAssertTrue(configuration.showsVideoControls)
        XCTAssertNil(configuration.topBar)
        XCTAssertNil(configuration.bottomBar)
        XCTAssertNil(configuration.topBarBuilder)
        XCTAssertNil(configuration.bottomBarBuilder)
        XCTAssertNil(configuration.videoControlsBuilder)
        XCTAssertNil(configuration.imageLoader)
    }

    func testTypedBuilderModifiersInstallEveryCustomChromeBuilder() {
        let configuration = SSPhotoViewerConfiguration()
            .customTopBar { _ in EmptyView() }
            .customBottomBar { _ in EmptyView() }
            .customVideoControls { _ in EmptyView() }

        XCTAssertNotNil(configuration.topBarBuilder)
        XCTAssertNotNil(configuration.bottomBarBuilder)
        XCTAssertNotNil(configuration.videoControlsBuilder)
    }

    func testFallbackDestinationsRetainAssociatedGeometry() {
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)

        XCTAssertEqual(SSPhotoViewerFallbackDestination.source, .source)
        XCTAssertEqual(
            SSPhotoViewerFallbackDestination.fixed(frame),
            .fixed(frame)
        )
    }

    func testPresentationStylesAreDistinctAndStable() {
        XCTAssertNotEqual(
            SSPhotoViewerPresentationStyle.sameHierarchy,
            .fullScreen
        )
        XCTAssertEqual(
            SSPhotoViewerPresentationStyle.fullScreen,
            .fullScreen
        )
    }

    func testAdapterConvertsAppAssetAtTheBoundary() {
        let asset = AdapterAsset(
            imageViewerID: "chat-photo",
            imageViewerMedia: .image(imageURL),
            imageViewerThumbnailURL: thumbnailURL,
            imageViewerAccessibilityLabel: "Chat photo"
        )

        let item = asset.ssPhotoViewerItem

        XCTAssertEqual(item.id, "chat-photo")
        XCTAssertEqual(item.mediaURL, imageURL)
        XCTAssertEqual(item.preferredThumbnailURL, thumbnailURL)
        XCTAssertEqual(item.accessibilityLabel, "Chat photo")
    }

    func testAdapterPolicyBuildsIndependentViewerConfiguration() {
        let policy = ImageViewerPresentationPolicy<AdapterAsset>(
            presentationStyle: .fullScreen,
            showsDefaultTopBar: false,
            showsDefaultPaginationStrip: true,
            showsDefaultActionBar: false,
            showsVideoControls: true
        )

        let configuration = policy.makeConfiguration()

        XCTAssertEqual(policy.presentationStyle, .fullScreen)
        XCTAssertFalse(configuration.showsDefaultTopBar)
        XCTAssertTrue(configuration.showsDefaultPaginationStrip)
        XCTAssertFalse(configuration.showsDefaultActionBar)
        XCTAssertTrue(configuration.showsVideoControls)
    }

    func testAdapterExposesTheAppOwnedImageLoaderBoundary() async {
        let expected = UIImage()
        let policy = ImageViewerPresentationPolicy<AdapterAsset>(
            imageLoader: { _ in expected }
        )
        let configuration = policy.makeConfiguration()
        let resolved = await configuration.imageLoader?(imageURL)

        XCTAssertTrue(resolved === expected)
    }

    @MainActor
    func testStandaloneStripAcceptsTheAppOwnedImageLoaderBoundary() {
        let item = SSPhotoViewerItem(id: "strip-photo", media: .image(imageURL))

        let strip = SSPhotoViewerStrip(
            items: [item],
            selectedIndex: .constant(0),
            imageLoader: { _ in UIImage() }
        )

        XCTAssertEqual(strip.items, [item])
        XCTAssertEqual(strip.selectedIndex, 0)
    }

    func testAdapterOwnsOnlySelectionWrites() {
        let state = AdapterBindingState()
        let asset = AdapterAsset(
            imageViewerID: "gallery-photo",
            imageViewerMedia: .image(imageURL)
        )
        let adapter = ImageViewerAdapter(
            assets: [asset],
            isPresented: Binding(
                get: { state.isPresented },
                set: { state.isPresented = $0 }
            ),
            selectedID: Binding(
                get: { state.selectedID },
                set: { state.selectedID = $0 }
            )
        )

        adapter.present(asset)

        XCTAssertEqual(state.selectedID, "gallery-photo")
        XCTAssertTrue(state.isPresented)
    }
}
