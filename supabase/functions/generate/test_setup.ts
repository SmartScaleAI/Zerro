// Test-only side effect. Imported FIRST by handler_test.ts (before any module
// that reads config.ts), so config.ts picks up these values at evaluation time.
// We shrink the payload fuse to a small value so the oversized-payload path is
// exercisable with a modest body instead of an actual 60 MB request — while
// staying well above the tiny happy-path / 201-frame test bodies.
Deno.env.set("GENERATE_MAX_PAYLOAD_BYTES", "50000");
