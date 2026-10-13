// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coffee",
    platforms: [.macOS(.v13)],
    products: [
        // Wrapped into Coffee.app by bundle.sh (installed to /Applications by
        // the Homebrew cask).
        .executable(name: "coffee-menubar", targets: ["CoffeeMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "CoffeeMenuBar", path: "Sources/CoffeeMenuBar"),
        .testTarget(name: "CoffeeMenuBarTests", dependencies: ["CoffeeMenuBar"], path: "Tests/CoffeeMenuBarTests"),
    ]
)
