// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SSPhotoViewer",
    platforms: [
        .iOS(.v17)
    ],
    products: [
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
