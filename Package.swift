// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSPhotoViewer",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SSPhotoViewer",
            targets: ["SSPhotoViewer"]
        ),
        .library(
            name: "SSPhotoViewerAdapter",
            targets: ["SSPhotoViewerAdapter"]
        ),
    ],
    targets: [
        .target(
            name: "SSPhotoViewer"
        ),
        .target(
            name: "SSPhotoViewerAdapter",
            dependencies: ["SSPhotoViewer"]
        ),
        .testTarget(
            name: "SSPhotoViewerTests",
            dependencies: ["SSPhotoViewer", "SSPhotoViewerAdapter"]
        )
    ]
)
