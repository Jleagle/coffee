// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coffee",
    platforms: [.macOS(.v13)],
    products: [
        // Installed by the Homebrew formula as libexec/coffee; the Go CLI owns
        // the `coffee` name in bin.
        .executable(name: "coffee-menubar", targets: ["CoffeeMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "CoffeeMenuBar", path: "Sources/CoffeeMenuBar"),
    ]
)
