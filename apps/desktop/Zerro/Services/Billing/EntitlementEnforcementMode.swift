//
//  EntitlementEnforcementMode.swift
//  Zerro
//
//  The compile-boundary between SmartScale's OFFICIAL builds and COMMUNITY
//  builds made from a plain source checkout, expressed as an injectable value
//  so entitlement behavior is testable in BOTH modes regardless of how the
//  test binary itself was compiled.
//
//  • `.official`  — the build enforces licensing: the entitlement ladder
//                   (license > active 14-day trial > expired trial), the
//                   paywall gate, activation/deactivation, and background
//                   re-validation all apply.
//  • `.community` — a build anyone compiled from the public source. Always
//                   entitled: generation is never blocked by entitlement
//                   state, and trial/license state is never read, validated,
//                   or contacted. Unrestricted is NOT the same as licensed —
//                   `EntitlementStore.hasActiveLicense` stays false, the
//                   Paywall and Activate Key windows never open, checkout
//                   deep links are ignored, and only Settings shows a "no
//                   license required" notice.
//                   (Provider keys are still required to actually generate —
//                   that is BYOK setup, not entitlement.)
//
//  The production default derives from `Build.isOfficialBuild`, i.e. from the
//  `OFFICIAL_BUILD` compilation condition that only the release workflows
//  set — so every build from a plain checkout is a community build by
//  construction, and forgetting the flag can only fail toward the free mode.
//

enum EntitlementEnforcementMode: Equatable {
    /// SmartScale release-pipeline build: full entitlement enforcement.
    case official
    /// Plain source-checkout build: always entitled, never licensed.
    case community

    /// What a production construction of `EntitlementStore` uses when no mode
    /// is injected: official builds enforce, everything else is community.
    static var productionDefault: EntitlementEnforcementMode {
        Build.isOfficialBuild ? .official : .community
    }
}
