// Regression guard for THIRD_PARTY_NOTICES.md: the generator excludes
// devDependencies, but `shadcn` is a devDependency whose `tailwind.css` is
// compiled into the shipped stylesheet (app/globals.css imports it), so its
// notice must stay in the generated file — while the CLI-only tree it drags
// in (@modelcontextprotocol/sdk, hono, express, …) must not appear merely
// because shadcn does. Deterministic: reads only checked-in files.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { test } from "node:test"

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..")
const notices = readFileSync(join(webRoot, "THIRD_PARTY_NOTICES.md"), "utf8")
const lock = JSON.parse(readFileSync(join(webRoot, "package-lock.json"), "utf8")) as {
  packages: Record<string, { version?: string; dev?: boolean }>
}
const manifest = JSON.parse(readFileSync(join(webRoot, "package.json"), "utf8")) as {
  dependencies?: Record<string, string>
  devDependencies?: Record<string, string>
}
const globalsCss = readFileSync(join(webRoot, "app", "globals.css"), "utf8")

const inventory = notices.slice(
  notices.indexOf("## Package inventory"),
  notices.indexOf("## License texts"),
)
const inventoryRows = inventory
  .split("\n")
  .filter((l) => l.startsWith("| ") && !l.startsWith("| Package") && !l.startsWith("|---"))
  .map((l) => l.split("|").map((c) => c.trim()))
  .map(([, name, version, license]) => ({ name, version, license }))
const listed = (name: string) => inventoryRows.filter((r) => r.name === name)

/** True when no lockfile node for `name` is a production (non-dev) node. */
const devOnlyInLock = (name: string) =>
  Object.entries(lock.packages)
    .filter(([path]) => path.endsWith(`node_modules/${name}`))
    .every(([, entry]) => entry.dev === true)

test("shadcn is a devDependency whose CSS is imported by the site", () => {
  assert.equal(manifest.dependencies?.shadcn, undefined)
  assert.ok(manifest.devDependencies?.shadcn, "shadcn must be declared in devDependencies")
  assert.equal(lock.packages["node_modules/shadcn"]?.dev, true)
  assert.match(globalsCss, /@import\s+"shadcn\/tailwind\.css";/)
})

test("notices list shadcn@4.8.2 with its MIT license and copyright notice", () => {
  const shadcnVersion = lock.packages["node_modules/shadcn"]?.version
  assert.equal(shadcnVersion, "4.8.2")
  assert.deepEqual(listed("shadcn"), [{ name: "shadcn", version: "4.8.2", license: "MIT" }])
  assert.ok(notices.includes("shadcn@4.8.2"), "license-text heading must name shadcn@4.8.2")
  assert.ok(
    notices.includes("Copyright (c) 2023 shadcn"),
    "shadcn's copyright notice must be reproduced",
  )
})

test("notices explain that bundled build dependencies are included", () => {
  assert.match(notices, /explicitly identified build dependencies whose\ncontent is bundled into the deployed site/)
  assert.match(notices, /`shadcn`, whose\n`tailwind\.css` is compiled into the shipped stylesheet/)
})

test("shadcn's CLI-only tree is not listed merely because shadcn is", () => {
  // These packages reach the lockfile only through shadcn's command-line
  // tooling. While no production dependency needs them, they must stay out
  // of the notices; if one ever becomes a production dependency the lock
  // will carry a non-dev node and this guard steps aside for it.
  for (const name of ["@modelcontextprotocol/sdk", "hono", "@hono/node-server", "express", "ts-morph"]) {
    assert.ok(devOnlyInLock(name), `${name} is expected to be development-only in package-lock.json`)
    assert.deepEqual(listed(name), [], `${name} must not appear in the notices inventory`)
    assert.ok(!notices.includes(`${name}@`), `${name} must not appear in any license-text heading`)
  }
})

test("no development-only package other than shadcn is listed", () => {
  for (const row of inventoryRows) {
    if (row.name === "shadcn") continue
    assert.ok(
      !devOnlyInLock(row.name),
      `${row.name}@${row.version} is development-only in the lockfile but listed in the notices`,
    )
  }
})
