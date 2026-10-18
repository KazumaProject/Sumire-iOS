// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SumireCore", platforms: [.iOS("18.0"), .macOS(.v13)], products: [.library(name: "SumireCore", targets: ["SumireCore"])], targets: [
    .target(name: "MaterialColorUtilities", exclude: ["UPSTREAM.json"]),
    .target(name: "CZipSupport", linkerSettings: [.linkedLibrary("z")]),
    .target(name: "SumireCore", dependencies: ["MaterialColorUtilities", "CZipSupport"], resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "SumireCoreTests", dependencies: ["SumireCore"], resources: [.process("Fixtures")])
])
