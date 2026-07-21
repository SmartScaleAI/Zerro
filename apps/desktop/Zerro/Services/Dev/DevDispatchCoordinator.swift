//
//  DevDispatchCoordinator.swift
//  Zerro
//
//  Dev Mode (Phase 1, Milestone 6) — the orchestration between a generated
//  `agent_prompt` and the coding agent editing real files (design §3 steps
//  4→6). Sequences:
//
//    1. checkpoint()  — snapshot the pre-run working tree (git, §4). A non-git
//       project throws `.notAGitRepository`, surfaced as a clean failure — we
//       NEVER dispatch the agent without a checkpoint to revert to.
//    2. runner.run()  — spawn the agent in the project, streaming substatus.
//    3. diffStat()    — on success, the `N files changed (+x −y)` summary.
//
//  The checkpoint (and its service) ride back on BOTH outcomes so the pill's
//  Revert (Milestone 7) can restore the tree — there is NO auto-revert on
//  failure (design §8): partial edits are left for the user to Revert or Retry.
//
//  Cap-1 (§9): the single shared `runner` rejects a second concurrent dispatch.
//

import Foundation
import os

/// Progress the pill reflects during a dispatch.
enum DevDispatchPhase: Equatable, Sendable {
    case checkpointing
    case dispatching
    case running(DevRunSubstatus)
}

/// Why a dispatch ended badly. `userMessage` is the single-line pill string.
enum DevDispatchFailure: Equatable, Sendable {
    /// The chosen folder isn't inside a git repo (Phase 1 requires one, §4).
    case notAGitRepo
    /// `git` couldn't be found on the system.
    case gitUnavailable
    /// A stale `.git/index.lock` is blocking git's index writes (left by an
    /// interrupted git/agent run). Distinct from `checkpointFailed` so we can
    /// give the one-line fix.
    case indexLocked
    /// Taking the pre-run checkpoint threw for some other reason.
    case checkpointFailed
    /// The agent couldn't be resolved/spawned (not installed at dispatch).
    case agentUnavailable
    /// Generation produced no `agent_prompt` — nothing concrete to dispatch.
    case noChangeRequested
    /// Reverting the working tree to the checkpoint didn't fully restore it
    /// (a git op threw, or a residual diff remained). The checkpoint is kept
    /// so the user can try Revert again. (Milestone 7.)
    case revertFailed
    /// The user cancelled at the pre-edit confirm gate (Ask Permission review) —
    /// the agent never ran, so the caller discards the checkpoint (nothing to
    /// revert). Never rendered.
    case confirmDeclined
    /// The agent process itself failed (non-zero exit, timeout, …).
    case agent(DevRunFailureReason)

    var userMessage: String {
        switch self {
        case .notAGitRepo:
            return "Dev Mode needs a git repo. Pick a folder that's inside one."
        case .gitUnavailable:
            return "Couldn't find git on your system."
        case .indexLocked:
            return "A leftover git lock is blocking edits. In Terminal, run: rm -f .git/index.lock in your project, then Retry."
        case .checkpointFailed:
            return "Couldn't snapshot the project before editing."
        case .agentUnavailable:
            return "The coding agent isn't available. Check it's installed."
        case .noChangeRequested:
            return "No concrete change to make. I didn't catch an edit to dispatch."
        case .revertFailed:
            return "Couldn't fully restore your files. Check your working tree."
        case .confirmDeclined:
            return "Cancelled."
        case .agent(let reason):
            switch reason {
            case .nonZeroExit(_, let tail):
                return tail.isEmpty ? "The agent exited with an error." : tail
            case .spawnFailed:          return "Couldn't start the coding agent."
            case .busy:                 return "A Dev Mode run is already in progress."
            case .cancelled:            return "Cancelled."
            }
        }
    }

    /// A short, bold label for the expanded failure card's header. `userMessage`
    /// is the full prose detail shown beneath it (wrapped + scrollable, never
    /// truncated) — so this is just the at-a-glance category, not the message.
    /// Mirrors the `.error` / `.failureExpanded` cards' headline-over-detail split.
    var headline: String {
        switch self {
        case .notAGitRepo:      return "Dev Mode needs a git repo"
        case .gitUnavailable:   return "Git unavailable"
        case .indexLocked:      return "Git is locked"
        case .checkpointFailed: return "Couldn\u{2019}t snapshot the project"
        case .agentUnavailable: return "Coding agent unavailable"
        case .noChangeRequested: return "Nothing to change"
        case .revertFailed:     return "Couldn\u{2019}t restore your files"
        case .confirmDeclined:  return "Cancelled"
        case .agent(let reason):
            switch reason {
            case .nonZeroExit:  return "Couldn\u{2019}t apply changes"
            case .spawnFailed:  return "Couldn\u{2019}t start the agent"
            case .busy:         return "A run is already in progress"
            case .cancelled:    return "Run stopped"
            }
        }
    }
}

@MainActor
final class DevDispatchCoordinator {

    /// A non-negotiable Dev Mode invariant appended to EVERY agent prompt right
    /// before dispatch: the coding agent edits files and STOPS — it must never
    /// commit, stage, or push. Dev Mode owns the version-control decision (the
    /// developer reviews the diff in the result card and commits themselves, §7),
    /// and the git checkpoint is the revert containment — an agent commit would
    /// bury its edits in history and defeat that.
    ///
    /// This is belt-and-suspenders on top of the edits-only permission posture
    /// (§11): that posture denies the shell for Claude Code (`--disallowedTools
    /// Bash`) and Cursor's default `-p`, but it does NOT cover the allow-commands
    /// opt-in, Codex's `workspace-write` sandbox (which can run a local `git
    /// commit`), or a user who has globally weakened Cursor's auto-run. The
    /// instruction closes that gap for every agent and both permission modes, and
    /// — unlike a rule in the generation system prompt — is deterministic rather
    /// than model-dependent. Appended (not part of the change spec) so it rides
    /// the same well-attended tail position for every run; the result card's
    /// shown change spec is unchanged.
    static let noCommitInstruction = """
    IMPORTANT — DO NOT COMMIT OR PUSH:
    Make only the file edits described above, then stop. Do NOT run `git commit`, \
    `git push`, `git add`, `git stash`, or any other command that stages, records, \
    or publishes changes — not even if the task looks finished or it seems helpful. \
    Leave every change unstaged and uncommitted in the working tree so the developer \
    can review the diff and commit it themselves. Committing, staging, and pushing \
    are never your responsibility.
    """

    /// One shared runner so the cap-1 concurrency guard (§9) spans every
    /// dispatch, not just one call.
    private let runner: DevAgentRunner

    /// Set by `cancel()` to abort the current dispatch. Checked right after the
    /// checkpoint so a cancel that lands BEFORE the agent spawns (e.g. during
    /// checkpointing) skips the run entirely; a cancel DURING the run is handled
    /// by `runner.cancel()` terminating the process. Reset at each `dispatch`.
    private var cancelled = false

    init(runner: DevAgentRunner = ClaudeCodeAgentRunner()) {
        self.runner = runner
    }

    /// Abort the in-flight dispatch (M7 #3): terminate the running agent and
    /// short-circuit a not-yet-spawned one. The dispatch resolves with an
    /// `.agent(.cancelled)` failure carrying the checkpoint, so the caller can
    /// auto-revert. A no-op when nothing is dispatching.
    func cancel() {
        cancelled = true
        runner.cancel()
    }

    /// Quit-path abort (G-02): synchronously SIGKILL the agent's whole process
    /// group before returning. `prepareForTermination` calls this instead of
    /// `cancel()` — cancel's terminate hops onto the runner's queue
    /// asynchronously, and `applicationShouldTerminate` answers `.terminateNow`
    /// immediately after, so the app could exit before that hop ran, orphaning
    /// the agent and everything it spawned. Also flags `cancelled` so a dispatch
    /// suspended before the spawn aborts if the app somehow lives on. A no-op
    /// when nothing is dispatching, and never blocks quit.
    func terminateNow() {
        cancelled = true
        runner.terminateNow()
    }

    struct Success: Sendable {
        let checkpoint: GitCheckpoint
        let service: GitCheckpointService
        let diff: GitDiffStat
        /// The agent's final message text (from the stream-json `result` event),
        /// or nil when it gave none — the result card then generates a fallback
        /// change line from `diff`. (Result-card handoff, Part A.)
        let summary: String?
        /// The readable unified diff shown in the result card's body well, already
        /// capped (Part B). Empty when the diff couldn't be produced.
        let diffText: String
    }

    enum Outcome {
        case succeeded(Success)
        /// `checkpoint`/`service` are non-nil only once a checkpoint was taken
        /// (i.e. the agent actually ran), so Revert is offered exactly when
        /// there's something to revert to. `diff` is the partial-edit stat the
        /// agent managed before failing (vs. the checkpoint) — nil when no
        /// checkpoint was taken; surfaced for analytics (M8 `files_changed`),
        /// not shown in the failure pill.
        case failed(DevDispatchFailure, checkpoint: GitCheckpoint?, service: GitCheckpointService?, diff: GitDiffStat?)
    }

    /// Run the full sequence. `onPhase` is invoked on the main actor as the
    /// dispatch advances. Git work is offloaded so the main thread never blocks
    /// on a stash/diff.
    func dispatch(
        prompt: String,
        projectURL: URL,
        agent: DevAgentEntry,
        tier: DevPermissionTier,
        // Phase 2: the selected `--model` id, or nil to run the agent's own
        // default. Forwarded to the runner, which appends `--model <id>` only
        // when non-nil AND the agent declares a model flag.
        model: String? = nil,
        onCheckpoint: @escaping @MainActor (GitCheckpoint, GitCheckpointService) -> Void = { _, _ in },
        // The pre-edit confirm gate (Ask Permission review), run AFTER the
        // checkpoint and BEFORE the agent. Returns true to proceed, false to abort
        // (cancelled). Defaults to "proceed" so non-dev callers and the Auto
        // Approve path are unaffected.
        confirmGate: @escaping @MainActor () async -> Bool = { true },
        // Phase 4: the live activity feed + the (non-terminating) stall notifier.
        // Defaulted to no-ops so the legacy single-line callers (and tests) that
        // only consume `onPhase` are unaffected; the dev pill wires these to the
        // feed log + the stall prompt.
        onEvent: @escaping @MainActor (DevAgentEvent) -> Void = { _ in },
        onStall: @escaping @MainActor (Bool) -> Void = { _ in },
        onPhase: @escaping @MainActor (DevDispatchPhase) -> Void
    ) async -> Outcome {
        cancelled = false
        onPhase(.checkpointing)

        // Build the service (locates git) + take the checkpoint, off-main.
        let service: GitCheckpointService
        do {
            service = try GitCheckpointService(projectURL: projectURL)
        } catch GitCheckpointError.gitUnavailable {
            return .failed(.gitUnavailable, checkpoint: nil, service: nil, diff: nil)
        } catch {
            // Keep the underlying reason (git stderr tail / fs error) in the device
            // log so a checkpoint failure is diagnosable — the pill only shows the
            // generic message, and analytics carry the coarse code only. .private:
            // the detail can include repo paths.
            Log.dev.error("Dev checkpoint setup failed: \(String(describing: error), privacy: .private)")
            return .failed(.checkpointFailed, checkpoint: nil, service: nil, diff: nil)
        }

        let checkpoint: GitCheckpoint
        do {
            checkpoint = try await Task.detached { try service.checkpoint() }.value
        } catch GitCheckpointError.notAGitRepository {
            return .failed(.notAGitRepo, checkpoint: nil, service: nil, diff: nil)
        } catch GitCheckpointError.indexLocked {
            // A stale .git/index.lock — give the actionable fix, not the generic
            // message. Logged so the device trail still shows it.
            Log.dev.error("Dev checkpoint failed: stale git index lock (.git/index.lock)")
            return .failed(.indexLocked, checkpoint: nil, service: nil, diff: nil)
        } catch {
            Log.dev.error("Dev checkpoint failed: \(String(describing: error), privacy: .private)")
            return .failed(.checkpointFailed, checkpoint: nil, service: nil, diff: nil)
        }

        // Surface the checkpoint immediately so the caller can revert it on a
        // cancel/quit even before the agent finishes (M7 #3).
        onCheckpoint(checkpoint, service)

        // A cancel that landed during checkpointing aborts BEFORE the agent runs
        // — nothing to revert (checkpoint() doesn't touch the tree), but the
        // checkpoint rides back so the caller's teardown is uniform.
        if cancelled {
            return .failed(.agent(.cancelled), checkpoint: checkpoint, service: service, diff: nil)
        }

        // The pre-edit confirm gate: checkpoint taken, agent NOT yet run. A
        // cancelled gate aborts here; the checkpoint rides back so the caller
        // discards it (the tree is untouched — nothing to revert).
        let proceed = await confirmGate()
        if !proceed {
            return .failed(.confirmDeclined, checkpoint: checkpoint, service: service, diff: nil)
        }
        if cancelled {
            return .failed(.agent(.cancelled), checkpoint: checkpoint, service: service, diff: nil)
        }

        // Dispatch the agent — it edits the working tree directly. The change
        // spec is the generated `agent_prompt`; we append the Dev Mode
        // do-not-commit invariant so EVERY agent (any permission mode) is told,
        // deterministically, to leave the edits uncommitted for the developer.
        onPhase(.dispatching)
        let runResult = await runner.run(
            entry: agent,
            tier: tier,
            prompt: Self.promptWithDevModeGuards(prompt),
            projectURL: projectURL,
            timeouts: .default,
            model: model,
            onEvent: { event in
                Task { @MainActor in
                    // Rich event → the live feed; its coarse substatus → the
                    // legacy single-line phase (kept until the feed UI lands).
                    onEvent(event)
                    onPhase(.running(event.substatus))
                }
            },
            onStall: { isStalled in
                Task { @MainActor in onStall(isStalled) }
            }
        )

        switch runResult {
        case .succeeded(let summary):
            // One off-main hop computes both the stat and the readable diff text
            // (Part B) against the checkpoint; either degrades gracefully if git
            // throws (.zero stat / empty text) rather than failing the success.
            let (diff, diffText) = await Task.detached {
                let stat = (try? service.diffStat(since: checkpoint)) ?? .zero
                let text = (try? service.diff(since: checkpoint)) ?? ""
                return (stat, text)
            }.value
            return .succeeded(Success(
                checkpoint: checkpoint, service: service,
                diff: diff, summary: summary, diffText: diffText
            ))
        case .failed(let reason):
            // No auto-revert (§8) — keep the checkpoint so the user can Revert.
            // Compute the partial-edit stat (how far the agent got before
            // failing) for analytics; nil if the diff itself errors.
            let diff = try? await Task.detached { try service.diffStat(since: checkpoint) }.value
            return .failed(.agent(reason), checkpoint: checkpoint, service: service, diff: diff)
        }
    }

    /// The final prompt handed to the coding agent: the generated change spec
    /// followed by the Dev Mode invariants (currently the do-not-commit guard),
    /// separated by a blank line so the guard reads as its own closing block. The
    /// change spec is preserved verbatim — the guard is only ever appended.
    static func promptWithDevModeGuards(_ prompt: String) -> String {
        let spec = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return noCommitInstruction }
        return spec + "\n\n" + noCommitInstruction
    }
}
