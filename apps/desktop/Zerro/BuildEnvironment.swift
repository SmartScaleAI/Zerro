//
//  BuildEnvironment.swift
//  Zerro
//
//  Compile-time build-channel facts.
//
//  `Build.isStaging` is true ONLY in the Staging configuration, which defines
//  the `STAGING` active-compilation condition via Config/Staging.xcconfig. It is
//  false in Debug and Release — deliberately decoupled from `#if DEBUG`, since
//  the Staging build is release-type (optimized, assertions off). Use it to gate
//  the amber "this is staging" markers so the shipping Production build is never
//  affected. Where the gate must remove code from the Production binary entirely
//  (e.g. references to Staging-only symbols), use `#if STAGING` directly; use
//  `Build.isStaging` where a plain runtime boolean reads cleaner.
//
//  `Build.isOfficialBuild` is true ONLY when the `OFFICIAL_BUILD` active-
//  compilation condition is set — which NO checked-in configuration does. A
//  plain source checkout (Debug, Release, and Staging alike) always builds a
//  COMMUNITY build: unrestricted, local/BYOK generation, no trial or license
//  enforcement. Only SmartScale's release workflows pass the condition (as a
//  command-line build setting, together with the C macro
//  GCC_PREPROCESSOR_DEFINITIONS=OFFICIAL_BUILD=1 for the exported marker in
//  OfficialBuildMarker.c and ZERRO_BUILD_CHANNEL=official for the Info.plist
//  marker), producing the OFFICIAL builds that are eligible for trial/license
//  enforcement. The safe failure direction is deliberate: forgetting the
//  Swift condition can only ever produce a free community build (or, with the
//  C macro alone, a build that fails to link), never an enforcing one.
//  `STAGING` and `OFFICIAL_BUILD` are orthogonal — the official staging build
//  carries both.
//

enum Build {
    /// True only in the Staging build configuration.
    static var isStaging: Bool {
        #if STAGING
        true
        #else
        false
        #endif
    }

    /// True only when built by SmartScale's release pipeline with the
    /// `OFFICIAL_BUILD` condition. False for every build from a plain source
    /// checkout. Feeds `EntitlementEnforcementMode.productionDefault`. The
    /// official branch genuinely calls the exported C marker
    /// (OfficialBuildMarker.c, imported through the bridging header), which
    /// is declared only under the C `OFFICIAL_BUILD` macro — so a Swift-only
    /// official build does not compile.
    static var isOfficialBuild: Bool {
        #if OFFICIAL_BUILD
        zerroOfficialBuildMarker() == 1
        #else
        false
        #endif
    }
}

#if OFFICIAL_BUILD
/// The Swift half of the official-build marker pairing. The exported marker
/// itself lives in C (OfficialBuildMarker.c) because only a weak C definition
/// survives the exported app's stripping; that C function calls THIS symbol,
/// which exists only under the Swift `OFFICIAL_BUILD` condition. `@_cdecl`
/// gives it the C name `zerroOfficialBuildSwiftMarker`, `nonisolated` keeps
/// it off the main actor so the C entry point is emitted under default actor
/// isolation, and `@inline(never)` keeps it a real function. It is not
/// expected to survive stripping (it is a non-weak Swift symbol); its job is
/// to make a C-macro-only build fail to LINK, so no artifact can carry the
/// marker unless Swift was also compiled official.
@_cdecl("zerroOfficialBuildSwiftMarker")
@inline(never)
nonisolated public func zerroOfficialBuildSwiftMarker() -> Int32 { 1 }
#endif
