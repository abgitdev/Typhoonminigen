// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Typhoonminigen",
    platforms: [
        .macOS(.v14) // matches flux-2-swift-mlx engine floor
    ],
    dependencies: [
        // FLUX.2 Klein engine (Flux2Core + FluxTextEncoders). Pinned for reproducibility.
        .package(
            url: "https://github.com/VincentGourbin/flux-2-swift-mlx.git",
            exact: "2.4.0"
        ),
        // Pin mlx-swift to 0.30.6: the engine declares `from: 0.30.2` (open upper bound),
        // but 0.31.4 changed MLXOptimizers' AdamW state type (TupleState → AdamState),
        // which breaks the engine's training code (ResumableAdamW). 0.30.6 is the latest
        // version compatible with flux-2-swift-mlx v2.4.0. We also `import MLX` directly.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.30.6"
        )
    ],
    targets: [
        .executableTarget(
            name: "Typhoonminigen",
            dependencies: [
                .product(name: "Flux2Core", package: "flux-2-swift-mlx"),
                .product(name: "FluxTextEncoders", package: "flux-2-swift-mlx"),
                .product(name: "MLX", package: "mlx-swift")
            ],
            path: "Sources/Typhoonminigen",
            resources: [
                // Bundled Library scene preview thumbnails (one downscaled hero per recipe id).
                .copy("Resources/ScenePreviews")
            ]
        )
    ]
)
