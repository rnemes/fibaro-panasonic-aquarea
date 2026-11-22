#!/usr/bin/env python3
"""Split a QuickApp exported from the HC3 (.fqa) back into sources.

Writes each Lua file of the QuickApp to its source file and the rest (name,
type, UI layout, uiCallbacks, variables) to a manifest in quickapps/.

Variables:
  * Secret variables (Username, password, authCode, and anything in the
    manifest's "secretVariables") are always written empty.
  * A variable that is already in the manifest keeps its committed value, so
    values that only make sense on your HC3 (deviceName, loginUrl, ...) don't
    drift into git. Pass --take-values to use the exported values instead.
  * A new variable gets the exported value (empty if it is a secret).

Usage:
    python3 tools/unpack.py ~/Downloads/Panasonic_Aquarea.fqa --manifest quickapps/aquarea.json
    python3 tools/unpack.py export.fqa                # new manifest named after the QuickApp

Check the result with "git diff" before committing.
"""

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SECRETS = ["Username", "password", "authCode"]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.strip().lower()).strip("-") or "quickapp"


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("fqa", help="the .fqa file exported from the HC3")
    parser.add_argument("--manifest", help="manifest to update (default: quickapps/<name>.json)")
    parser.add_argument("--take-values", action="store_true",
                        help="use the exported values of existing (non-secret) variables")
    args = parser.parse_args()

    with open(args.fqa, encoding="utf-8") as f:
        fqa = json.load(f)

    manifest_path = os.path.abspath(args.manifest) if args.manifest else \
        os.path.join(ROOT, "quickapps", slug(fqa.get("name", "")) + ".json")
    old = {}
    if os.path.isfile(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            old = json.load(f)

    secrets = {n.lower() for n in DEFAULT_SECRETS + old.get("secretVariables", [])}

    # Lua files: keep the existing name -> source mapping, new files go to src/.
    old_sources = {entry["name"]: entry for entry in old.get("files", [])}
    files = []
    for item in fqa.get("files", []):
        prev = old_sources.get(item["name"])
        source = prev["source"] if prev else ("src/main.lua" if item["name"] == "main" else f"src/{item['name']}.lua")
        path = os.path.join(ROOT, source)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(item.get("content", ""))
        print(f"wrote {source}")
        files.append({"name": item["name"], "source": source, "isMain": bool(item.get("isMain")),
                      "isOpen": bool(item.get("isOpen"))})
    for name in old_sources:
        if name not in {e["name"] for e in files}:
            print(f"note  file '{name}' is no longer in the QuickApp; {old_sources[name]['source']} was left in place")

    # Variables: secrets blank, committed values kept unless --take-values.
    props = dict(fqa.get("initialProperties", {}))
    old_values = {v["name"]: v.get("value", "")
                  for v in old.get("initialProperties", {}).get("quickAppVariables", [])}
    variables = []
    for var in props.get("quickAppVariables", []):
        var = dict(var)
        if var.get("name", "").lower() in secrets:
            if str(var.get("value", "")) != "":
                print(f"blank {var['name']} (secret)")
            var["value"] = ""
        elif var["name"] in old_values and not args.take_values:
            var["value"] = old_values[var["name"]]
        elif var["name"] not in old_values:
            print(f"new   variable {var['name']} = {var.get('value', '')!r}")
        variables.append(var)
    if "quickAppVariables" in props:
        props["quickAppVariables"] = variables

    manifest = {}
    if "$comment" in old:
        manifest["$comment"] = old["$comment"]
    manifest["name"] = fqa.get("name", old.get("name", ""))
    manifest["output"] = old.get("output") or re.sub(r"[^A-Za-z0-9]+", "_", manifest["name"].strip()).strip("_")
    manifest["type"] = fqa.get("type", old.get("type"))
    manifest["apiVersion"] = fqa.get("apiVersion", old.get("apiVersion", "1.2"))
    if "secretVariables" in old:
        manifest["secretVariables"] = old["secretVariables"]
    manifest["files"] = files
    manifest["initialProperties"] = props

    os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {rel(manifest_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
