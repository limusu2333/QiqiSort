// swift-tools-version: 5.9
import PackageDescription
import Foundation

let brandInfo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("resources/branding/Info.plist").path

let package = Package(
    name: "Gather",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GroupPicker", targets: ["GroupPicker"])],
    dependencies: [.package(path: "vendor/mlx-swift-lm"), .package(path: "vendor/mlx-swift")],
    targets: [.executableTarget(
        name: "GroupPicker",
        dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXOptimizers", package: "mlx-swift"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm")
        ],
        path: "current",
        exclude: ["合影筛选器.app", "用户确认示例.json", "使用说明.md"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", brandInfo])]
    )],
    swiftLanguageVersions: [.v5]
)
