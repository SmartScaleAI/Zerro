/**
 * Site-wide configuration constants.
 */

/**
 * Direct download URL for the signed/notarized Zerro macOS DMG.
 *
 * The DMG is hosted on the site itself (served from `public/Zerro.dmg` via Vercel),
 * so the download target is the file at the site root.
 */
export const DOWNLOAD_URL = "https://getzerro.app/Zerro.dmg";

/**
 * Direct LemonSqueezy subscription checkout links for the Managed tiers.
 *
 * Not used yet: every pricing CTA currently points to DOWNLOAD_URL, since users
 * download the app, get 15 free generations, then subscribe in-app. These are
 * placeholders for if/when the Starter/Pro cards link straight to checkout.
 *
 * TODO(Colin): paste the LemonSqueezy checkout URLs (the same ones used in the
 * app's BillingLinks) and wire the Starter/Pro CTAs in pricing.tsx to them.
 */
export const STARTER_CHECKOUT_URL = ""; // TODO: LemonSqueezy Starter checkout
export const PRO_CHECKOUT_URL = ""; // TODO: LemonSqueezy Pro checkout
