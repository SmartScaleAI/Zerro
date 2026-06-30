// Test-only side effect. Imported FIRST by handler_test.ts (before handler.ts /
// config.ts load). Single managed tier: every subscription variant → 'managed';
// the only variant distinction left is which ids are YEARLY (billing_interval).
Deno.env.set("LS_VARIANT_MANAGED", "101,102,201,202");
// Which of the managed variants are the YEARLY ones (102, 202) → billing_interval.
Deno.env.set("LS_VARIANT_YEARLY", "102,202");
// Top-up packs are one-time ORDER variants. Registry order mini→mega; only the
// packs the handler tests exercise need ids wired here (Boost 200 / Power 500 /
// Mega 10,000) — the rest stay unset (""), i.e. "no match".
Deno.env.set("LS_VARIANT_TOPUP_BOOST", "301");
Deno.env.set("LS_VARIANT_TOPUP_POWER", "302");
Deno.env.set("LS_VARIANT_TOPUP_MEGA", "307");
