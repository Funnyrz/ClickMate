#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"
build_directory="$repository_root/build/documentation"
mkdir -p "$build_directory"

if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' 'Usage: Scripts/generate_documentation_images.sh [--validate]' \
        'Generates native demo screenshots, removes private text, and validates both READMEs.' \
        '--validate checks the existing published images and documentation without recapturing.'
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--validate" ) ]]; then
    printf '%s\n' 'Unknown option. Use --help.' >&2
    exit 2
fi

xcrun swiftc Scripts/prepare_documentation_images.swift -o "$build_directory/prepare-images"
"$build_directory/prepare-images" --self-test --report "$build_directory/privacy-self-test.json"

if [[ "${1:-}" != "--validate" ]]; then
    raw_directory="$(mktemp -d "$build_directory/raw.XXXXXX")"
    capture_log="$raw_directory/capture.log"
    printf '%s\n' 'Capturing 12 English / Simplified Chinese scenes from native views…'
    if ! TEST_RUNNER_CLICKMATE_DOCUMENTATION_OUTPUT="$raw_directory" \
        xcodebuild test -project ClickMate.xcodeproj -scheme ClickMate \
        -configuration Debug -destination 'platform=macOS' \
        -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
        -only-testing:ClickMateCoreTests/DocumentationScreenshotTests \
        -only-testing:ClickMateCoreTests/FinderMenuDocumentationTests \
        -resultBundlePath "$raw_directory/Capture.xcresult" -quiet > "$capture_log" 2>&1; then
        tail -60 "$capture_log" >&2
        exit 1
    fi
    "$build_directory/prepare-images" --input "$raw_directory" --output img \
        --report "$build_directory/privacy-report.json"
fi

"$build_directory/prepare-images" --validate --output img \
    --report "$build_directory/privacy-validation.json"
python3 Scripts/validate_readme.py
printf '%s\n' 'Documentation images and README checks passed. Review all 24 images before committing.'
