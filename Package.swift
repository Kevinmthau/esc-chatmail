// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "esc-chatmail",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "esc-chatmail",
            targets: ["esc-chatmail"])
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "esc-chatmail",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS")
            ],
            path: "esc-chatmail"
        )
    ]
)