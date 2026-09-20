# Documents and archive

## Review a document

Choose **Review & file…** on an inbox file, or **Review & edit…** in Archive.
The file preview sits beside its title, sender, date, type, and Finder tags.
Invoice fields include number, amount, currency, and due date; you can add custom fields.

Choose a rule or enter a destination and name yourself. After correcting details,
**Update naming from these details** reapplies the selected rule's templates.
Post-filing commands are shown and can be skipped for this document.

Approval checks that the file still has the contents you reviewed. Preview records the
action without moving the file or saving changed document details. Undo restores the
previous location, tags, and recorded details.

## Read text

PDF text layers are read directly. Ablage also reads common text formats and extracts
text from DOCX, XLSX, and PPTX files. Legacy `.doc` and `.xls` formats are not supported
for text extraction. Spreadsheet extraction is limited to stored shared strings, not
a complete rendering of every cell.

Images and scanned PDFs use Apple's on-device text recognition, configured for German
and English. Recognition needed by a plan runs in the background, one document at a time.
**Read this file next** prioritizes a queued scan; **Pause** holds queued work.

Defaults are the first two scanned PDF pages and files up to 25 MiB. Change them under
**Settings → Preferences → Documents**. OCR can misread text, so inspect important dates
and amounts. Reading for a plan leaves the file's bytes unchanged.

## Make scans searchable

When enabled, Ablage adds an invisible text layer after filing a scanned PDF. This is a
separate operation from reading text for a plan: it **rewrites the PDF**. The original
pages are drawn into a new PDF and recognized text is added over them. Do not assume
that signatures, interactive forms, bookmarks, or every original PDF feature survive.

Automatic text-layer creation is limited to PDFs of at most 60 pages and the configured
OCR size limit. Ablage retains the pre-rewrite bytes for Undo for 30 days by default.
Turn it off with `searchablePDFs: false`, or enable permanent preservation in Archive
settings. [Storage and backups](privacy.md)

The `ocr-layer` command rewrites a file directly and does not provide the filing workflow's
Undo backup. Use it on a copy. [Command-line reference](command-line.md)

## Search filed documents

New filings are indexed automatically. To include existing documents:

1. Open **Settings → Archive** and add folders, or choose **Add my filing destinations**.
2. Save changes.
3. Open **Archive** and choose **Refresh index** from its refresh menu.

Indexing includes subfolders and supported document formats. **Read scans and refresh…**
also runs OCR. An ordinary refresh reads available text without OCR or changes to the files.

Search names, contents, tags, and document details. Filter by folder, sender, type, date,
or a custom field. **Saved views** stores the search and filters together.
Refresh after edits or moves made outside Ablage.

## Check an archive

**Integrity → Check files** compares files with their recorded checksums and checks
preserved originals. Missing, changed, and unreadable files appear separately.
After verifying an intentional edit, choose **Accept current contents…** to set a new
baseline. Refreshing the index does not silently accept a changed baseline.

**Keep original documents forever** preserves copies of newly filed or indexed documents.
Identical originals share one stored copy. **Save original copy…** exports a preserved
copy without replacing the working file. This does not replace your Mac's backup.

## Split a scan

Choose **Split scan…** on a PDF. Mark the first page of each document, choose an output
folder and filename prefix, then create the separate PDFs. The source is retained;
existing filenames are avoided.

For repeated batches, use **Save separator sheet…** to print a QR sheet. Place it between
documents before scanning, then detect the separators. The default payload is `ABLAGE:SPLIT`.
Review the proposed groups before splitting. Separator pages remain in the original and
are excluded from the resulting documents.

Outputs created in a watched inbox follow that inbox's rules.
