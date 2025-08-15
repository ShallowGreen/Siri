import ProjectDescription

let project = Project(
    name: "Siri",
    targets: [
        .target(
            name: "Siri",
            destinations: .iOS,
            product: .app,
            bundleId: "dev.tuist.Siri",
            infoPlist: .extendingDefault(
                with: [
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                ]
            ),
            sources: ["Siri/Sources/**"],
            resources: ["Siri/Resources/**"],
            dependencies: []
        ),
        .target(
            name: "SiriTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "dev.tuist.SiriTests",
            infoPlist: .default,
            sources: ["Siri/Tests/**"],
            resources: [],
            dependencies: [.target(name: "Siri")]
        ),
    ]
)
