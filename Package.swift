// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "GuidelinesCLI",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "guidelines",
            targets: [
                "GuidelinesCLI",
            ]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-tooling/Guidelines.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-tooling/GuidelinesSearch.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Terminal.git",
            branch: "master"
        ),
    ],
    targets: [
        .executableTarget(
            name: "GuidelinesCLI",
            dependencies: [
                .product(
                    name: "Guidelines",
                    package: "Guidelines"
                ),
                .product(
                    name: "GuidelinesSearch",
                    package: "GuidelinesSearch"
                ),
                .product(
                    name: "Terminal",
                    package: "Terminal"
                ),
                .product(
                    name: "TerminalStructuredContent",
                    package: "Terminal"
                ),
            ]
        ),
    ],
    swiftLanguageModes: [
        .v6,
    ]
)
