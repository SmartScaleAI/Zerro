import assert from "node:assert/strict"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { test } from "node:test"
import {
  APPCAST_ASSET_URL,
  APPCAST_PATH,
  DMG_ASSET_URL,
  DMG_PATH,
  RELEASE_ASSET_BASE_URL,
  RELEASE_REDIRECTS,
  RELEASE_REPOSITORY,
} from "./release-routes.ts"
import nextConfig from "../next.config.ts"

// Run with: npm test  (Node's built-in runner strips the TS types natively)
//
// Pins the public release-routing contract: the two stable getzerro.app URLs
// that installed apps and marketing links depend on must redirect to the
// matching asset on the latest GitHub Release of the app repository, nothing
// on the website may still route them anywhere else, and no static copy of
// either artifact may be committed under apps/web/public. The CI job
// `release-routing-guard` checks the same contract from the shell; this test
// additionally verifies the routes Next.js actually resolves from
// next.config.ts.

const WEB_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")

const EXPECTED_APPCAST_URL =
  "https://github.com/SmartScaleAI/Zerro/releases/latest/download/appcast.xml"
const EXPECTED_DMG_URL =
  "https://github.com/SmartScaleAI/Zerro/releases/latest/download/Zerro.dmg"

/** Hosts that must never appear in the public release routing. */
const FORBIDDEN_HOST_FRAGMENTS = ["supabase.co", "storage/v1"]

type Route = { source: string; destination: string; permanent?: boolean }

async function resolvedRedirects(): Promise<Route[]> {
  assert.equal(typeof nextConfig.redirects, "function")
  return (await nextConfig.redirects!()) as Route[]
}

async function resolvedRewrites(): Promise<Route[]> {
  assert.equal(typeof nextConfig.rewrites, "function")
  const rewrites = await nextConfig.rewrites!()
  return Array.isArray(rewrites)
    ? (rewrites as Route[])
    : ([
        ...(rewrites.beforeFiles ?? []),
        ...(rewrites.afterFiles ?? []),
        ...(rewrites.fallback ?? []),
      ] as Route[])
}

test("release asset URLs point at the latest GitHub Release of the app repository", () => {
  assert.equal(RELEASE_REPOSITORY, "SmartScaleAI/Zerro")
  assert.equal(
    RELEASE_ASSET_BASE_URL,
    "https://github.com/SmartScaleAI/Zerro/releases/latest/download/"
  )
  assert.equal(APPCAST_ASSET_URL, EXPECTED_APPCAST_URL)
  assert.equal(DMG_ASSET_URL, EXPECTED_DMG_URL)
  assert.equal(APPCAST_ASSET_URL, `${RELEASE_ASSET_BASE_URL}appcast.xml`)
  assert.equal(DMG_ASSET_URL, `${RELEASE_ASSET_BASE_URL}Zerro.dmg`)
})

test("the stable getzerro.app paths are the ones installed apps and links use", () => {
  assert.equal(APPCAST_PATH, "/appcast.xml")
  assert.equal(DMG_PATH, "/Zerro.dmg")
})

test("RELEASE_REDIRECTS maps each stable path to its asset with a temporary redirect", () => {
  assert.deepEqual(RELEASE_REDIRECTS, [
    {
      source: "/appcast.xml",
      destination: EXPECTED_APPCAST_URL,
      permanent: false,
    },
    { source: "/Zerro.dmg", destination: EXPECTED_DMG_URL, permanent: false },
  ])
})

/** The contract, spelled out independently of lib/release-routes.ts. */
const EXPECTED_REDIRECTS = [
  {
    source: "/appcast.xml",
    destination: EXPECTED_APPCAST_URL,
    permanent: false,
  },
  { source: "/Zerro.dmg", destination: EXPECTED_DMG_URL, permanent: false },
] as const

test("next.config.ts redirects /appcast.xml and /Zerro.dmg to the GitHub Release assets", async () => {
  const redirects = await resolvedRedirects()

  for (const expected of EXPECTED_REDIRECTS) {
    const matches = redirects.filter((r) => r.source === expected.source)
    assert.equal(
      matches.length,
      1,
      `${expected.source} must have exactly one redirect (found ${matches.length})`
    )
    const actual = matches[0]
    assert.equal(
      actual.destination,
      expected.destination,
      `${expected.source} must redirect to ${expected.destination}`
    )
    assert.equal(
      actual.permanent,
      false,
      `${expected.source} must stay a temporary redirect so a new release is picked up immediately`
    )
  }
})

test("each release asset URL is the destination of exactly one redirect", async () => {
  const redirects = await resolvedRedirects()
  for (const expected of EXPECTED_REDIRECTS) {
    const targets = redirects.filter(
      (r) => r.destination === expected.destination
    )
    assert.deepEqual(
      targets.map((r) => r.source),
      [expected.source],
      `${expected.destination} must be reached only from ${expected.source}`
    )
  }
})

test("neither stable path is served by a rewrite", async () => {
  const rewrites = await resolvedRewrites()
  for (const expected of EXPECTED_REDIRECTS) {
    assert.ok(
      !rewrites.some((r) => r.source === expected.source),
      `${expected.source} must be served by a redirect, not a rewrite`
    )
    assert.ok(
      !rewrites.some((r) => r.destination === expected.destination),
      `${expected.destination} must not be proxied by a rewrite`
    )
  }
  // The PostHog reverse proxy is unrelated routing and must survive untouched.
  assert.ok(rewrites.some((r) => r.source === "/ingest/static/:path*"))
  assert.ok(rewrites.some((r) => r.source === "/ingest/:path*"))
})

test("no resolved route sends release traffic anywhere but GitHub Releases", async () => {
  const routes = [...(await resolvedRedirects()), ...(await resolvedRewrites())]
  for (const route of routes) {
    for (const fragment of FORBIDDEN_HOST_FRAGMENTS) {
      assert.ok(
        !route.destination.includes(fragment),
        `${route.source} → ${route.destination} must not route through ${fragment}`
      )
    }
  }
})

test("no static appcast or DMG is committed under apps/web/public", () => {
  for (const name of ["appcast.xml", "Zerro.dmg"]) {
    const path = join(WEB_ROOT, "public", name)
    assert.ok(
      !existsSync(path),
      `${path} must not exist — a committed copy would go stale on the next release`
    )
  }
})
