# Find duplicate files

Choose **Find duplicates…** from Ablage's gear menu or the Review window.
This compares files directly; you do not need to index an archive first.

## Scan folders

Use **Choose folders…** to add or remove locations. **Include subfolders** controls
whether the scan descends into them. Search the results by filename or folder.

Ablage compares file sizes, then SHA-256 checksums. Different filenames and extensions
can belong to the same group. A different CV revision stays separate unless its file
contents are identical. Groups with the most extra file contents appear first.

Scanning does not move files, run OCR, or contact a model. **Stop scan** leaves a clearly
marked set of partial results.

## Keep the copy you want

1. Select a group. Compare names, locations, dates, and previews.
2. Choose **Keep this copy**. The other copies are selected for removal.
3. Deselect any copies you also want to retain.
4. Choose **Review removal…** and inspect the complete list before confirming.

With Preview on, the button is **Review Trash preview…** and only records a simulation.
Otherwise, selected copies go to the macOS Trash. **Activity & Undo** can restore them.
Ablage rechecks the files before removing them and retains the copy you chose. If a
compared file changed or disappeared, scan again.

Identical file contents do not mean identical Finder tags or dates. Choose the location
and copy you actually want. Ablage does not decide which differing CV is your current one.

## What a scan leaves out

- Hidden files, app packages, aliases, symbolic links, and empty files.
- Cloud-only files that have not been downloaded.
- Ablage's own support folder and preserved originals.
- Repeated paths and hard links to the same file.

**Scan details** lists read errors and skipped cloud files. Download a cloud file in
Finder first if you want to include it. The displayed size describes file contents;
actual space freed can differ because of APFS clones, compression, or backups.

## Similar documents

**Archive → Duplicates → Compare archive documents** also finds documents with similar
text in the archive index. Similarity is a review aid, not proof of duplication: two
invoices can share almost every word but have different amounts.

## Terminal report

```sh
/Applications/Ablage.app/Contents/MacOS/Ablage duplicates --shallow ~/Downloads
```

Omit `--shallow` to include subfolders. Add `--json` for structured output.
The command only reports matches. [Command-line reference](command-line.md)
