// Test-only side effect. Imported FIRST by the convert tests (before any
// module that reads config.ts), so config.ts picks up these values at
// evaluation time. Shrinks the payload fuse so the oversized-payload path is
// exercisable with a modest body — same pattern as generate/test_setup.ts.
Deno.env.set("CONVERT_MAX_PAYLOAD_BYTES", "50000");
