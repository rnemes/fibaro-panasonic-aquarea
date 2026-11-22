#!/usr/bin/env python3
"""Build Fibaro HC3 QuickApp files (.fqa) from the sources in this repo.

Each quickapps/<id>.json manifest describes one QuickApp: its name, device type,
UI layout, uiCallbacks and variables, plus the Lua files it is made of. The
build reads the Lua sources, puts them into the manifest and writes
dist/<output>_<version>.fqa.

The version comes from the "-- version X.Y.Z" line in the main Lua file. When a
version is given (--version, or a v* tag in GitHub Actions), the build fails if
it does not match, so a release can never ship a file with the wrong version.

The build also fails if a secret variable (Username, password, authCode, or
anything in the manifest's "secretVariables") has a value, so real credentials
can't end up in a release.

Usage:
    python3 tools/build.py                  # build every manifest into dist/
    python3 tools/build.py quickapps/aquarea.json
    python3 tools/build.py --version 2.6.1  # also check the version
    python3 tools/build.py --check          # validate only, write nothing
"""

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SECRETS = ["Username", "password", "authCode"]
VERSION_RE = re.compile(r"^\s*--\s*version\s+(\d+\.\d+\.\d+)\s*$", re.MULTILINE | re.IGNORECASE)

# Manifest keys that are build settings, not part of the .fqa itself.
BUILD_KEYS = {"output", "files", "secretVariables", "$comment"}


class BuildError(Exception):
    pass


def secret_names(manifest):
    return {n.lower() for n in DEFAULT_SECRETS + manifest.get("secretVariables", [])}


def check_secrets(manifest, where):
    secrets = secret_names(manifest)
    variables = manifest.get("initialProperties", {}).get("quickAppVariables", [])
    leaked = [v["name"] for v in variables if v.get("name", "").lower() in secrets and str(v.get("value", "")) != ""]
    if leaked:
        raise BuildError(f"{where}: secret variable(s) must be empty in the repo: {', '.join(leaked)}")


def read_version(lua_source, where):
    match = VERSION_RE.search(lua_source)
    if not match:
        raise BuildError(f"{where}: no '-- version X.Y.Z' line found in the main Lua file")
    return match.group(1)


def build_one(manifest_path, expected_version=None):
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    where = os.path.relpath(manifest_path, ROOT)

    for key in ("name", "type", "files", "output"):
        if key not in manifest:
            raise BuildError(f"{where}: missing '{key}'")
    check_secrets(manifest, where)

    files = []
    version = None
    mains = [entry for entry in manifest["files"] if entry.get("isMain")]
    if len(mains) != 1:
        raise BuildError(f"{where}: exactly one file must have \"isMain\": true")
    for entry in manifest["files"]:
        src = os.path.join(ROOT, entry["source"])
        if not os.path.isfile(src):
            raise BuildError(f"{where}: source file not found: {entry['source']}")
        with open(src, encoding="utf-8", newline="") as f:
            content = f.read()
        if entry.get("isMain"):
            version = read_version(content, entry["source"])
        files.append({
            "name": entry["name"],
            "isMain": bool(entry.get("isMain", False)),
            "isOpen": bool(entry.get("isOpen", entry.get("isMain", False))),
            "content": content,
        })

    if expected_version and expected_version != version:
        raise BuildError(f"{where}: requested version {expected_version}, but the main Lua file says {version}")

    fqa = {k: v for k, v in manifest.items() if k not in BUILD_KEYS}
    fqa.setdefault("apiVersion", "1.2")
    fqa.setdefault("initialProperties", {})
    fqa["files"] = files
    return fqa, f"{manifest['output']}_{version}.fqa", version


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifests", nargs="*", help="manifest files (default: quickapps/*.json)")
    parser.add_argument("--version", help="expected version, e.g. 2.6.1 or v2.6.1")
    parser.add_argument("--out", default=os.path.join(ROOT, "dist"), help="output folder (default: dist/)")
    parser.add_argument("--check", action="store_true", help="validate only, do not write files")
    args = parser.parse_args()

    manifests = args.manifests or sorted(
        os.path.join(ROOT, "quickapps", n) for n in os.listdir(os.path.join(ROOT, "quickapps")) if n.endswith(".json")
    )
    if not manifests:
        print("No manifests found in quickapps/", file=sys.stderr)
        return 1
    expected = args.version[1:] if args.version and args.version.startswith("v") else args.version

    try:
        built = [build_one(m, expected) for m in manifests]
    except (BuildError, json.JSONDecodeError, KeyError) as e:
        print(f"Build failed: {e}", file=sys.stderr)
        return 1

    if args.check:
        for _, filename, _ in built:
            print(f"ok    {filename}")
        return 0
    os.makedirs(args.out, exist_ok=True)
    for fqa, filename, _ in built:
        path = os.path.join(args.out, filename)
        with open(path, "w", encoding="utf-8", newline="") as f:
            json.dump(fqa, f)  # ASCII-escaped, like HC3 exports
        print(f"built {os.path.relpath(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
