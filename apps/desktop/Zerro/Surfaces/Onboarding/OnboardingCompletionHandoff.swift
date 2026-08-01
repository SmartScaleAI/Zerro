//
//  OnboardingCompletionHandoff.swift
//  Zerro
//
//  Keeps the final onboarding action ordered and testable: persist completion,
//  close the setup window, then open the existing capture overlay on the next
//  MainActor turn. The overlay's normal start route owns permission,
//  entitlement, and first-use toolbar-walkthrough behavior.
//

import Foundation

@MainActor
enum OnboardingCompletionHandoff {
    static func perform(
        complete: () -> Void,
        dismiss: () -> Void,
        openOverlay: @escaping @MainActor () -> Void
    ) {
        complete()
        dismiss()

        // Let SwiftUI finish dismissing the titled onboarding window before
        // the non-activating full-screen selector takes key focus.
        Task { @MainActor in
            await Task.yield()
            openOverlay()
        }
    }
}
