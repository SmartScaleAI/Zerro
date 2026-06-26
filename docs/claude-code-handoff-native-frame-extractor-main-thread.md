# NativeFrameExtractor main-thread warning — RESOLVED (2026-06-26)

> **Status: fixed and verified.** Kept as a record because the fix corrects a
> non-obvious concurrency gotcha specific to this target's build settings. The
> original handoff (below the line) prescribed bare `nonisolated` and "don't
> touch the test" — **both were wrong** for this build config; see Correction.

## Symptom (original)

Thread Performance Checker runtime warnings ("This method should not be called on
the main thread as it may lead to UI unresponsiveness") on
`NativeFrameExtractorTests.testExtractsFrameAtNativeResolution()`. The test
passed; the warnings were runtime diagnostics.

## Actual root cause (two sources, not one)

1. **Production:** `NativeFrameExtractor.frame(atSeconds:from:)` was MainActor-
   isolated (the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
   un-annotated static is implicitly `@MainActor`), so its `AVAssetImageGenerator`
   decode ran on the main thread — for the test AND for the production caller
   `DevAnchorPipeline`.
2. **Test:** the bulk of the warnings (~18) actually fired *before* `frame`'s body
   ran, from the test helper `makeSolidVideo(...)` writing the synthetic `.mov`
   via `AVAssetWriter` / `adaptor.append` on the MainActor — not from `frame`.

## The fix that actually works — `@concurrent nonisolated`

Bare `nonisolated` is **not** sufficient in this target. It also sets
`SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables SE-0461
(`NonisolatedNonsendingByDefault`): under it a `nonisolated async` function runs
on the **caller's** executor, so a MainActor caller keeps it on main. The
attribute that forces the body onto the concurrent (off-actor) executor is
`@concurrent`. Confirmed empirically with a `Thread.isMainThread` probe: plain
`nonisolated` → on main; `@concurrent nonisolated` → off main.

Changes applied:

- `NativeFrameExtractor.swift`
  - `frame(atSeconds:from:)` → `@concurrent nonisolated` (load-bearing for
    off-main execution).
  - `crop(_:around:cropSize:)`, `jpegData(_:quality:)` → `nonisolated` (pure sync
    CG helpers; no `@concurrent` needed).
- `NativeFrameExtractorTests.swift`
  - `makeSolidVideo(...)` → `@concurrent nonisolated` (moves the `AVAssetWriter`
    writing off-main).
  - `makePixelBuffer(...)` → `nonisolated` (so the now-off-main writer can call it
    synchronously).
  - Assertions and video dimensions unchanged — only *where* the writing runs.

No call-site changes (`DevAnchorPipeline` and others already `await`/call these).
No new Sendable/isolation warnings.

## Result

`NativeFrameExtractorTests` passes with zero "main thread" warnings, and the
production full-res decode runs off the main thread.

## Reusable lesson

In this codebase (`SWIFT_APPROACHABLE_CONCURRENCY = YES`), "mark it `nonisolated`
to get off the main actor" is **wrong** — `nonisolated async` inherits the
caller's executor. Use `@concurrent` to guarantee off-actor execution.

---

_Original handoff prescription is superseded by the Correction above (it called
for bare `nonisolated` and no test change). Retained only as history._
