# Rules and configuration

Use **Settings → Rules** for everyday editing. Choose shared rules or one inbox's rules,
then add, edit, enable, or reorder them. Changes take effect after **Save changes**.

The same settings live in `~/.config/ablage/config.json`. Ablage reloads edits while
running. Invalid changes show an error; the last valid configuration stays active.
Settings keeps `config.previous.json` and refuses to overwrite concurrent edits.

## Start with a specific match

```json
{
  "name": "Invoices by filename",
  "match": {
    "extensions": ["pdf"],
    "filenameRegex": "^(invoice|receipt)[_ -]"
  },
  "action": {
    "destination": "~/Documents/Invoices/{year}",
    "dateFrom": "filename",
    "tags": ["Invoice"]
  }
}
```

This matches `invoice_2026-09-20.pdf`. It preserves the name and adds an Invoice tag.
A regex match is case-insensitive. Dates fall back to the file's modification date
when no usable date is found.

Check examples in [starter-config.json](../examples/starter-config.json) and
[multiple-inboxes.json](../examples/multiple-inboxes.json). To import one, open
**Settings → Advanced → Import configuration…**, review it, and save. Import replaces
the staged configuration; it does not merge rule lists.

## Several inboxes

```json
{
  "inboxes": [
    { "path": "~/Downloads", "name": "Downloads", "reviewFirst": true },
    { "path": "~/Scans", "name": "Scans", "reviewFirst": true, "rules": [] }
  ],
  "rules": []
}
```

Each inbox runs its own rules before shared top-level rules. All ordinary rules are
checked before learned suggestions or model rules. The first ordinary match wins.
An empty action means **Keep in place** and stops later rules.

Relative destinations are resolved against that inbox. Inboxes can also set `enabled`,
`ignore`, and `sortExistingOnRescan`. Shared ignore patterns apply alongside inbox patterns.
The older single-folder `"inbox": "~/Downloads"` format still works.

Inbox watching is not recursive. Avoid sending a file between inboxes with rules that
route it back again.

## Match fields

Every listed field must match. Lists mean “any of these,” except `contentAll`.

| Field | Meaning |
|---|---|
| `kind` | `file` (default), `folder`, or `any` |
| `extensions` | Extensions without dots, case-insensitive |
| `filename` | Any listed substring of the name |
| `filenameRegex` | Regular expression on the name |
| `source` | Any listed substring of a recorded download URL; unavailable sources do not match |
| `content` | Any listed substring of extracted text |
| `contentAll` | Every listed substring of extracted text |
| `contentRegex` | Regular expression on extracted text |
| `minAgeDays` | Minimum age since arrival in the folder, falling back to creation or modification time |
| `minSizeMB`, `maxSizeMB` | Bounds in MiB (1,048,576 bytes) |
| `fuzzy` | Allow small spelling differences in `filename` and `content` terms |
| `ai` | Model name and category description; see [Integrations](integrations.md#models) |

`minAgeDays` is **not** time since last opened. Age rules also run on periodic rescans
unless the inbox is held for review. Ablage does not currently use Spotlight usage dates.

For content rules, use distinctive headings or a combination of terms. A broad match on
“contract” can also catch a lecture about contracts. Failed text extraction blocks later
fallbacks instead of treating the unreadable file as a non-match.

## Actions

| Field | Meaning |
|---|---|
| `destination` | Folder path or template; no leading `/` or `~` means relative to the inbox |
| `rename` | New filename stem; the original extension is kept |
| `tags` | Finder tags to add; existing tags are retained |
| `dateFrom` | `file` (default), `filename`, or `content` |
| `correspondent` | Fixed value for the sender placeholder |
| `trash` | Move to macOS Trash |
| `run` | Shell command after filing; review before enabling |
| `ai` | Name of a model used to fill document details |

A destination collision never overwrites the existing file. If the bytes are identical,
the incoming copy goes to Trash; otherwise Ablage chooses an available filename.
The plan flags existing destinations before filing.

## Naming templates

| Placeholder | Value |
|---|---|
| `{date}`, `{year}`, `{month}`, `{day}` | Selected date; `date` is `YYYY-MM-DD` |
| `{name}`, `{ext}` | Original stem and extension |
| `{title}`, `{correspondent}`, `{type}` | Document details |
| `{invoice_number}`, `{amount}`, `{currency}`, `{due_date}` | Invoice fields |
| `{field.project}` | A custom field named Project |
| `{rule}`, `{host}` | Rule name and download host |

With `dateFrom: "content"`, Ablage uses the first plausible date in the text, then the
filename, then the file's modification date. Recognized forms include `2026-09-20`,
`20.09.2026`, `20260920`, `20. September 2026`, and `September 20, 2026`.
A date you correct in document review takes precedence. An inferred date is not guaranteed
to be an invoice or issue date.

Missing invoice, type, or custom fields remain visible in the plan and hold automatic
filing until completed. Template values cannot insert extra directory levels.

## Other settings

Defaults below apply when a key is omitted. New starter files additionally enable
Review first on Downloads.

| Key | Default | Purpose |
|---|---|---|
| `ignore` | `[]` | Filename glob patterns to skip |
| `settleSeconds` | `3` | Quiet time before processing an arriving file |
| `rescanMinutes` | `30` | Periodic scan; `0` disables it |
| `sortExistingOnRescan` | `false` | Allow rescans to process existing files with all rules |
| `notifications` | `true` | Filing notifications |
| `ocr` | `true` | On-device text recognition |
| `ocrPages` | `2` | Scanned PDF pages to read for matching |
| `ocrMaxMB` | `25` | Maximum file size for OCR, in MiB |
| `searchablePDFs` | `true` | Add text layers to filed scans |
| `textLayerMaxPages` | `60` | Maximum PDF length for a text-layer rewrite |
| `originalsDays` | `30` | Retention of pre-rewrite copies used by Undo |
| `keepOriginalsForever` | `false` | Preserve originals without time-based deletion |
| `archiveFolders` | `[]` | Folders included in archive indexing |
| `mailAccounts` | `[]` | Optional email intake |
| `ai` | No configured models | Optional model settings |
| `learning` | Enabled | Local matching learned from prior filings |

## Learning

After ordinary rules, the learner can suggest the action of a rule used on similar files.
Manual examples count immediately and have more weight. Automatic rule filings become
examples after 24 hours without an undo. Undo retracts the example; undoing a learned filing
also records a counterexample. Trash and Keep rules are not learned.

```json
{
  "learning": {
    "enabled": true,
    "minExamples": 2,
    "minConfidence": 0.8,
    "minSimilarity": 0.25,
    "fromRules": true,
    "confirmAfterHours": 24
  }
}
```

Set `enabled` to `false` to use only explicit rules and model requests. Set `fromRules`
to `false` to learn from manual filings only. Learning happens locally; it does not require
an AI service. [Inspect or remove examples from the terminal](command-line.md).
