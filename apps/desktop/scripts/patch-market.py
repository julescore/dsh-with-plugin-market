#!/usr/bin/env python3
"""Apply desktop-distribution-only aliases and curated market policies."""

from pathlib import Path
import json
import sys


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    """Replace one version-pinned upstream fragment or stop the build."""
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"desktop build: bundled market {label} is unexpected")
    path.write_text(text.replace(old, new, 1))


package_dir = Path(sys.argv[1])
overrides_source = Path(sys.argv[2])
overrides = json.loads(overrides_source.read_text())
if not isinstance(overrides, dict) or len(overrides) != 1:
    raise SystemExit("desktop build: market overrides must contain exactly one repository")
url, override = next(iter(overrides.items()))
source_urls = [
    "https://github.com/zhu1090093659/dsh-web-ui",
    "https://github.com/zhu1090093659/dsh-web-ui/tree/main/packages/dsh-web-ui-all",
]
expected = {
    "sourceUrls": source_urls,
    "npm": "@linxin666/dsh-web-ui-all",
    "install": "dsh plugin --profile web add @linxin666/dsh-web-ui-all",
    "denyBuilds": ["cloudflared", "cpu-features", "ssh2"],
}
if url != source_urls[0] or override != expected:
    raise SystemExit("desktop build: dsh-web-ui market override is unexpected")

manifest_path = package_dir / "package.json"
manifest = json.loads(manifest_path.read_text())
if manifest.get("name") != "dshmarket" or manifest.get("version") != "1.2.3":
    raise SystemExit("desktop build: bundled market must be unmodified dshmarket@1.2.3")
manifest["name"] = "dshmarket-bundled"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

replace_once(
    package_dir / "client/client.js",
    'window.__ModuleLoader__.load({ id: "dshmarket", factory: (require) => {',
    'window.__ModuleLoader__.load({ id: "dshmarket-bundled", factory: (require) => {',
    "client registration",
)

(package_dir / "data/distribution-overrides.json").write_text(
    json.dumps(overrides, indent=2) + "\n"
)

registry_ts_policy = """
export interface DistributionOverride {
  sourceUrls: string[]
  npm: string
  install: string
  denyBuilds: string[]
}

const overridesPath = fileURLToPath(new URL('../data/distribution-overrides.json', import.meta.url))
const distributionOverrides = JSON.parse(readFileSync(overridesPath, 'utf8')) as Record<string, DistributionOverride>

function normalizeSourceUrl(url: string): string {
  return url.toLowerCase().replace(/\\/+$/, '')
}

/** Return the desktop distribution policy for one approved repository URL. */
export function distributionOverride(url: string): DistributionOverride | undefined {
  const expected = normalizeSourceUrl(url)
  return Object.values(distributionOverrides).find(rule =>
    rule.sourceUrls.some(candidate => normalizeSourceUrl(candidate) === expected))
}

function applyDistributionOverrides(registry: Registry): Registry {
  return {
    ...registry,
    plugins: registry.plugins.map(plugin => {
      const rule = distributionOverride(plugin.url)
      return rule === undefined ? plugin : { ...plugin, npm: rule.npm, install: rule.install }
    }),
  }
}
"""
replace_once(
    package_dir / "src/registry.ts",
    "const TTL_MS = 60 * 60 * 1000\n\nlet cache: { at: number; data: Registry } | null = null\n",
    "const TTL_MS = 60 * 60 * 1000\n" + registry_ts_policy + "\nlet cache: { at: number; data: Registry } | null = null\n",
    "TypeScript registry policy insertion",
)
replace_once(
    package_dir / "src/registry.ts",
    "  return JSON.parse(readFileSync(path, 'utf8')) as Registry\n",
    "  return applyDistributionOverrides(JSON.parse(readFileSync(path, 'utf8')) as Registry)\n",
    "TypeScript snapshot policy",
)
replace_once(
    package_dir / "src/registry.ts",
    "    cache = { at: Date.now(), data }\n    return { registry: data, source: 'live' }\n",
    "    const overridden = applyDistributionOverrides(data)\n    cache = { at: Date.now(), data: overridden }\n    return { registry: overridden, source: 'live' }\n",
    "TypeScript live registry policy",
)

registry_js_policy = """
const overridesPath = fileURLToPath(new URL('../data/distribution-overrides.json', import.meta.url));
const distributionOverrides = JSON.parse(readFileSync(overridesPath, 'utf8'));
function normalizeSourceUrl(url) {
    return url.toLowerCase().replace(/\\/+$/, '');
}
/** Return the desktop distribution policy for one approved repository URL. */
export function distributionOverride(url) {
    const expected = normalizeSourceUrl(url);
    return Object.values(distributionOverrides).find(rule => rule.sourceUrls.some(candidate => normalizeSourceUrl(candidate) === expected));
}
function applyDistributionOverrides(registry) {
    return {
        ...registry,
        plugins: registry.plugins.map(plugin => {
            const rule = distributionOverride(plugin.url);
            return rule === undefined ? plugin : { ...plugin, npm: rule.npm, install: rule.install };
        }),
    };
}
"""
replace_once(
    package_dir / "lib/registry.js",
    "const TTL_MS = 60 * 60 * 1000;\nlet cache = null;\n",
    "const TTL_MS = 60 * 60 * 1000;\n" + registry_js_policy + "let cache = null;\n",
    "runtime registry policy insertion",
)
replace_once(
    package_dir / "lib/registry.js",
    "    return JSON.parse(readFileSync(path, 'utf8'));\n",
    "    return applyDistributionOverrides(JSON.parse(readFileSync(path, 'utf8')));\n",
    "runtime snapshot policy",
)
replace_once(
    package_dir / "lib/registry.js",
    "        cache = { at: Date.now(), data };\n        return { registry: data, source: 'live' };\n",
    "        const overridden = applyDistributionOverrides(data);\n        cache = { at: Date.now(), data: overridden };\n        return { registry: overridden, source: 'live' };\n",
    "runtime live registry policy",
)

replace_once(
    package_dir / "lib/types/registry.d.ts",
    """export interface Registry {
    updated: string;
    count: number;
    categories: Record<string, Record<string, string>>;
    plugins: RegistryPlugin[];
}
""",
    """export interface Registry {
    updated: string;
    count: number;
    categories: Record<string, Record<string, string>>;
    plugins: RegistryPlugin[];
}
export interface DistributionOverride {
    sourceUrls: string[];
    npm: string;
    install: string;
    denyBuilds: string[];
}
/** Return the desktop distribution policy for one approved repository URL. */
export declare function distributionOverride(url: string): DistributionOverride | undefined;
""",
    "registry declarations",
)

routes_ts = package_dir / "src/routes.ts"
replace_once(
    routes_ts,
    "import { readFileSync } from 'node:fs'",
    "import { readFileSync, writeFileSync } from 'node:fs'",
    "TypeScript filesystem imports",
)
replace_once(
    routes_ts,
    "import type { IncomingMessage, ServerResponse } from 'node:http'",
    "import type { IncomingMessage, ServerResponse } from 'node:http'\nimport { join } from 'node:path'",
    "TypeScript path imports",
)
replace_once(
    routes_ts,
    "import { loadRegistry } from './registry.ts'",
    "import { distributionOverride, loadRegistry } from './registry.ts'",
    "TypeScript registry imports",
)
routes_js = package_dir / "lib/routes.js"
replace_once(
    routes_js,
    "import { readFileSync } from 'node:fs';",
    "import { readFileSync, writeFileSync } from 'node:fs';",
    "runtime filesystem imports",
)
replace_once(
    routes_js,
    "import { BOOT_ID, probePnpm, progress, provisionPnpm, runDshPlugin } from './dsh-cli.js';",
    "import { BOOT_ID, probePnpm, progress, provisionPnpm, runDshPlugin } from './dsh-cli.js';\nimport { join } from 'node:path';",
    "runtime path imports",
)
replace_once(
    routes_js,
    "import { loadRegistry } from './registry.js';",
    "import { distributionOverride, loadRegistry } from './registry.js';",
    "runtime registry imports",
)

workspace_ts = """
/** Preserve user choices while denying build scripts required by one distribution rule. */
function denyBuildScripts(profile: string, packageNames: readonly string[]): void {
  if (packageNames.length === 0) return
  const path = join(profileDir(profile), 'pnpm-workspace.yaml')
  const text = readFileSync(path, 'utf8')
  const lines = text.split('\\n')
  let section = lines.findIndex(line => line === 'allowBuilds:')
  if (section < 0) {
    while (lines.at(-1) === '') lines.pop()
    lines.push('', 'allowBuilds:')
    section = lines.length - 1
  }
  let end = section + 1
  while (end < lines.length && (lines[end] === '' || /^\\s/.test(lines[end]))) end++
  for (const name of packageNames) {
    const prefix = `  ${name}:`
    const relative = lines.slice(section + 1, end).findIndex(line => line.startsWith(prefix))
    if (relative < 0) {
      lines.splice(end, 0, `${prefix} false`)
      end++
      continue
    }
    const absolute = section + 1 + relative
    if (lines[absolute].includes('set this to true or false')) lines[absolute] = `${prefix} false`
  }
  const next = `${lines.join('\\n').replace(/\\n*$/, '')}\\n`
  if (next !== text) writeFileSync(path, next)
}
"""
workspace_js = """
/** Preserve user choices while denying build scripts required by one distribution rule. */
function denyBuildScripts(profile, packageNames) {
    if (packageNames.length === 0)
        return;
    const path = join(profileDir(profile), 'pnpm-workspace.yaml');
    const text = readFileSync(path, 'utf8');
    const lines = text.split('\\n');
    let section = lines.findIndex(line => line === 'allowBuilds:');
    if (section < 0) {
        while (lines.at(-1) === '')
            lines.pop();
        lines.push('', 'allowBuilds:');
        section = lines.length - 1;
    }
    let end = section + 1;
    while (end < lines.length && (lines[end] === '' || /^\\s/.test(lines[end])))
        end++;
    for (const name of packageNames) {
        const prefix = `  ${name}:`;
        const relative = lines.slice(section + 1, end).findIndex(line => line.startsWith(prefix));
        if (relative < 0) {
            lines.splice(end, 0, `${prefix} false`);
            end++;
            continue;
        }
        const absolute = section + 1 + relative;
        if (lines[absolute].includes('set this to true or false'))
            lines[absolute] = `${prefix} false`;
    }
    const next = `${lines.join('\\n').replace(/\\n*$/, '')}\\n`;
    if (next !== text)
        writeFileSync(path, next);
}
"""
replace_once(routes_ts, "const PROFILE_RE = /^[A-Za-z0-9_-]+$/\n", "const PROFILE_RE = /^[A-Za-z0-9_-]+$/\n" + workspace_ts, "TypeScript build policy helper")
replace_once(routes_js, "const PROFILE_RE = /^[A-Za-z0-9_-]+$/;\n", "const PROFILE_RE = /^[A-Za-z0-9_-]+$/;\n" + workspace_js, "runtime build policy helper")

install_guard_ts = """          if (target === null) {
            sendJson(response, 400, { error: 'unsupported source url' })
            return
          }
"""
replace_once(
    routes_ts,
    install_guard_ts,
    install_guard_ts + "          const override = distributionOverride(entry.url)\n          if (override !== undefined) denyBuildScripts(config.profile, override.denyBuilds)\n",
    "TypeScript install policy",
)
install_guard_js = """                    if (target === null) {
                        sendJson(response, 400, { error: 'unsupported source url' });
                        return;
                    }
"""
replace_once(
    routes_js,
    install_guard_js,
    install_guard_js + "                    const override = distributionOverride(entry.url);\n                    if (override !== undefined)\n                        denyBuildScripts(config.profile, override.denyBuilds);\n",
    "runtime install policy",
)

replace_once(
    routes_ts,
    "          const force = body.force === true\n",
    "          const force = body.force === true || name === 'dshmarket' || name === 'dsh-market'\n",
    "TypeScript market update policy",
)
replace_once(
    routes_js,
    "                    const force = body.force === true;\n",
    "                    const force = body.force === true || name === 'dshmarket' || name === 'dsh-market';\n",
    "runtime market update policy",
)
