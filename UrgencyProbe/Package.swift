// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UrgencyProbe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "UrgencyProbe",
            path: "Sources/UrgencyProbe",
            swiftSettings: [
                // The FoundationModels macro plugin ships in the platform
                // toolchain, not the default host plugin path SPM searches.
                .unsafeFlags([
                    "-plugin-path",
                    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
                ])
            ]
        ),
        .executableTarget(
            name: "Calibrate",
            path: "Sources/Calibrate",
            swiftSettings: [
                // EventSemantics.swift and UrgencyCombiner.swift are symlinks into
                // the app, so this measures exactly what ships. The app builds in
                // Swift 5 mode; match it.
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-plugin-path",
                    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
                ])
            ]
        ),
        .executableTarget(
            name: "Spikes",
            path: "Sources/Spikes",
            swiftSettings: [
                // Same setup as Calibrate: shipping files via symlinks, Swift 5 mode.
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-plugin-path",
                    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
                ])
            ]
        ),
        .executableTarget(
            name: "ExportCalendar",
            path: "Sources/ExportCalendar"
        )
    ]
)
