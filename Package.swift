// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WinTaskbar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WinTaskbar", targets: ["WinTaskbar"])
    ],
    targets: [
        .executableTarget(
            name: "WinTaskbar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
