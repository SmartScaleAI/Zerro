/**
 * Site-wide configuration constants.
 */

/**
 * Direct download URL for the signed/notarized Zerro macOS DMG.
 *
 * Hosted on GitHub Releases. The `/releases/latest/download/<asset>` form always
 * resolves to the asset of the most recent (non-prerelease) release, so this URL
 * does not need to change when a new version ships — just upload a DMG asset with
 * the same filename to each release.
 *
 * TODO: replace `<owner>/<repo>` and the asset filename with the real values once
 * the first release is published (e.g. the app repo's releases page).
 */
export const DOWNLOAD_URL =
  "https://github.com/colinbreeding/zerro/releases/latest/download/Zerro.dmg";
