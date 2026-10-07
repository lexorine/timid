#!/usr/bin/env python3
"""Generate timid's debloat policy from the upstream chrome-debloat manifest.

The upstream project (github.com/NVFP4/chrome-debloat, formerly
yashgorana/chrome-debloat) was rewritten as a Rust TUI and no longer ships
pre-generated per-browser JSON. Its source of truth is `src/manifest.yaml`,
which this script resolves into the same `balanced` preset the TUI applies,
mirroring `Manifest::balanced_preset` in upstream `src/manifest.rs`.

Output is deterministic: upstream `PolicySet` is a BTreeMap, so keys are
emitted sorted.

Usage:
    gen-debloat-policy.py [--browser brave] [--ref main] [-o modules/brave.json]

With no -o the JSON is written to stdout. Ref can be a branch, tag or commit.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

MANIFEST_URL = "https://raw.githubusercontent.com/NVFP4/chrome-debloat/{ref}/src/manifest.yaml"
EXTENSION_INSTALL_FORCELIST = "ExtensionInstallForcelist"


def load_manifest(ref: str) -> dict:
    url = MANIFEST_URL.format(ref=ref)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            text = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"error: fetching {url} failed: HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise SystemExit(f"error: fetching {url} failed: {error.reason}") from error

    try:
        import yaml
    except ModuleNotFoundError:  # pragma: no cover
        raise SystemExit("error: PyYAML is required (pip install pyyaml)") from None

    return yaml.safe_load(text)


def balanced_preset(manifest: dict, browser: str) -> dict:
    """Resolve the `balanced` preset for one browser.

    Mirrors upstream balanced_preset(): walk the preset's policy groups in
    order (skipping groups the browser is not a target of), then the preset's
    extensions (again skipping non-targets), collecting their extension ids
    into ExtensionInstallForcelist. Later inserts overwrite earlier ones.
    """
    presets = manifest.get("presets") or {}
    preset = (presets.get(browser) or {}).get("balanced")
    if not preset:
        raise SystemExit(f"error: no 'balanced' preset for browser {browser!r}")

    groups = manifest.get("policyGroups") or {}
    extensions = manifest.get("extensions") or {}

    policies: dict = {}

    for group_id in preset.get("policyGroups") or []:
        group = groups.get(group_id)
        if group is None or browser not in (group.get("targets") or []):
            continue
        policies.update(group.get("settings") or {})

    extension_ids: list = []
    for extension_id in preset.get("extensions") or []:
        extension = extensions.get(extension_id)
        if extension is None or browser not in (extension.get("targets") or []):
            continue
        extension_ids.append(extension["id"])
        policies.update(extension.get("settings") or {})

    if extension_ids:
        policies[EXTENSION_INSTALL_FORCELIST] = extension_ids

    # Upstream PolicySet is a BTreeMap, i.e. keys come out sorted.
    return {key: policies[key] for key in sorted(policies)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", default="brave", help="browser target (default: brave)")
    parser.add_argument("--ref", default="main", help="upstream git ref (default: main)")
    parser.add_argument("-o", "--output", help="write JSON here instead of stdout")
    args = parser.parse_args()

    policies = balanced_preset(load_manifest(args.ref), args.browser)
    rendered = json.dumps(policies, indent=2, sort_keys=True) + "\n"

    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        print(f"wrote {len(policies)} policies for {args.browser} to {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())