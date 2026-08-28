/**
 * Public release-artifact routing for getzerro.app.
 *
 * GitHub Releases on the app repository are the canonical public source for
 * every official artifact. Each production release carries three assets:
 *
 *   - `Zerro-<build>.dmg` — the immutable archive the Sparkle feed references
 *   - `Zerro.dmg`         — a byte-identical stable "download latest" copy
 *   - `appcast.xml`       — the cumulative, signed Sparkle feed
 *
 * `releases/latest/download/<asset>` always resolves to the newest published,
 * non-prerelease, non-draft release, so the two stable getzerro.app URLs below
 * never have to change: installed apps keep `https://getzerro.app/appcast.xml`
 * baked in as their feed URL, and marketing links keep pointing at
 * `https://getzerro.app/Zerro.dmg`.
 *
 * Both paths are served by a temporary (307) redirect rather than a proxying
 * rewrite: GitHub itself answers `releases/latest/download/…` with a redirect
 * to its asset CDN, so proxying would only put the website in the download
 * path for every update check. A 307 is re-resolved on every request and is
 * never cached, so a new release is picked up immediately. Sparkle follows
 * redirects.
 *
 * This module is dependency-free on purpose: it is the single source of truth
 * that `next.config.ts` consumes and that `release-routes.test.ts` and the CI
 * `release-routing-guard` job verify.
 */

/** Owner/name of the repository whose GitHub Releases publish official builds. */
export const RELEASE_REPOSITORY = "SmartScaleAI/Zerro"

/** Base URL that resolves an asset name on the latest published release. */
export const RELEASE_ASSET_BASE_URL = `https://github.com/${RELEASE_REPOSITORY}/releases/latest/download/`

/** Canonical public URL of the Sparkle appcast on the latest release. */
export const APPCAST_ASSET_URL =
  "https://github.com/SmartScaleAI/Zerro/releases/latest/download/appcast.xml"

/** Canonical public URL of the stable latest-download DMG on the latest release. */
export const DMG_ASSET_URL =
  "https://github.com/SmartScaleAI/Zerro/releases/latest/download/Zerro.dmg"

/** Stable getzerro.app path installed apps use as their Sparkle feed URL. */
export const APPCAST_PATH = "/appcast.xml"

/** Stable getzerro.app path for the latest-download DMG. */
export const DMG_PATH = "/Zerro.dmg"

export interface ReleaseRedirect {
  source: string
  destination: string
  permanent: false
}

/**
 * The redirect entries `next.config.ts` installs for the two stable paths.
 *
 * Never commit a file at `apps/web/public/appcast.xml` or
 * `apps/web/public/Zerro.dmg`. GitHub Releases are the sole source for both
 * artifacts, so a repository copy would be redundant and stale the moment the
 * next release publishes (Next.js applies redirects before public-file
 * lookup, so it would not even be served). CI rejects both paths.
 */
export const RELEASE_REDIRECTS: readonly ReleaseRedirect[] = [
  { source: APPCAST_PATH, destination: APPCAST_ASSET_URL, permanent: false },
  { source: DMG_PATH, destination: DMG_ASSET_URL, permanent: false },
]
