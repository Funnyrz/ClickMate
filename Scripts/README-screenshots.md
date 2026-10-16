# README screenshots

The README images show the real native views with dedicated demonstration data. They are not AI-generated mockups. English and Simplified Chinese use the same 12 scenes and image order. Captures use a light appearance and should be reviewed at both full size and a narrow reading width.

## Generate and prepare

Run from the repository root on macOS with the Xcode command-line tools installed:

```sh
Scripts/generate_documentation_images.sh
# Check existing images and README links without recapturing:
Scripts/generate_documentation_images.sh --validate
```

The capture command and sanitizer use only Apple frameworks and existing project test infrastructure. `DocumentationScreenshotTests` renders real native views with temporary preferences, files, archives and task results. `FinderMenuDocumentationTests` displays the production Finder menu with demonstration items. Tests do not replace the user's settings, clipboard or system permissions. These are reproducible demonstration captures; they do not assert that the installed Finder extension or system screenshot permissions have been granted. If additional real interactions require unavailable system access, record that limitation instead of presenting an old screenshot as a new capture.

The Finder image losslessly combines the real parent and submenu view bitmaps at their native positions. They are captured sequentially to avoid an AppKit inactive-menu vibrancy artifact; no labels, controls or icons are recreated. The archive view demonstrates searching for Markdown files while an unsaved configuration entry stays open, which also avoids an AppKit sidebar-selection capture artifact.

Each run keeps raw images, fixtures, build logs and the test result bundle in a fresh ignored `build/documentation/raw.*` directory. Do not copy raw images directly into `img/` or commit them. Only the sanitizer's checked output belongs in `img/`. Privacy and README validation reports are written to `build/documentation/`.

To reprocess an existing raw set or supply extra private project names, run:

```sh
swift Scripts/prepare_documentation_images.swift \
  --input build/documentation/raw.EXAMPLE --output img \
  --private-token 'PRIVATE_PROJECT_NAME' \
  --report build/documentation/privacy-report.json
```

## Image inventory

Every scene has both `-en.png` and `-zh-CN.png` variants with the prefix `clickmate-`:

| Scene | Purpose |
| --- | --- |
| `finder-menu` | Actual Finder context menu with sample files |
| `quick-features` | Finder Cut and screenshot controls |
| `screenshot-annotation` | Screenshot editor containing sample content and annotations |
| `scrolling-capture` | Long screenshot preview containing a sample page |
| `archive-editor` | Sample archive with an entry open for editing |
| `file-tasks` | Demonstration progress, item results and move recovery |
| `settings-menus` | Menu controls |
| `settings-layout` | Submenus and top-level shortcuts |
| `template-editor` | Template draft with a filename and text content |
| `settings-apps` | Detected and pinned applications |
| `permissions` | Feature permission guide and trial results |
| `settings-data` | Configuration backup, recovery and transfer |

The sanitizer requires all 24 expected names and rejects unexpected `clickmate-*.png` captures in its source directory. Other image assets in the published directory are retained.

## Privacy processing

Vision OCR recognizes English and Simplified Chinese. Rules detect the current account name, full name, home-directory account component, host name, email addresses and `/Users/…` account paths. Add other private project or organization names using repeatable `--private-token 'PRIVATE_TEXT'` arguments. These values are never included in generated reports.

Sensitive text pixels are first replaced with an opaque neutral fill. A local blur is then applied to the erased region, so the original characters cannot be recovered by sharpening the image. Images are flattened into fresh sRGB bitmaps and written to new PNG destinations without copying source metadata. Final OCR and metadata checks run before the complete set is published. A failure leaves the existing published image set untouched during validation; a filesystem failure while publishing can still require rerunning the command.

Reports contain filenames, dimensions, rule identifiers, redaction rectangles and pass/fail flags. They never contain recognized text, account names, full source paths or supplied private tokens. The self-test draws sensitive fixture strings in a temporary image and verifies detection, changed pixels, final OCR and clean PNG metadata; the temporary fixture is deleted afterward.

OCR is a screening tool and cannot prove the absence of every private detail. Before committing images, inspect all 24 at full size for account names, personal folders, emails, machine names, private projects and diagnostic identity information. Check that necessary controls remain readable after redaction. Also inspect the two README files at desktop and narrow widths, including expanded settings sections and image language parity.
