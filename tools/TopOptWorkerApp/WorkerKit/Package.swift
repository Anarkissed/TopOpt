// swift-tools-version:5.9
// WorkerKit — the Foundation-only action layer shared by the TopOpt Worker app's two
// faces (the MenuBarExtra and the main Window). It lives in its own SwiftPM package so
// `swift test` can prove, without Xcode or a GUI, that both faces drive the worker
// through identical HTTP requests (handoff 124). The macOS app compiles the same
// sources directly into its target; this package is the test harness for them.
import PackageDescription

let package = Package(
    name: "WorkerKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WorkerKit", targets: ["WorkerKit"]),
    ],
    targets: [
        .target(name: "WorkerKit"),
        .testTarget(name: "WorkerKitTests", dependencies: ["WorkerKit"]),
    ]
)
