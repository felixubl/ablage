# Command line

The executable inside the app bundle also accepts commands. Set a shell variable for
convenience:

```sh
ABLAGE=/Applications/Ablage.app/Contents/MacOS/Ablage
```

With a Homebrew installation, use `ABLAGE=ablage` instead. Running `ablage` without
arguments opens the menu bar app.

## Read-only commands

```sh
"$ABLAGE" validate
"$ABLAGE" duplicates --shallow ~/Downloads
"$ABLAGE" duplicates --json ~/Downloads ~/Desktop
"$ABLAGE" text --no-ocr ~/Downloads/document.pdf
"$ABLAGE" text ~/Downloads/scan.pdf
"$ABLAGE" suggest ~/Downloads/document.pdf
"$ABLAGE" examples
```

| Command | Result |
|---|---|
| `validate` | Parse configuration and report invalid rules, regexes, or model references |
| `duplicates` | Compare folders recursively; `--shallow` limits each folder to its direct files |
| `duplicates --json` | Report groups, file snapshots, skipped items, errors, and scan counts as JSON |
| `text` | Print extracted text; OCR is allowed unless `--no-ocr` is present |
| `suggest` | Print the local learner's suggestion; does not file the document |
| `examples` | List learned examples, including negative or pending examples |

Duplicate reports include full local paths. Exit code `0` means the scan completed without
reported read issues; `1` reports issues or failure; `2` means invalid command usage.
The duplicate command does not load the archive index or learner.

## Commands that change state

```sh
"$ABLAGE" learn Invoices ~/Downloads/invoice.pdf
"$ABLAGE" learn Invoices ~/Downloads/unrelated.pdf --negative
"$ABLAGE" forget Invoices ~/Downloads/invoice.pdf
"$ABLAGE" add-rule '{"name":"CSV files","match":{"extensions":["csv"]},"action":{"destination":"~/Documents/Data"}}'
```

`learn` and `forget` change training examples. `add-rule` appends a shared rule after
validating the configuration. These commands do not move the sample files.

```sh
"$ABLAGE" ocr-layer /path/to/a-copy-of-a-scan.pdf
```

`ocr-layer` rewrites a PDF **in place**, independently of Preview mode. It does not create
the automatic filing workflow's Undo backup. Run it on a copy you are willing to change.

## Open the duplicate window

```sh
open /Applications/Ablage.app --args --duplicates
```

The launch argument is handled when a new app process starts. An already-running Ablage
can open the window from its gear menu.

## Isolated development runs

`ABLAGE_DIR` redirects configuration, journal, learner, index, originals, and logs.
`ABLAGE_SIMULATE=0|1` and `ABLAGE_PAUSED=0|1` override those preferences for that process.
These are intended for tests. [Development guide](development.md)
