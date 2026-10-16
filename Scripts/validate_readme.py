#!/usr/bin/env python3
"""Check bilingual README assets and Markdown structure without dependencies."""
from pathlib import Path
import json
import re
import struct

ROOT = Path(__file__).resolve().parent.parent
SCENES = [
    "finder-menu", "quick-features", "screenshot-annotation", "scrolling-capture",
    "archive-editor", "file-tasks", "settings-menus", "settings-layout",
    "template-editor", "settings-apps", "permissions", "settings-data",
]


def check():
    documents = []
    for filename, language in [("README.md", "en"), ("README.zh-CN.md", "zh-CN")]:
        text = (ROOT / filename).read_text()
        images = re.findall(r"!\[([^\]]*)\]\(([^)]+)\)", text)
        expected = [f"img/product-overview-{language}.png"] + [
            f"img/clickmate-{scene}-{language}.png" for scene in SCENES
        ]
        assert [target for _, target in images] == expected, f"{filename}: image order / language mismatch"
        assert all(label.strip() for label, _ in images), f"{filename}: missing image descriptions"
        assert text.count("<details>") == text.count("</details>") == 9, f"{filename}: disclosure mismatch"
        assert text.count("<summary>") == text.count("</summary>") == 9, f"{filename}: summary mismatch"
        assert "Scripts/release_github.sh" not in text, f"{filename}: private release script dependency"
        assert "/Users/" not in text, f"{filename}: private account path"
        in_code = False
        heading_levels = []
        for line in text.splitlines():
            if line.startswith("```"):
                in_code = not in_code
            elif not in_code and (match := re.match(r"^(#{1,6}) ", line)):
                heading_levels.append(len(match.group(1)))
        assert not in_code, f"{filename}: unclosed code fence"
        for target in re.findall(r"\]\(([^)]+)\)", text):
            if not target.startswith(("https://", "http://", "#")):
                assert (ROOT / target.split("#", 1)[0]).is_file(), f"{filename}: broken local link {target}"
        for _, image in images:
            data = (ROOT / image).read_bytes()
            assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{image}: invalid PNG"
            width, height = struct.unpack(">II", data[16:24])
            assert 320 <= width <= 2600 and 200 <= height <= 4000, f"{image}: unexpected dimensions"
        documents.append({"file": filename, "images": len(images), "heading_levels": heading_levels, "disclosures": 9})
    assert documents[0]["heading_levels"] == documents[1]["heading_levels"], "README heading structure mismatch"
    expected_images = len(documents) * (len(SCENES) + 1)
    report = {"passed": True, "documents": documents, "expected_images": expected_images}
    destination = ROOT / "build/documentation/readme-validation.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Both READMEs passed: {expected_images} matching images, local links, headings, disclosures, and code fences.")


if __name__ == "__main__":
    check()
