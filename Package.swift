// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shunshou",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Shunshou",
            path: "Sources/Shunshou"
        )
    ]
)
