/**
 * Site-wide configuration constants.
 */

/**
 * Direct download URL for the signed/notarized Zerro macOS DMG.
 *
 * Public-facing, stable link. It is redirected (307, `permanent: false`) to the
 * public Supabase Storage `downloads/Zerro.dmg` object — overwritten by CI on
 * each release — via the `/Zerro.dmg` redirect in next.config.ts, so this URL
 * never has to change across releases and any existing links to it keep working.
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
 * Direct LemonSqueezy subscription checkout link for Zerro Cloud.
 *
 * Not used yet: every pricing CTA currently points to DOWNLOAD_URL, since users
 * download the app, get 30 free credits, then subscribe in-app. This is a
 * placeholder for if/when the Zerro Cloud card links straight to checkout.
 *
 * TODO(Colin): paste the LemonSqueezy checkout URL (the same one used in the
 * app's BillingLinks) and wire the Zerro Cloud CTA in pricing.tsx to it.
 */
export const CLOUD_CHECKOUT_URL = ""; // TODO: LemonSqueezy Zerro Cloud checkout
