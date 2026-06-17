//
//  DevAgentDetection.swift
//  Zerro
//
//  Async front for `DevAgentRegistry` detection. The registry's `all()` runs a
//  BLOCKING shell probe (interactive login shell → slow), so it must never run
//  on the hotkey→overlay path. This actor-isolated cache warms detection ONCE
//  on a background task and hands the result back on the main actor — callers
//  read the cached entries instead of resolving inline.
//
//  Usage contract:
//    • Only ever warmed when Dev Mode is (or becomes) active — a normal-mode
//      user (devModeEnabled == false who never toggles it on) never triggers
//      the shell probe, so the overlay path stays allocation-cheap for them.
//    • `warm(completion:)` is idempotent: the first call kicks the probe, later
//      calls (and calls after it finishes) get the cached result; a completion
//      passed before the probe finishes is invoked when it does, on the main
//      actor.
//

import Foundation

@MainActor
@Observable
final class DevAgentDetection {

    /// Shared so an app-launch warm and the overlay controller see the same
    /// cached result.
    static let shared = DevAgentDetection()

    enum Status: Equatable {
        case notStarted
        case detecting
        case done
    }

    private(set) var status: Status = .notStarted

    /// Detected agents (with `installed`/`absolutePath` populated). Empty until
    /// the first warm completes.
    private(set) var entries: [DevAgentEntry] = []

    /// Completions waiting on an in-flight probe.
    private var pending: [([DevAgentEntry]) -> Void] = []

    /// Cached lookup by id. nil until detection finishes.
    func entry(id: String) -> DevAgentEntry? {
        entries.first { $0.id == id }
    }

    /// Kick off detection if it hasn't run, then deliver the resolved entries
    /// to `completion` on the main actor — immediately if already done, or when
    /// the in-flight probe finishes. Safe to call repeatedly.
    func warm(completion: (([DevAgentEntry]) -> Void)? = nil) {
        switch status {
        case .done:
            completion?(entries)

        case .detecting:
            if let completion { pending.append(completion) }

        case .notStarted:
            status = .detecting
            if let completion { pending.append(completion) }
            // Run the blocking probe off the main actor. `DevAgentRegistry.all`
            // is `nonisolated`; entries are `Sendable`.
            Task.detached(priority: .utility) { [weak self] in
                let resolved = DevAgentRegistry.all()
                await MainActor.run {
                    self?.finish(with: resolved)
                }
            }
        }
    }

    private func finish(with resolved: [DevAgentEntry]) {
        entries = resolved
        status = .done
        let callbacks = pending
        pending.removeAll()
        for cb in callbacks { cb(resolved) }
    }
}
