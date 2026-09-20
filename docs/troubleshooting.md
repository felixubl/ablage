# Troubleshooting

## Nothing moves

Check **Preview**, **Pause**, and the inbox's **Review first** setting. Preview only
simulates actions. Review first waits for an explicit filing action. Also check whether
the planned action says no rule matches, Keep in place, or waiting for text recognition.

Ablage watches only the direct contents of each inbox. A file inside a subfolder will
not arrive in the parent inbox. Add that subfolder as another inbox if needed.

## A file would go to the wrong folder

Open its full plan and check the matching rule. Inbox rules precede shared rules; the
first ordinary match wins. Narrow broad content matches, move specific rules earlier,
or add a Keep in place rule. Use Preview while checking the change.

If the filing was learned, Undo retracts its example. You can also inspect or remove
examples with the [CLI](command-line.md), or disable learning in the configuration.

## Text recognition is waiting or failed

Queued scans are processed locally in the background. Resume Ablage if paused, or choose
**Read this file next**. Check **Settings → Preferences → Documents**: OCR must be enabled
and the file must fit its size limit. The default is 25 MiB and two scanned PDF pages.

A password-protected PDF must be unlocked in an appropriate app. **Retry reading text**
retries a failed extraction. Some older text files use encodings the current UTF-8 reader
does not accept; convert a copy to UTF-8 if needed. A failed content read blocks fallback
filing instead of silently treating the file as unmatched.

## A folder cannot be read

Confirm that it exists and is mounted. Check macOS **System Settings → Privacy & Security →
Files and Folders** for Ablage. Permission prompts vary with the folder and how the app
was signed. Rebuilding with a different signing identity can cause macOS to ask again.

## No duplicates appear

Choose the folders you want and check **Include subfolders**. Inspect **Scan details**
for read errors. Cloud-only files must be downloaded first. Files that look the same can
contain different metadata or bytes; the exact finder intentionally keeps those separate.
Try **Archive → Duplicates** for similar text after indexing documents.

## A duplicate removal was refused

One of the compared files changed, moved, or disappeared. Scan again. Ablage rechecks
the retained copy as well as the copies selected for Trash.

## A configuration change did not apply

Save the Settings window. If you edited JSON, check the error in the panel or run
`Ablage validate`. Invalid changes leave the last good configuration active. If the file
changed outside Settings while the window was open, reload it before editing again.

## Archive search misses a document

Add its folder under **Settings → Archive**, save, then **Refresh index**. Use **Read scans
and refresh…** when existing scans need OCR. External moves or edits require another refresh.
Unsupported document formats can be filed but may not have searchable contents.

## The on-device model is unavailable

It needs macOS 26, supported hardware, Apple Intelligence enabled, and a build made with
a matching SDK. Ordinary rules, local OCR, search, and duplicate finding do not need it.

## Report a bug

Include the Ablage version, macOS version, steps to reproduce, and the result you expected.
Prefer a small synthetic sample. Redact paths, document text, account names, and secrets
from config or logs. [Open an issue](https://github.com/felixubl/ablage/issues/new/choose)
or [report a security problem privately](../SECURITY.md).
