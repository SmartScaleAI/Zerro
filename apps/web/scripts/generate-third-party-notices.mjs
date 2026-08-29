#!/usr/bin/env node
// Generates THIRD_PARTY_NOTICES.md for the website from the production
// dependency tree in package-lock.json, plus the explicitly listed build
// dependencies whose content is bundled into the deployed site. Uses only
// Node built-ins.
//
//   node scripts/generate-third-party-notices.mjs          # write the file
//   node scripts/generate-third-party-notices.mjs --check  # verify no drift
//
// License text comes from each installed package's own bundled license
// file(s); when a package ships more than one (for example an OR-licensed
// package offering alternatives), every provided text is reproduced. A
// package that ships no text falls back to a checked-in override in
// scripts/license-overrides/ (upstream license text fetched from the
// package's repository at the installed version, or its published
// metadata attribution), mapped by exact name@version in
// scripts/license-overrides/map.json. A dependency with neither a bundled
// text nor an override makes the script exit non-zero and be listed,
// never silently skipped.

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const textsDir = join(webRoot, "scripts", "license-texts");
const overridesDir = join(webRoot, "scripts", "license-overrides");
const outPath = join(webRoot, "THIRD_PARTY_NOTICES.md");

const lock = JSON.parse(readFileSync(join(webRoot, "package-lock.json"), "utf8"));
const overrides = JSON.parse(readFileSync(join(overridesDir, "map.json"), "utf8"));

const normalize = (s) =>
  s
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((l) => l.replace(/[ \t]+$/, ""))
    .join("\n")
    .trim();

// The SPDX MIT template's fill-in line is not a real notice; attribution
// for packages rendered with canonical terms lives in their override note.
const canonicalTerms = (id) =>
  normalize(readFileSync(join(textsDir, `${id}.txt`), "utf8"))
    .split("\n")
    .filter((l) => l.trim() !== "Copyright (c) <year> <copyright holders>")
    .join("\n");

// ---- build dependencies whose content ships to users ------------------------
// Packages declared under devDependencies are excluded from the inventory by
// default: they run at build or development time and nothing of theirs is
// delivered to website visitors. The packages named here are the exception —
// they are build-time tools, but part of their content is compiled into the
// deployed site, so their notices must be reproduced. Only the named package
// itself is included; its transitive dependency tree stays excluded, because
// that tree serves the tool (for example a CLI), not the shipped output.
//
//   - shadcn: app/globals.css imports `shadcn/tailwind.css`, which Tailwind
//     compiles into the stylesheet served to users. The shadcn CLI and its
//     dependencies never reach the deployed site.
const BUNDLED_BUILD_DEPENDENCIES = new Set(["shadcn"]);

// ---- collect entries, deduped by name@version -------------------------------
const deps = new Map();
for (const [path, entry] of Object.entries(lock.packages ?? {})) {
  if (!path.startsWith("node_modules/")) continue; // root project
  const name = path.slice(path.lastIndexOf("node_modules/") + "node_modules/".length);
  // Development-only, unless it is a top-level bundled build dependency.
  const isBundledBuildDep =
    BUNDLED_BUILD_DEPENDENCIES.has(name) && path === `node_modules/${name}`;
  if (entry.dev && !isBundledBuildDep) continue;
  if (name === "@zerro/web") continue; // workspace self-link, first-party
  const key = `${name}@${entry.version ?? "?"}`;
  const installed = existsSync(join(webRoot, path));
  const prev = deps.get(key);
  if (!prev || (!prev.installedPath && installed)) {
    deps.set(key, {
      name,
      version: entry.version ?? "?",
      license: entry.license ?? null,
      installedPath: installed ? join(webRoot, path) : null,
    });
  }
}

// ---- resolve license text for each dependency -------------------------------
const licenseFilesIn = (dir) =>
  readdirSync(dir)
    .filter((f) => /^(license|licence|copying)([-._].*)?$/i.test(f))
    .sort();

const unresolved = [];
for (const dep of deps.values()) {
  const key = `${dep.name}@${dep.version}`;
  if (dep.installedPath) {
    const pkgMeta = JSON.parse(readFileSync(join(dep.installedPath, "package.json"), "utf8"));
    dep.license ??= typeof pkgMeta.license === "string" ? pkgMeta.license : null;
    const files = licenseFilesIn(dep.installedPath);
    if (files.length === 1) {
      dep.text = normalize(readFileSync(join(dep.installedPath, files[0]), "utf8"));
    } else if (files.length > 1) {
      // Multiple bundled texts (e.g. an OR-licensed package offering
      // alternatives): reproduce every one, labeled by filename.
      const intro = `This package is distributed under "${dep.license}". All license texts provided with the package are reproduced below.`;
      dep.text = [
        intro,
        ...files.map(
          (f) => `--- ${f} ---\n\n${normalize(readFileSync(join(dep.installedPath, f), "utf8"))}`,
        ),
      ].join("\n\n");
    }
  }
  if (!dep.text) {
    const ov = overrides[key];
    if (!ov) {
      unresolved.push(`${key}: no bundled license text and no entry in scripts/license-overrides/map.json`);
      continue;
    }
    const parts = [];
    if (ov.note) parts.push(ov.note);
    for (const f of ov.files ?? []) {
      parts.push(`--- ${f} ---\n\n${normalize(readFileSync(join(overridesDir, f), "utf8"))}`);
    }
    for (const id of ov.canonical ?? []) {
      parts.push(`--- ${id} license terms ---\n\n${canonicalTerms(id)}`);
    }
    if (ov.source) parts.push(`Source: ${ov.source}`);
    if (parts.length === 0) {
      unresolved.push(`${key}: override entry provides no note, files, or canonical terms`);
      continue;
    }
    dep.text = parts.join("\n\n");
  }
  if (!dep.license) {
    unresolved.push(`${key}: no license declared in lockfile or package metadata`);
  }
}
if (unresolved.length) {
  console.error("UNRESOLVED LICENSES:\n" + unresolved.map((u) => `  - ${u}`).join("\n"));
  process.exit(2);
}

// ---- render -----------------------------------------------------------------
const sorted = [...deps.values()].sort((a, b) =>
  a.name === b.name ? a.version.localeCompare(b.version) : a.name.localeCompare(b.name),
);

// Group byte-identical license texts so shared texts appear once.
const groups = new Map();
for (const dep of sorted) {
  const hash = createHash("sha256").update(dep.text).digest("hex");
  if (!groups.has(hash)) groups.set(hash, { text: dep.text, packages: [] });
  groups.get(hash).packages.push(dep);
}
const orderedGroups = [...groups.values()].sort((a, b) =>
  a.packages[0].name.localeCompare(b.packages[0].name),
);

const lines = [];
lines.push("# Third-Party Notices — Zerro website");
lines.push("");
lines.push("The Zerro website (`apps/web`) is built with the open-source packages");
lines.push("listed below. Each remains subject to its own license, reproduced in");
lines.push("the [License texts](#license-texts) section. This file is generated");
lines.push("by `scripts/generate-third-party-notices.mjs` from the production");
lines.push("dependency tree plus the explicitly identified build dependencies whose");
lines.push("content is bundled into the deployed site (currently `shadcn`, whose");
lines.push("`tailwind.css` is compiled into the shipped stylesheet; its command-line");
lines.push("tooling and that tooling's dependencies are not part of the site).");
lines.push("Regenerate it after dependency changes and verify with");
lines.push("`npm run notices:check`.");
lines.push("");
lines.push("The Inter typeface, embedded in the built site, is licensed under the");
lines.push("SIL Open Font License 1.1 — see the [Inter](#inter-typeface) section.");
lines.push("");
lines.push(`## Package inventory (${sorted.length} packages)`);
lines.push("");
lines.push("| Package | Version | License |");
lines.push("|---|---|---|");
for (const dep of sorted) {
  lines.push(`| ${dep.name} | ${dep.version} | ${dep.license} |`);
}
lines.push("");
lines.push("## License texts");
lines.push("");
let n = 0;
for (const g of orderedGroups) {
  n += 1;
  lines.push(`### Text ${n}: ${g.packages.map((p) => `${p.name}@${p.version}`).join(", ")}`);
  lines.push("");
  lines.push("```text");
  lines.push(g.text.replaceAll("```", "'''"));
  lines.push("```");
  lines.push("");
}
lines.push("## Inter typeface");
lines.push("");
lines.push("The site embeds the Inter font family (via `next/font`), licensed");
lines.push("under the SIL Open Font License 1.1:");
lines.push("");
lines.push("```text");
lines.push(normalize(readFileSync(join(textsDir, "OFL-1.1-Inter.txt"), "utf8")));
lines.push("```");
lines.push("");
const output = lines.join("\n");

if (process.argv.includes("--check")) {
  const current = existsSync(outPath) ? readFileSync(outPath, "utf8") : "";
  if (current !== output) {
    console.error("THIRD_PARTY_NOTICES.md is out of date. Run: npm run notices");
    process.exit(1);
  }
  console.log(`THIRD_PARTY_NOTICES.md is up to date (${sorted.length} packages).`);
} else {
  writeFileSync(outPath, output);
  console.log(`Wrote THIRD_PARTY_NOTICES.md (${sorted.length} packages, ${orderedGroups.length} unique texts).`);
}
