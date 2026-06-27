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

enum Build {
    /// True only in the Staging build configuration.
    static var isStaging: Bool {
        #if STAGING
        true
        #else
        false
        #endif
    }
}
