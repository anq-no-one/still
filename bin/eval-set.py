#!/usr/bin/env python3
"""Downloads the locked word-error-rate set into ~/Library/Caches/Still-Eval.

Each language takes the same fixed rows of a public test split, converted to 16 kHz mono WAV.
Usage: bin/eval-set.py [rows-per-language]
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

ROWS = int(sys.argv[1]) if len(sys.argv) > 1 else 20
ROOT = os.path.expanduser("~/Library/Caches/Still-Eval")
SOURCES = {
    "en": ("openslr/librispeech_asr", "clean", "test", "text"),
    "pl": ("facebook/multilingual_librispeech", "polish", "test", "transcript"),
    "de": ("facebook/multilingual_librispeech", "german", "test", "transcript"),
    "fr": ("facebook/multilingual_librispeech", "french", "test", "transcript"),
    "es": ("facebook/multilingual_librispeech", "spanish", "test", "transcript"),
    "it": ("facebook/multilingual_librispeech", "italian", "test", "transcript"),
    "ru": ("bond005/sberdevices_golos_10h_crowd", "default", "test", "transcription"),
}


def rows(dataset, config, split, count):
    query = urllib.parse.urlencode(
        {"dataset": dataset, "config": config, "split": split, "offset": 0, "length": count}
    )
    with urllib.request.urlopen(f"https://datasets-server.huggingface.co/rows?{query}") as response:
        return [item["row"] for item in json.load(response)["rows"]]


def main():
    manifest = {}
    for language, (dataset, config, split, field) in SOURCES.items():
        directory = os.path.join(ROOT, language)
        os.makedirs(directory, exist_ok=True)
        items = []
        for index, row in enumerate(rows(dataset, config, split, ROWS)):
            source = row["audio"][0]["src"]
            wav = os.path.join(directory, f"{index:03d}.wav")
            if not os.path.exists(wav):
                raw = wav + ".src"
                urllib.request.urlretrieve(source, raw)
                subprocess.run(
                    ["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ac", "1", "-ar", "16000", wav],
                    check=True,
                )
                os.remove(raw)
            items.append({"audio": wav, "reference": row[field]})
        manifest[language] = items
        print(f"{language}: {len(items)}")
    with open(os.path.join(ROOT, "manifest.json"), "w") as file:
        json.dump(manifest, file, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
