#!/usr/bin/env python3
"""Validate the plugin repo: manifests, translations, catalog sync, thumbnails.

Run from the repository root: python3 .github/scripts/validate_plugins.py
Exits non-zero and prints every problem if anything fails.
"""
import json
import os
import re
import struct
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENTRY_KINDS = {"widget", "panel", "service", "desktop_widget", "shortcut", "launcher_provider", "layer"}
REQUIRED_MANIFEST = ("id", "name", "version", "plugin_api")
THUMBNAIL_MAX_BYTES = 512 * 1024

errors = []


def err(msg):
    errors.append(msg)


def nested_get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def plugin_dirs():
    return sorted(
        d for d in os.listdir(ROOT)
        if os.path.isdir(os.path.join(ROOT, d)) and os.path.exists(os.path.join(ROOT, d, "plugin.toml"))
    )


def collect_keys(obj, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.endswith("_key") and isinstance(v, str):
                out.append(v)
            collect_keys(v, out)
    elif isinstance(obj, list):
        for e in obj:
            collect_keys(e, out)


def webp_size(path):
    with open(path, "rb") as f:
        head = f.read(30)
    if len(head) < 30 or head[:4] != b"RIFF" or head[8:12] != b"WEBP":
        return None
    if head[12:16] == b"VP8X":
        return int.from_bytes(head[24:27], "little") + 1, int.from_bytes(head[27:30], "little") + 1
    if head[12:16] == b"VP8L":
        bits = int.from_bytes(head[21:26], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if head[12:16] == b"VP8 ":
        return struct.unpack("<H", head[26:28])[0] & 0x3FFF, struct.unpack("<H", head[28:30])[0] & 0x3FFF
    return None


def main():
    dirs = plugin_dirs()
    if not dirs:
        err("no plugin directories with plugin.toml found")

    manifests = {}
    for d in dirs:
        pdir = os.path.join(ROOT, d)
        toml_path = os.path.join(pdir, "plugin.toml")
        try:
            with open(toml_path, "rb") as f:
                m = tomllib.load(f)
        except Exception as e:
            err(f"{d}/plugin.toml: invalid TOML: {e}")
            continue
        manifests[d] = m

        for field in REQUIRED_MANIFEST:
            if field not in m:
                err(f"{d}/plugin.toml: missing required field '{field}'")
        if "version" in m and not re.fullmatch(r"\d+\.\d+\.\d+", str(m["version"])):
            err(f"{d}/plugin.toml: version '{m['version']}' must be MAJOR.MINOR.PATCH")
        if "plugin_api" in m and not (isinstance(m["plugin_api"], int) and 3 <= m["plugin_api"] <= 53):
            err(f"{d}/plugin.toml: plugin_api must be an integer in 3..53, got {m.get('plugin_api')!r}")
        pid = m.get("id", "?")
        if pid != f"neoscaler/{d}":
            err(f"{d}/plugin.toml: id '{pid}' should be 'neoscaler/{d}'")

        for kind in ENTRY_KINDS:
            for e in m.get(kind, []) or []:
                entry_file = os.path.join(pdir, e.get("entry", ""))
                if not e.get("entry") or not os.path.exists(entry_file):
                    err(f"{d}/plugin.toml: {kind} entry '{e.get('id')}' points to missing file '{e.get('entry')}'")

        for req in ("README.md", os.path.join("translations", "en.json")):
            if not os.path.exists(os.path.join(pdir, req)):
                err(f"{d}: missing required file {req}")

        tdir = os.path.join(pdir, "translations")
        trans = {}
        if os.path.isdir(tdir):
            for tf in sorted(os.listdir(tdir)):
                if not tf.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(tdir, tf)) as f:
                        trans[tf] = json.load(f)
                except Exception as e:
                    err(f"{d}/translations/{tf}: invalid JSON: {e}")
        en = trans.get("en.json")
        if en is not None:
            keys = []
            collect_keys(m, keys)
            for k in keys:
                if nested_get(en, k) is None:
                    err(f"{d}/plugin.toml: key '{k}' has no entry in translations/en.json")
            for f in glob_luau(pdir):
                src = open(f).read()
                for match in re.findall(r'noctalia\.tr\("([^"]+)"', src):
                    if match.endswith("."):
                        # dynamic prefix like noctalia.tr("ui.level." .. level): prefix must be a table
                        if not isinstance(nested_get(en, match[:-1]), dict):
                            err(f"{d}: noctalia.tr(\"{match}\" .. ...) in {os.path.basename(f)} has no table at '{match[:-1]}' in translations/en.json")
                        continue
                    if nested_get(en, match) is None:
                        err(f"{d}: noctalia.tr(\"{match}\") in {os.path.basename(f)} missing in translations/en.json")

        thumb = os.path.join(pdir, "thumbnail.webp")
        if os.path.exists(thumb):
            size = os.path.getsize(thumb)
            dims = webp_size(thumb)
            if dims is None:
                err(f"{d}/thumbnail.webp: not a valid WebP file")
            else:
                w, h = dims
                if w * 9 != h * 16:
                    err(f"{d}/thumbnail.webp: {w}x{h} is not 16:9")
            if size > THUMBNAIL_MAX_BYTES:
                err(f"{d}/thumbnail.webp: {size} bytes exceeds {THUMBNAIL_MAX_BYTES}")

    # catalog sync
    catalog_path = os.path.join(ROOT, "catalog.toml")
    try:
        with open(catalog_path, "rb") as f:
            catalog = tomllib.load(f)
    except Exception as e:
        err(f"catalog.toml: invalid TOML: {e}")
        catalog = {}
    entries = catalog.get("plugin", [])
    cat_ids = {p.get("id", "?").split("/")[-1] for p in entries}
    if cat_ids != set(dirs):
        err(f"catalog.toml plugins {sorted(cat_ids)} do not match plugin dirs {dirs}")
    for p in entries:
        d = p.get("id", "?").split("/")[-1]
        m = manifests.get(d)
        if not m:
            continue
        for field in ("name", "version", "author", "license", "icon", "description", "deprecated", "plugin_api", "tags", "dependencies"):
            if field in m and p.get(field) != m[field]:
                err(f"catalog.toml: '{d}' field '{field}' = {p.get(field)!r} != plugin.toml {m[field]!r}")

    # root README links every plugin
    readme = os.path.join(ROOT, "README.md")
    if os.path.exists(readme):
        text = open(readme).read()
        for d in dirs:
            if f"]({d}/)" not in text:
                err(f"README.md: no table row linking to ({d}/)")

    if errors:
        print(f"{len(errors)} problem(s):")
        for e in errors:
            print(" -", e)
        sys.exit(1)
    print(f"OK: {len(dirs)} plugin(s) valid: {', '.join(dirs)}")


def glob_luau(pdir):
    out = []
    for base, _dirs, files in os.walk(pdir):
        for fn in files:
            if fn.endswith(".luau"):
                out.append(os.path.join(base, fn))
    return out


if __name__ == "__main__":
    main()
