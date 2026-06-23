// =============================================================================
// SlotTable — TEST-ONLY in-memory stand-in for the generation_slots /
// trial_generation_slots tables that ACTUALLY honors the stale-reclaim window.
// =============================================================================
// NOT production code (no *_test suffix only so it can be imported by the test
// files; nothing ships it). The handler fakes previously modeled a slot as a bare
// Set<string>, which IGNORED the staleSeconds argument entirely (review finding
// B-09). Because of that, no unit test could exercise the stale-reclaim path, and
// the A-04 timing bug — stale window (180s) SHORTER than the worst-case slot hold
// (~480s across STT + chat) — slipped through.
//
// This fake mirrors acquire_generation_slot / acquire_trial_slot semantics from
// the SQL migrations (billing_generate_slots.sql / billing_trial_credits.sql):
//   * no row             → acquire        → TRUE
//   * row, still FRESH   → busy           → FALSE   [age < staleSeconds]
//   * row, STALE         → stale-reclaim  → TRUE    [age ≥ staleSeconds]
// release() is an idempotent delete, like release_*_slot.
//
// Time is a FAKE clock (`nowMs`, default 0) so a test can age a slot past — or
// hold it within — the reclaim window deterministically, with no real time
// passing. `seed(id, ageSeconds)` plants a held slot acquired `ageSeconds` in the
// past (negative `acquired_at` relative to nowMs is fine — only the delta is used).
// =============================================================================
export class SlotTable {
  /** id → acquired_at on the fake clock (ms). */
  private readonly held = new Map<string, number>();
  /** Fake clock (ms). Bump to advance time; `seed` ages relative to it. */
  nowMs = 0;

  /** Mirrors acquire_*_slot(p_stale_seconds): claim a free slot, RECLAIM one
   *  older than staleSeconds, else refuse a still-live (fresh) slot. */
  acquire(id: string, staleSeconds: number): boolean {
    const acquiredAt = this.held.get(id);
    if (acquiredAt !== undefined && this.nowMs - acquiredAt < staleSeconds * 1000) {
      return false; // a fresh slot is held → busy (cap-1 holds)
    }
    this.held.set(id, this.nowMs); // acquire (no row) or stale-reclaim
    return true;
  }

  /** Mirrors release_*_slot: idempotent delete. */
  release(id: string): void {
    this.held.delete(id);
  }

  /** Plant a held slot acquired `ageSeconds` before `nowMs` (default: just now).
   *  Simulates an in-flight (small age) or crashed (age ≥ stale window) request's
   *  slot in a handler test, without standing up a real concurrent request. */
  seed(id: string, ageSeconds = 0): void {
    this.held.set(id, this.nowMs - ageSeconds * 1000);
  }

  // ---- Back-compat surface so existing Set-era assertions/seeds keep working --
  get size(): number {
    return this.held.size;
  }
  has(id: string): boolean {
    return this.held.has(id);
  }
  /** Seed a freshly-held slot (age 0) — the Set-era `.add(id)` spelling. */
  add(id: string): void {
    this.held.set(id, this.nowMs);
  }
  delete(id: string): void {
    this.held.delete(id);
  }
}
