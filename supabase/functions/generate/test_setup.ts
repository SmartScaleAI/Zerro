// Test-only side effect. Imported FIRST by handler_test.ts (before any module
// that reads config.ts), so config.ts picks up these values at evaluation time.
// We shrink the payload fuse to a small value so the oversized-payload path is
// exercisable with a modest body instead of an actual 60 MB request — while
// staying well above the tiny happy-path / 201-frame test bodies.
Deno.env.set("GENERATE_MAX_PAYLOAD_BYTES", "50000");
// Shrink the AUDIO byte cap too so the (now load-bearing) oversize-audio reject is
// exercisable with a modest body — well above the tiny happy-path audio (~16 bytes)
// and below the payload fuse, so audio_too_large fires before payload_too_large.
// The PRODUCTION default is 2 MB (≈ a 3-min 64 kbps recording + headroom; see
// config.ts). This 4 KB stand-in proves the mechanism, not the production sizing.
Deno.env.set("GENERATE_MAX_AUDIO_BYTES", "4096");
