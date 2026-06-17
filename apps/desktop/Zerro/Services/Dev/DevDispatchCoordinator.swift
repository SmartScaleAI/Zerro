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
    /// The agent process itself failed (non-zero exit, timeout, …).
    case agent(DevRunFailureReason)

    var userMessage: String {
        switch self {
        case .notAGitRepo:
            return "Dev Mode needs a git repo — pick a folder that's inside one."
        case .gitUnavailable:
            return "Couldn't find git on your system."
        case .checkpointFailed:
            return "Couldn't snapshot the project before editing."
        case .agentUnavailable:
            return "The coding agent isn't available — check it's installed."
        case .noChangeRequested:
            return "No concrete change to make — I didn't catch an edit to dispatch."
        case .revertFailed:
            return "Couldn't fully restore your files — check your working tree."
        case .agent(let reason):
            switch reason {
            case .timeout(.wallClock):  return "The agent ran past the time limit and was stopped."
            case .timeout(.inactivity): return "The agent went quiet and was stopped."
            case .nonZeroExit(_, let tail):
                return tail.isEmpty ? "The agent exited with an error." : tail
            case .spawnFailed:          return "Couldn't start the coding agent."
            case .busy:                 return "A Dev Mode run is already in progress."
            case .cancelled:            return "Cancelled."
            }
        }
    }
}

@MainActor
final class DevDispatchCoordinator {

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

    struct Success: Sendable {
        let checkpoint: GitCheckpoint
        let service: GitCheckpointService
        let diff: GitDiffStat
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
        permission: DevAgentPermission,
        onCheckpoint: @escaping @MainActor (GitCheckpoint, GitCheckpointService) -> Void = { _, _ in },
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
            return .failed(.checkpointFailed, checkpoint: nil, service: nil, diff: nil)
        }

        let checkpoint: GitCheckpoint
        do {
            checkpoint = try await Task.detached { try service.checkpoint() }.value
        } catch GitCheckpointError.notAGitRepository {
            return .failed(.notAGitRepo, checkpoint: nil, service: nil, diff: nil)
        } catch {
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

        // Dispatch the agent — it edits the working tree directly.
        onPhase(.dispatching)
        let runResult = await runner.run(
            entry: agent,
            permission: permission,
            prompt: prompt,
            projectURL: projectURL,
            onSubstatus: { sub in
                Task { @MainActor in onPhase(.running(sub)) }
            }
        )

        switch runResult {
        case .succeeded:
            let diff = (try? await Task.detached { try service.diffStat(since: checkpoint) }.value) ?? .zero
            return .succeeded(Success(checkpoint: checkpoint, service: service, diff: diff))
        case .failed(let reason):
            // No auto-revert (§8) — keep the checkpoint so the user can Revert.
            // Compute the partial-edit stat (how far the agent got before
            // failing) for analytics; nil if the diff itself errors.
            let diff = try? await Task.detached { try service.diffStat(since: checkpoint) }.value
            return .failed(.agent(reason), checkpoint: checkpoint, service: service, diff: diff)
        }
    }
}
