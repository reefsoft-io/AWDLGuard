// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AWDLGuardKit",
    platforms: [.macOS(.v26)],
    products: [
        // Linked by both the app and the privileged helper; keep it to what both share: the
        // identity, the message types, logging and the helper's session table.
        .library(name: "HelperInterface", targets: ["HelperInterface"]),
        // Linked by the app only: rules, the suppression decision and the status shown to the user.
        .library(name: "GuardPolicy", targets: ["GuardPolicy"]),
    ],
    targets: [
        .target(name: "HelperInterface"),
        .target(name: "GuardPolicy", dependencies: ["HelperInterface"]),
        .testTarget(name: "GuardPolicyTests", dependencies: ["GuardPolicy"]),
        .testTarget(name: "HelperInterfaceTests", dependencies: ["HelperInterface"]),
    ]
)
