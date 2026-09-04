// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coffee",
    platforms: [.macOS(.v13)],
    products: [
        // Wrapped into Coffee.app by the release workflow (installed to
        // /Applications by the Homebrew cask); the Go CLI owns the `coffee`
        // name in bin.
        .executable(name: "coffee-menubar", targets: ["CoffeeMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "CoffeeMenuBar", path: "Sources/CoffeeMenuBar"),
    ]
)
