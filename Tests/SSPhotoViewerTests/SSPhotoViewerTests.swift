import SwiftUI
import XCTest
@testable import SSPhotoViewer

final class SSPhotoViewerTests: XCTestCase {
    private let imageURL = URL(string: "https://example.com/full.jpg")!
    private let videoURL = URL(string: "https://example.com/video.mp4")!
    private let thumbnailURL = URL(string: "https://example.com/thumb.jpg")!
    private let posterURL = URL(string: "https://example.com/poster.jpg")!

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
        XCTAssertTrue(configuration.showsVideoControls)
        XCTAssertNil(configuration.topBar)
        XCTAssertNil(configuration.bottomBar)
        XCTAssertNil(configuration.topBarBuilder)
        XCTAssertNil(configuration.bottomBarBuilder)
        XCTAssertNil(configuration.videoControlsBuilder)
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
}
