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
    ],
    targets: [
        .target(
            name: "SSPhotoViewer"
        ),
        .testTarget(
            name: "SSPhotoViewerTests",
            dependencies: ["SSPhotoViewer"]
        )
    ]
)
