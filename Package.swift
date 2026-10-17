// swift-tools-version: 6.0
// Xcode 16 (Swift 6.0). Языковой режим остаётся Swift 5, чтобы перевод не
// превратился в переписывание всего кода под строгий параллелизм.

import PackageDescription

let package = Package(
    name: "DJPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DJPlayer", targets: ["DJPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "DJPlayer",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
