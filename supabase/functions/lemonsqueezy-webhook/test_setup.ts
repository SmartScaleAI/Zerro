// Test-only side effect. Imported FIRST by handler_test.ts (before handler.ts /
// config.ts load), so the variant→tier mapping is exercised end-to-end through
// the webhook with real variant ids (proving the Phase E comma-separated-list
// fix holds): variant 201/202 → Pro, 101/102 → Starter.
Deno.env.set("LS_VARIANT_STARTER", "101,102");
Deno.env.set("LS_VARIANT_PRO", "201,202");
// Which of the mapped variants are the YEARLY ones (102 = starter yearly,
// 202 = pro/Managed yearly) → billing_interval.
Deno.env.set("LS_VARIANT_YEARLY", "102,202");
// Top-up packs are one-time ORDER variants (Phase 5): Boost 200 / Power 500.
Deno.env.set("LS_VARIANT_TOPUP_BOOST", "301");
Deno.env.set("LS_VARIANT_TOPUP_POWER", "302");
