// swift-tools-version:5.5

import PackageDescription

let package = Package(
	name: "Neon",
	platforms: [.macOS(.v10_13), .iOS(.v11), .tvOS(.v11), .watchOS(.v4)],
	products: [
		.library(name: "Neon", targets: ["Neon"]),
	],
	dependencies: [
        .package(url: "https://github.com/danielpunkass/SwiftTreeSitter", revision: "7260abc17ca52cc432f3731974cdcf4b1fdb2223"),
		.package(url: "https://github.com/ChimeHQ/Rearrange", from: "1.5.3"),
	],
	targets: [
		.target(name: "Neon", dependencies: ["SwiftTreeSitter", "Rearrange", "TreeSitterClient"]),
		.target(name: "TreeSitterClient", dependencies: ["Rearrange", "SwiftTreeSitter"]),
		.testTarget(name: "NeonTests", dependencies: ["Neon"]),
		.testTarget(name: "TreeSitterClientTests", dependencies: ["TreeSitterClient"])
	]
)
