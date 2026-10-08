// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coffee",
    platforms: [.macOS(.v13)],
    products: [
        // Wrapped into Coffee.app by bundle.sh (installed into the Homebrew
        // Cellar by the formula, see homebrew/formula.sh).
        .executable(name: "coffee-menubar", targets: ["CoffeeMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "CoffeeMenuBar", path: "Sources/CoffeeMenuBar"),
        .testTarget(name: "CoffeeMenuBarTests", dependencies: ["CoffeeMenuBar"], path: "Tests/CoffeeMenuBarTests"),
    ]
)
