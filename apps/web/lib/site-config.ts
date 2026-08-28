/**
 * Site-wide configuration constants.
 */

/**
 * Direct download URL for the signed/notarized Zerro macOS DMG.
 *
 * Public-facing, stable link. It is redirected (307, `permanent: false`) to the
 * `Zerro.dmg` asset on the latest GitHub Release of the app repository — see
 * `RELEASE_REDIRECTS` in lib/release-routes.ts, wired up in next.config.ts —
 * so this URL never has to change across releases and any existing links to
 * it keep working.
 */
export const DOWNLOAD_URL = "https://getzerro.app/Zerro.dmg";
