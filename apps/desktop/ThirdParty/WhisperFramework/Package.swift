// swift-tools-version: 5.9
//
//  WhisperFramework — a thin local SwiftPM package that vendors the OFFICIAL
//  prebuilt whisper.cpp xcframework as a `binaryTarget`, pinned by URL +
//  checksum to one whisper.cpp release.
//
//  Why a vendored LOCAL package wrapping a remote binary, rather than a normal
//  remote package dependency:
//    • whisper.spm (github.com/ggerganov/whisper.spm) is being archived and is
//      no longer maintained, builds whisper from source, ships WITHOUT Metal
//      (its Metal sources are commented out), and its README requires a
//      `branch: master` rule — i.e. it can't be pinned to a version. It fails
//      both the "links Metal" and "pin the version" requirements.
//    • whisper.cpp itself ships NO Package.swift at its release tags, so the
//      repo can't be consumed directly as a remote SwiftPM package.
//    • The maintainers DO publish a prebuilt `whisper.xcframework` (Metal +
//      Accelerate, universal macOS slice) as a release asset. Pinning a
//      `binaryTarget` to that asset's URL + SHA-256 gives a reproducible,
//      Metal-enabled, code-sign/validatable dependency that Xcode embeds &
//      signs into Zerro.app automatically.
//
//  Pinned release: whisper.cpp v1.9.1
//    asset    : whisper-v1.9.1-xcframework.zip  (~48 MB, macos-arm64_x86_64 slice)
//    checksum : SHA-256 of that zip (the value SwiftPM verifies on download)
//
//  Imported in Swift as `import whisper`. The framework's module map exposes
//  whisper.h + the ggml headers and auto-links Metal, Accelerate, Foundation
//  and libc++, so consumers need no extra link flags.
//
//  To bump the version: change the tag in the URL and replace the checksum with
//  the output of `swift package compute-checksum whisper-vX.Y.Z-xcframework.zip`
//  (equivalently `shasum -a 256` of the downloaded zip).
//
import PackageDescription

let package = Package(
    name: "WhisperFramework",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        )
    ]
)
