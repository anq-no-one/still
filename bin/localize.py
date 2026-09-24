#!/usr/bin/env python3
"""Keeps Localizable.xcstrings in step with the code and merges translations.

  bin/localize.py sync                  add every string the last build extracted, drop the ones no code uses
  bin/localize.py missing <lang> <out>  write the keys <lang> still lacks as a JSON object of key -> ""
  bin/localize.py apply <lang> <in>     merge a JSON object of key -> translation into the catalog
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Still/Supporting/Localizable.xcstrings")
DERIVED = os.environ.get(
    "STILL_DERIVED_DATA", os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Still-shared")
)
LANGUAGES = ["de", "es", "fr", "it", "nl", "pl", "pt-PT", "ru", "sv", "uk"]


def load():
    with open(CATALOG) as file:
        return json.load(file)


def save(catalog):
    with open(CATALOG, "w") as file:
        json.dump(catalog, file, ensure_ascii=False, indent=2, sort_keys=True)
        file.write("\n")


def extracted_keys():
    keys = {}
    pattern = os.path.join(DERIVED, "Build/Intermediates.noindex/Still.build/*/Still-*.build/Objects-normal/*/*.stringsdata")
    for path in glob.glob(pattern):
        with open(path) as file:
            data = json.load(file)
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.setdefault(entry["key"], entry.get("comment", ""))
    return keys


def sync():
    catalog = load()
    catalog.setdefault("sourceLanguage", "en")
    catalog.setdefault("version", "1.0")
    strings = catalog.setdefault("strings", {})
    keys = extracted_keys()
    if not keys:
        sys.exit("No extracted strings found. Build the app first (bin/check.sh --skip-e2e).")
    for key in list(strings):
        if key not in keys:
            del strings[key]
    for key, comment in keys.items():
        entry = strings.setdefault(key, {})
        if comment:
            entry["comment"] = comment
    save(catalog)
    print(f"{len(strings)} strings")


def missing(language, output):
    strings = load()["strings"]
    lacking = {
        key: ""
        for key, entry in strings.items()
        if key.strip() and language not in entry.get("localizations", {})
    }
    with open(output, "w") as file:
        json.dump(lacking, file, ensure_ascii=False, indent=2)
    print(f"{len(lacking)} missing for {language}")


def apply(language, source):
    catalog = load()
    strings = catalog["strings"]
    with open(source) as file:
        translations = json.load(file)
    applied = 0
    for key, value in translations.items():
        if key in strings and isinstance(value, str) and value.strip():
            strings[key].setdefault("localizations", {})[language] = {
                "stringUnit": {"state": "translated", "value": value}
            }
            applied += 1
    save(catalog)
    print(f"{applied} applied for {language}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "sync":
        sync()
    elif command == "missing" and len(sys.argv) == 4:
        missing(sys.argv[2], sys.argv[3])
    elif command == "apply" and len(sys.argv) == 4:
        apply(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
