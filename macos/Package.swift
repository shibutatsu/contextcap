// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "ContextCap", platforms: [.macOS(.v14)], targets: [
    .target(name: "CaptureCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "ContextCap", dependencies: ["CaptureCore"]),
    .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"])
])
