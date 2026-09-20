# Development

## Build

You need macOS 14 or later and a Swift toolchain from Xcode or the Command Line Tools.
There are no third-party package dependencies. Apple Intelligence is compiled in only
when the Foundation Models framework is available in the SDK; other features work without it.

```sh
swift build
make app
```

The bundle is written to `dist/Ablage.app`. `make install` replaces the installed copy
in `/Applications`, quits an existing Ablage process, and opens the new build. Configuration
and stored documents are preserved. To update later, pull the repository and rebuild.

`make app` uses the first Apple Development identity in your keychain, if present.
Choose one explicitly with `make app SIGN_ID='"Apple Development: Your Name (TEAMID)"'`,
or use `make app SIGN_ID=-` for ad-hoc signing. A stable signing identity helps macOS
retain folder permissions across rebuilds. Ad-hoc builds may need permission again.

These are local development builds. The project does not yet provide a Developer ID
signed and notarized download. Do not commit signing certificates or credentials.

## Test

```sh
swift test
python3 scripts/check-docs.py
make app SIGN_ID=-
codesign --verify --strict dist/Ablage.app
```

Tests use generated documents and temporary folders. They cover configuration, rule
plans, OCR, filing and Undo, duplicate checks, archive operations, model permissions,
scan splitting, and email parsing. No provider account is required. CI runs the same
checks on macOS. Visual renders are opt-in and skipped in the normal suite.

For the additional app-process smoke test, run `zsh scripts/e2e.sh` after a release build.
It needs a logged-in desktop session for Quick Look and uses an isolated scratch inbox.
It exercises real filing and sends a generated duplicate to macOS Trash.

## Try a change without your own inbox

`ABLAGE_DIR` redirects Ablage's configuration and support files. It does **not** change
paths inside a configuration, or isolate macOS preferences and Keychain. Create a test
configuration with only scratch paths:

```sh
ABLAGE_TEST_DIR=$(mktemp -d /tmp/ablage-dev.XXXXXX)
mkdir -p "$ABLAGE_TEST_DIR/inbox"
cat > "$ABLAGE_TEST_DIR/config.json" <<EOF
{
  "inboxes": [{"path": "$ABLAGE_TEST_DIR/inbox", "reviewFirst": true}],
  "notifications": false,
  "rules": [{"name": "Notes", "match": {"extensions": ["txt"]}, "action": {"destination": "Filed"}}]
}
EOF
printf 'A test note.\n' > "$ABLAGE_TEST_DIR/inbox/note.txt"
ABLAGE_DIR="$ABLAGE_TEST_DIR" ABLAGE_SIMULATE=1 ABLAGE_PAUSED=0 .build/debug/Ablage
```

Avoid adding real email credentials to a test instance. Quit the test app before removing
its scratch folder. Preview and Pause environment overrides apply only to that process.

## Render the interface

```sh
ABLAGE_RENDER_DIR=/private/tmp/ablage-previews swift test --filter VisualPreviewTests
```

This renders the actual SwiftUI views in light and dark appearances, using fictional
documents. It does not take screenshots of your desktop. Inspect the output before
copying any images into `docs/images`. Regenerate the icon with `make icons` after changing
`Sources/Ablage/AppMark.swift`.

## Where things live

| Area | Source |
|---|---|
| Watching, rule execution, review, Undo | `Sources/Ablage/Engine.swift` |
| Configuration and validation | `Config.swift`, `ConfigDocument.swift`, `DefaultConfig.swift` |
| Matching and visible plans | `Rule.swift`, `FilePlan.swift`, `Template.swift` |
| Text extraction and searchable PDFs | `Extract.swift`, `SearchablePDF.swift` |
| Local archive and metadata | `DocumentLibrary.swift`, `DocumentMetadata.swift`, `ArchiveServices.swift` |
| Identical-file scanning | `ExactDuplicates.swift` |
| Optional model and email connections | `AI.swift`, `Mail/` |
| AppKit windows and SwiftUI views | `AblageApp.swift`, `Views/` |

Keep filesystem work off the main thread. Plans must remain read-only; a Preview action
must never mutate a document. Revalidate files before applying an action based on a prior
scan. Tests for those boundaries matter more than tests that repeat a view's implementation.

[Contribution guide](../CONTRIBUTING.md)
