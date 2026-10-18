// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SumireCore", platforms: [.iOS("18.0"), .macOS(.v13)], products: [.library(name: "SumireCore", targets: ["SumireCore"])], targets: [
    .target(name: "SumireCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "SumireCoreTests", dependencies: ["SumireCore"])
])
