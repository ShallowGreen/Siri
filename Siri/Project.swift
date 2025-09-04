import ProjectDescription

let project = Project(
    name: "Siri",
    packages: [
        .remote(
            url: "https://github.com/socketio/socket.io-client-swift",
            requirement: .upToNextMajor(from: "16.0.0")
        )
    ],
    targets: [
        .target(
            name: "Siri",
            destinations: .iOS,
            product: .app,
            bundleId: "dev.tuist2.Siri",
            infoPlist: .extendingDefault(
                with: [
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                    "NSMicrophoneUsageDescription": "This app requires microphone access to record and transcribe speech.",
                    "NSSpeechRecognitionUsageDescription": "This app requires speech recognition to convert audio to text.",
                    "NSScreenRecordingUsageDescription": "This app requires screen recording access to capture screen content.",
                    "UIBackgroundModes": ["audio", "background-processing"],
                    "UIRequiredDeviceCapabilities": ["microphone"],
                    "AVInitialRouteSharingPolicy": "LongFormAudio",
                    "UISupportsDocumentBrowser": false,
                ]
            ),
            sources: ["Siri/Sources/**"],
            resources: ["Siri/Resources/**"],
            entitlements: .dictionary([
                "com.apple.security.application-groups": ["group.dev.tuist2.Siri"]
            ]),
            dependencies: [
                .target(name: "ScreenBroadcastExtension"),
                .package(product: "SocketIO")
            ]
        ),
        .target(
            name: "ScreenBroadcastExtension",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "dev.tuist2.Siri.ScreenBroadcastExtension",
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "屏幕直播",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "NSExtension": [
                        "NSExtensionPointIdentifier": "com.apple.broadcast-services-upload",
                        "NSExtensionPrincipalClass": "ScreenBroadcastHandler",
                        "RPBroadcastProcessMode": "RPBroadcastProcessModeSampleBuffer"
                    ]
                ]
            ),
            sources: ["ScreenBroadcastExtension/Sources/**"],
            entitlements: .dictionary([
                "com.apple.security.application-groups": ["group.dev.tuist2.Siri"]
            ])
        ),
        .target(
            name: "SiriTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "dev.tuist2.SiriTests",
            infoPlist: .default,
            sources: ["Siri/Tests/**"],
            resources: [],
            dependencies: [.target(name: "Siri")]
        ),
    ]
)
