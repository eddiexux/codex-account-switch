// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAccountSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CodexAccountSwitchCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "CodexAccountSwitch",
            dependencies: ["CodexAccountSwitchCore"],
            path: "Sources/App",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // Command Line Tools 不带 XCTest，契约测试做成可执行目标：`swift run selftest`
        .executableTarget(
            name: "selftest",
            dependencies: ["CodexAccountSwitchCore"],
            path: "Sources/SelfTest"
        ),
    ]
)
