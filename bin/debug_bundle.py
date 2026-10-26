#!/usr/bin/env python3
"""Unpack a Still debug bundle or bug report, symbolicate its stacks, print its summary.

    bin/debug-bundle.sh <bundle.zip | unpacked folder>
    bin/bug-reports.sh [list | open <name|latest> | done <name|all>]
"""

import glob
import json
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UNPACKED = os.path.join(ROOT, "Artifacts", "DebugBundles")
INBOX = os.path.expanduser("~/Downloads/Still Bug Reports")
PROCESSED = os.path.join(ROOT, "Artifacts", "BugReports", "processed.txt")
SYMBOL_SOURCES = [
    os.path.expanduser("~/Library/Developer/Xcode/Archives/Still-dSYMs"),
    os.path.expanduser("~/Library/Developer/Xcode/Archives"),
    os.path.expanduser(os.environ.get("STILL_DERIVED_DATA", "~/Library/Developer/Xcode/DerivedData/Still-shared") + "/Build/Products"),
]
ADDRESS = re.compile(r"0x[0-9a-f]+")


def unpack(source):
    if os.path.isdir(source):
        return find_root(source)
    name = os.path.splitext(os.path.basename(source))[0]
    target = os.path.join(UNPACKED, name)
    if not os.path.isdir(target):
        os.makedirs(target)
        with zipfile.ZipFile(source) as archive:
            for member in archive.namelist():
                path = os.path.realpath(os.path.join(target, member))
                if not path.startswith(os.path.realpath(target) + os.sep):
                    sys.exit(f"refusing {member}: it would land outside {target}")
            archive.extractall(target)
    return find_root(target)


def find_root(folder):
    for current, _, files in os.walk(folder):
        if "README.txt" in files and "device.json" in files:
            return current
    sys.exit(f"no Still bundle inside {folder}")


def load_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def binary_uuids():
    """Every Still binary or dSYM on this Mac, by Mach-O UUID."""
    candidates = []
    for source in SYMBOL_SOURCES:
        candidates += glob.glob(os.path.join(source, "**", "*.dSYM"), recursive=True)
        candidates += glob.glob(os.path.join(source, "**", "Still.app", "Contents", "MacOS", "Still*"), recursive=True)
        candidates += glob.glob(os.path.join(source, "**", "Still.app", "Still*"), recursive=True)
    found = {}
    for path in candidates:
        try:
            output = subprocess.run(["dwarfdump", "--uuid", path], capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0] == "UUID:":
                found.setdefault(parts[1].upper(), parts[-1])
    return found


def image_for(address, images):
    for image in images:
        if image["loadAddress"] <= address < image["loadAddress"] + max(image.get("textSize", 0), 1):
            return image
    return None


class Symbolicator:
    def __init__(self):
        self._uuids = None

    @property
    def uuids(self):
        if self._uuids is None:
            self._uuids = binary_uuids()
        return self._uuids

    def lines(self, addresses, images):
        names = {}
        by_image = {}
        for address in addresses:
            image = image_for(address, images)
            if image and image.get("uuid", "").upper() in self.uuids:
                by_image.setdefault(image["uuid"].upper(), (image, []))[1].append(address)
        for uuid, (image, wanted) in by_image.items():
            command = ["atos", "-o", self.uuids[uuid], "-arch", "arm64", "-l", hex(image["loadAddress"])] + [hex(a) for a in wanted]
            try:
                output = subprocess.run(command, capture_output=True, text=True, timeout=60).stdout.splitlines()
            except (OSError, subprocess.TimeoutExpired):
                output = []
            names.update(zip(wanted, output))
        result = []
        for index, address in enumerate(addresses):
            image = image_for(address, images)
            owner = image["name"] if image else "???"
            offset = f"+{address - image['loadAddress']:#x}" if image else ""
            result.append(f"{index:3d} {owner:<28} {address:#x} {names.get(address, offset)}")
        return result


def symbolicate_threads(text, images, symbols):
    out = []
    for line in text.splitlines():
        match = ADDRESS.search(line)
        if match and re.match(r"^\s*\d+ ", line):
            out.append(symbols.lines([int(match.group(0), 16)], images)[0])
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def symbolicate(root):
    images = load_json(os.path.join(root, "images.json"), [])
    symbols = Symbolicator()
    folder = os.path.join(root, "symbolicated")
    os.makedirs(folder, exist_ok=True)
    written = []

    def write(name, text):
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(text)
        written.append(os.path.join("symbolicated", name))

    threads = os.path.join(root, "threads.txt")
    if os.path.exists(threads) and images:
        write("threads.txt", symbolicate_threads(open(threads).read(), images, symbols))

    hangs = []
    devlog = os.path.join(root, "devlog.jsonl")
    if os.path.exists(devlog):
        with open(devlog) as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if record.get("kind") == "hang" and (record.get("fields") or {}).get("stack"):
                    hangs.append(record)
    if hangs and images:
        hangs.sort(key=lambda record: record.get("ms") or 0, reverse=True)
        text = []
        for record in hangs[:20]:
            fields = record["fields"]
            text.append(f"## {record['at']} {record.get('ms', 0):.0f} ms {fields.get('severity', '')} blockedBy={fields.get('blockedBy', '-')} samples={fields.get('stackSamples', '?')}")
            text += symbols.lines([int(a, 16) for a in fields["stack"].split()], images)
            text.append("")
        write("hangs.txt", "\n".join(text))
        if any(image.get("name", "").startswith("Still") for image in images) and not any(
            image.get("uuid", "").upper() in symbols.uuids for image in images if image.get("name", "").startswith("Still")
        ):
            print("note: no dSYM or binary on this Mac matches this build's UUID, so Still frames stay as offsets", file=sys.stderr)

    crashes = []
    for crash_json in sorted(glob.glob(os.path.join(root, "crashes", "*", "crash.json"))):
        crash_images = load_json(os.path.join(os.path.dirname(crash_json), "images.json"), [])
        for report in load_json(crash_json, []):
            title = report.get("name") or f"signal {report.get('signal')}"
            crashes.append(f"## {os.path.basename(os.path.dirname(crash_json))} {title} {report.get('reason') or ''}")
            addresses = (report.get("backtrace") or {}).get("addresses") or []
            crashes += symbols.lines(addresses, crash_images) if crash_images else [hex(a) for a in addresses]
            crashes.append("")
    if crashes:
        write("crashes.txt", "\n".join(crashes))

    for marker_threads in sorted(glob.glob(os.path.join(root, "markers", "*", "threads.txt"))):
        name = os.path.basename(os.path.dirname(marker_threads))
        write(f"marker-{name}-threads.txt", symbolicate_threads(open(marker_threads).read(), images, symbols))
    return written


def show(source):
    root = unpack(source)
    written = symbolicate(root)
    print(f"bundle: {root}")
    for path in written:
        print(f"  {path}")
    attachments = sorted(glob.glob(os.path.join(root, "attachments", "*")))
    for path in attachments:
        print(f"attachment: {path}")
    summary = os.path.join(root, "summary.md")
    if os.path.exists(summary):
        print()
        print(open(summary).read())
    return root


def processed():
    try:
        with open(PROCESSED) as handle:
            return {line.strip() for line in handle if line.strip()}
    except OSError:
        return set()


def reports():
    return sorted(glob.glob(os.path.join(INBOX, "*.zip")), key=os.path.getmtime)


def mark_done(names):
    os.makedirs(os.path.dirname(PROCESSED), exist_ok=True)
    with open(PROCESSED, "a") as handle:
        for name in names:
            handle.write(name + "\n")


def bug_reports(arguments):
    command = arguments[0] if arguments else "list"
    done = processed()
    waiting = [path for path in reports() if os.path.basename(path) not in done]
    if command == "list":
        if not waiting:
            print(f"no new bug reports in {INBOX}")
        for path in waiting:
            print(os.path.basename(path))
    elif command == "open":
        name = arguments[1] if len(arguments) > 1 else "latest"
        matches = waiting[-1:] if name == "latest" else [path for path in reports() if os.path.basename(path).startswith(name)]
        if not matches:
            sys.exit(f"no bug report named {name}")
        show(matches[0])
    elif command == "done":
        name = arguments[1] if len(arguments) > 1 else ""
        names = [os.path.basename(path) for path in waiting] if name == "all" else [os.path.basename(path) for path in waiting if os.path.basename(path).startswith(name)]
        if not names:
            sys.exit(f"no waiting bug report named {name}")
        mark_done(names)
        print("\n".join(f"done: {name}" for name in names))
    else:
        sys.exit(__doc__)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "reports":
        bug_reports(sys.argv[2:])
    elif len(sys.argv) == 2:
        show(sys.argv[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
