#!/usr/bin/env python3
"""Check local documentation links, images, and JSON examples without network access."""

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
documents = sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").rglob("*.md"))
errors = []


def anchors(text):
    found = set()
    counts = {}
    for heading in re.findall(r"^#{1,6}\s+(.+)$", text, re.MULTILINE):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        number = counts.get(slug, 0)
        counts[slug] = number + 1
        found.add(slug if number == 0 else f"{slug}-{number}")
    return found


for document in documents:
    text = document.read_text()
    label = document.relative_to(ROOT)
    # Code samples may contain shell paths and patterns that are not Markdown links.
    prose = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
    links = re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", prose)
    links += re.findall(r'(?:src|srcset)="([^"]+)"', prose)
    for link in links:
        parts = urlsplit(link)
        if parts.scheme or parts.netloc:
            continue
        target = (document.parent / unquote(parts.path)).resolve() if parts.path else document
        if not target.is_relative_to(ROOT) or not target.exists():
            errors.append(f"{label}: missing local target {link}")
        elif parts.fragment and target.suffix == ".md":
            if unquote(parts.fragment) not in anchors(target.read_text()):
                errors.append(f"{label}: missing heading {link}")
    for index, block in enumerate(re.findall(r"```json\n(.*?)\n```", text, re.DOTALL), 1):
        try:
            json.loads(block)
        except ValueError as error:
            errors.append(f"{label}: invalid JSON example {index}: {error}")

for example in sorted((ROOT / "examples").glob("*.json")):
    try:
        json.loads(example.read_text())
    except ValueError as error:
        errors.append(f"{example.relative_to(ROOT)}: {error}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Documentation checked: {len(documents)} pages; local links, images, and JSON examples are valid.")
