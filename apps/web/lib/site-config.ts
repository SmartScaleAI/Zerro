/**
 * Site-wide configuration constants.
 */

/**
 * Direct download URL for the signed/notarized Zerro macOS DMG.
 *
 * Public-facing, stable link. It is redirected (302) to GitHub's "latest release"
 * asset via the `/Zerro.dmg` rewrite in next.config.ts, so this URL never has to
 * change across releases — and any existing links to it keep working.
 */
export const DOWNLOAD_URL = "https://getzerro.app/Zerro.dmg";

/**
 * Supabase Edge Functions base. NOT a secret — it's the same public base the
 * Mac app ships with (the server enforces everything; the client is never
 * trusted). Used by the affiliate-capture beacon to record `?aff` clicks.
 */
export const FUNCTIONS_BASE_URL =
  "https://wjxqmurgwyxwkezncxke.supabase.co/functions/v1";

/**
 * Direct LemonSqueezy subscription checkout link for the Managed plan.
 *
 * Not used yet: every pricing CTA currently points to DOWNLOAD_URL, since users
 * download the app, get 30 free credits, then subscribe in-app. This is a
 * placeholder for if/when the Managed card links straight to checkout.
 *
 * TODO(Colin): paste the LemonSqueezy checkout URL (the same one used in the
 * app's BillingLinks) and wire the Managed CTA in pricing.tsx to it.
 */
export const MANAGED_CHECKOUT_URL = ""; // TODO: LemonSqueezy Managed checkout
