# Ablage

A menu bar app for the Mac that files what lands in your Downloads folder, the way
[paperless-ngx](https://docs.paperless-ngx.com) files scanned mail. Rules decide where a
document goes and what it is called. What the rules miss, you file once by hand, and Ablage
learns from that. Every move shows up in a small panel and can be undone.

*Ablage* is the German word for a filing tray.

## What it does

A file arrives in Downloads. Ablage waits until the browser is done writing it, then reads it:
the name, where it was downloaded from, and the text inside. PDFs are read directly, scans and
screenshots go through OCR, Office files are unpacked. Then it walks your rules top to bottom.
The first rule that matches moves the file, renames it from a template, and adds Finder tags.

    Rechnung_Amazon.pdf  →  ~/Documents/Finanzen/2026/2026-03-15_Rechnung_Amazon.pdf   [Rechnung]

The date comes from the document itself, the year in the folder name from that date. An
identical file that already sits at the destination is recognised by its checksum and goes to
the Trash instead of becoming `Rechnung_Amazon 2.pdf`.

Files that no rule wants stay in Downloads and appear in the panel. From there you can file
one with any rule in two clicks. Every filing, by rule or by hand, trains a classifier, and
files that look like something already filed get the same treatment without a rule.

Scanned PDFs get an invisible text layer after filing, so Spotlight and Preview can search
them. The archive stays a folder tree you can read without Ablage.

## Install

    git clone git@github.com:felixubl/ablage.git
    cd ablage
    make install

This builds the app, signs it for your machine, copies it to /Applications and opens it. macOS
asks once for access to Downloads and to each destination folder it first writes to, and once
for notifications. Needs macOS 14. The on-device model needs macOS 26 with Apple Intelligence.

There is nothing to configure before the first download. A config file with a set of starter
rules is written on first launch.

## First run

Ablage starts in **simulation**. Rules run, the panel shows what each one would have done, and
nothing moves. Download a few things, open the panel, read the activity list. When it looks
right, turn Simulate off. Until then the worst that can happen is a wrong line in a list.

Files that were already in Downloads before the first launch are left alone. They wait for
**Sort now** in the panel, which runs every rule over everything, or for a rule with
`minAgeDays`, which also runs on the periodic rescan. Both can be undone file by file.

## The panel

Click the tray icon in the menu bar.

- **Inbox** lists what is waiting, newest first, with what Sort now would do to each file:
  the rule that would take it, `(learned)` when the classifier would, or the model that would be
  asked. Right-click a file for **Apply rule**, **New rule from this file**, **Quick Look**,
  **Reveal in Finder**, **Ask model**, and **Move to Trash**. Double-click opens it. A filter
  field appears when the list gets long.
- **Review…** opens a table of everything waiting with the same "would" column, for the
  thousand files that were in Downloads before Ablage. Select rows, or *Select suggested*, then
  *File selection*, apply one rule to all of them, or trash them. Space is Quick Look.
- **Drop files onto the panel** to file them by the rules, wherever they come from.
- **Activity** shows the last moves with the rule, the reason (`learned · like x.pdf (80%)`,
  `via apple: Stadt Wien, Bescheid`), and an **Undo** button. Undo puts the file back and
  restores its previous tags.
- **Simulate** and **Pause** are switches at the top. While paused, arrivals are held and
  sorted when you resume.
- **New rule…** opens a form. **Rules…** opens the config file. **Log** opens the log.

Notifications tell you what was filed where. Clicking one reveals the file.

## How a file is filed

Three stages, in this order, and the later ones only run when the earlier ones declined:

1. **Rules.** Deterministic, written by you, first match wins. This is where almost everything
   should be decided.
2. **The classifier.** Trained on everything that was filed. A file that no rule matched gets
   the rule the classifier is sure about, marked `(learned)` in the panel with the nearest
   example it resembles. Undo records a counterexample.
3. **Models.** Only when a rule explicitly names one. Nothing is sent anywhere otherwise.

## Rules

Rules live in `~/.config/ablage/config.json`. The file is written with a help block and a
starter set on first launch, and edits are picked up while the app runs. A mistake shows up in
red at the top of the panel; the last good config stays active until it is fixed.

The form behind **New rule from this file…** writes the same JSON for you. It pre-fills the
extension and the download source, shows the document's text so you can pick keywords, lets
you choose the destination folder, and can apply the rule to the file right away.

```json
{
  "name": "Rechnungen",
  "match": { "extensions": ["pdf"], "content": ["Rechnung", "Invoice", "Rechnungsnummer"] },
  "action": { "destination": "~/Documents/Finanzen/{year}", "rename": "{date}_{name}", "dateFrom": "content", "tags": ["Rechnung"] }
}
```

Every criterion in `match` must hold. Lists inside a criterion are alternatives.

| match | meaning |
|---|---|
| `kind` | `file` (default), `folder`, or `any` |
| `extensions` | list, case-insensitive |
| `filename` | substrings, any of them |
| `filenameRegex` | regular expression on the file name |
| `source` | substrings of the URL the file was downloaded from |
| `content` | substrings of the text, any of them |
| `contentAll` | substrings of the text, all of them |
| `contentRegex` | regular expression on the text |
| `minAgeDays` | days since the file arrived. Rules with this also run on the rescan |
| `minSizeMB`, `maxSizeMB` | size bounds |
| `fuzzy` | `true` lets `filename` and `content` terms match with one wrong character (two from nine characters on), for OCR errors |
| `ai` | `{ "model": "apple", "description": "…" }`, see Models |

| action | meaning |
|---|---|
| `destination` | folder, may use placeholders. Without `~` or `/` it is relative to the inbox |
| `rename` | new name without extension, may use placeholders |
| `tags` | Finder tags to add |
| `correspondent` | fixed value for `{correspondent}` |
| `dateFrom` | `file` (default), `content` (first plausible date in the text, then in the name), or `filename` |
| `trash` | `true` moves the file to the Trash |
| `run` | shell command to run afterwards, see Scripts |
| `ai` | model that fills `{correspondent}`, `{title}` and the date for this rule |

Placeholders: `{date}` `{year}` `{month}` `{day}` `{name}` `{ext}` `{correspondent}` `{title}`
`{rule}` `{host}`. Dates are recognised in the forms `15.03.2026`, `2026-03-15`, `20260315`,
`15. März 2026` (also Jänner and Feber), and `March 15, 2026`.

A rule with a `match` and no `action` keeps the file where it is and stops later rules from
matching it. Use it to protect things.

Other keys at the top level: `inbox`, `ignore` (glob patterns), `settleSeconds` (quiet time
before a file counts as arrived, default 3), `rescanMinutes` (default 30),
`sortExistingOnRescan`, `notifications`, `ocr`, `ocrPages`, `ocrMaxMB`, `searchablePDFs`,
`textLayerMaxPages`, `originalsDays`.

## Several inboxes

    "inboxes": [
      { "path": "~/Downloads" },
      { "path": "~/Desktop", "ignore": ["*.sketch"], "rules": [ ... ] },
      { "path": "~/Scans", "sortExistingOnRescan": true, "rules": [ ... ] }
    ]

Each inbox runs its own `rules` first, then the shared top-level `rules`. Relative destinations
are relative to that inbox. The panel groups files by inbox. A destination inside another inbox
is fine: the file is then handled by that inbox's rules next.

## Learning

This is paperless-ngx's *auto* matching. paperless trains a classifier on every document
that has a correspondent, type or tag assigned, whether a person or a matching rule assigned
it. Ablage does the same with rules.

**Training data.** Every filing becomes an example: the words of the document, stemmed,
with stop words removed, plus word pairs, the words of the file name, the extension and the
download host. A filing you did by hand with *Apply rule* counts at once and weighs three
times a rule filing. A rule filing counts after `confirmAfterHours` (default 24) have passed
without an undo, so a wrong rule does not teach anything before you had a chance to see it.
Undo takes the example back; undoing a learned filing also records a counterexample.

**Deciding.** A multinomial naive Bayes classifier over those features gives a probability for
each rule that has at least `minExamples` examples. The winner needs `minConfidence` (default
0.8) and a clear margin over the runner-up. On top of that, the document must resemble the
nearest example of that rule with a cosine similarity of at least `minSimilarity` (default
0.25), which is what lets the learner say "this looks like nothing I have seen" instead of
forcing a choice, and it must resemble it more than any counterexample. Rules that trash files
and rules without an action are never learned.

    "learning": { "enabled": true, "minExamples": 2, "minConfidence": 0.8, "minSimilarity": 0.25, "fromRules": true, "confirmAfterHours": 24 }

The activity list shows the reason: `learned · like Rechnung_2026-03.pdf (72%), 99% sure`.
Examples live in `learned.json`; the command line can add, inspect and remove them.

## Searchable PDFs

A scanned PDF is a picture. Spotlight cannot search it, Preview cannot select text in it, and
Ablage itself has to OCR it every time. After filing, Ablage renders each page, recognises the
text with Apple's Vision framework, and writes it back into the PDF as invisible text placed
over the words, the way ocrmypdf does. The page images are re-embedded untouched. From then
on Spotlight finds the document by its content.

This runs in the background after the move, only for PDFs that have no text layer, and only up
to `textLayerMaxPages` (default 60) and `ocrMaxMB`. The original bytes are kept under
Application Support for `originalsDays` (default 30) and Undo restores them. Turn it off with
`"searchablePDFs": false`. The same thing on demand: `Ablage ocr-layer file.pdf`.

## Models

Models are opt-in and explicit. A rule names its model; nothing else ever calls one.

    "ai": {
      "models": {
        "apple":  { "provider": "apple" },
        "local":  { "provider": "openai", "endpoint": "http://localhost:1234/v1", "model": "qwen2.5-vl-7b", "vision": true },
        "claude": { "provider": "anthropic", "model": "claude-opus-5", "apiKeyFile": "~/.config/ablage/anthropic.key", "vision": true }
      }
    }

| provider | what it is |
|---|---|
| `apple` | Apple's on-device model. Free, private, no setup. Text only. macOS 26 |
| `openai` | any OpenAI-compatible endpoint: LM Studio, Ollama, or a hosted service |
| `anthropic` | the Claude API |

**Local models**, meaning `apple` or an endpoint on localhost, may run on their own whenever a
rule names them. **Remote models never run on their own.** They run when you choose *Ask model*
on a file in the panel, or when you set `"automatic": true` on that model. Every model call is
written to the log with the model name and the file name.

A rule hands a decision to a model with `"ai": { "model": "apple", "description": "Rechnung,
Beleg oder Quittung" }` in its `match`. Once the plain criteria hold and no plain rule matched,
the file's text goes to that model together with the descriptions of all rules that use the
same model, and the model picks one or none. It also returns a correspondent, a title and a
date, which `{correspondent}` and `{title}` pick up. `"ai": "apple"` in an `action` does only
the extraction, for a rule that matched on its own.

Models with `"vision": true` get screenshots and scanned PDFs as pictures instead of OCR text.
API keys go into a file, never into the config. Requests to Claude are sent with
`fallbacks: "default"`, so a declined request is re-run server side on a fallback model.

## Scripts after filing

    "action": { "destination": "~/Documents/Finanzen/{year}", "run": "~/bin/upload-to-paperless.sh \"$ABLAGE_TO\"" }

The command runs in `zsh` after the move, with `ABLAGE_FROM`, `ABLAGE_TO` and `ABLAGE_RULE`
in its environment. Output and exit status go to the log; a failing script shows in the
activity list. This is paperless-ngx's post-consume script.

## Command line

The binary inside the bundle doubles as a small CLI for scripts and tests.

    A=/Applications/Ablage.app/Contents/MacOS/Ablage
    $A learn Rechnungen ~/Downloads/x.pdf       # teach, same as Apply rule in the panel
    $A learn Rechnungen ~/Downloads/y.pdf --negative
    $A forget Rechnungen ~/Downloads/x.pdf
    $A suggest ~/Downloads/z.pdf                # what the learner would do
    $A examples
    $A add-rule '{ "name": "CSV", "match": { "extensions": ["csv"] }, "action": { "destination": "~/Data" } }'
    $A validate                                 # parse the config and report bad regexes and unknown models
    $A text ~/Downloads/scan.pdf                # the text Ablage sees, OCR included; --no-ocr for the text layer only
    $A ocr-layer ~/Downloads/scan.pdf           # add a text layer to a scanned PDF in place

## Files and privacy

| what | where |
|---|---|
| config | `~/.config/ablage/config.json` |
| activity journal | `~/Library/Application Support/Ablage/journal.json` |
| learned examples | `~/Library/Application Support/Ablage/learned.json` |
| originals of rewritten PDFs | `~/Library/Application Support/Ablage/originals/`, purged after `originalsDays` |
| log | `~/Library/Logs/Ablage.log`, kept under a few hundred kilobytes |

Everything runs on the Mac. OCR is Apple's Vision framework, the learner is a few hundred
lines of Swift, and no network request is made unless a rule names a remote model and you
allowed it. `ABLAGE_DIR=<folder>` puts config, journal, examples and log into one folder,
which the tests use.

## Development

    make build      # swift build, release
    make app        # bundle into dist/Ablage.app and sign ad hoc
    make install    # bundle, copy to /Applications, open
    scripts/e2e.sh  # end-to-end test against a scratch inbox

The test builds the binary, starts it against a temporary config with two inboxes, drops
generated PDFs, a rendered scan and folders into them, and checks moves, renames, tags, OCR,
fuzzy matching, the classifier learning from rule filings and filing an invoice no rule
matched, the text layer on a scanned PDF, the post-filing script, adding a rule while the app
runs, and config validation.

Source layout, all under `Sources/Ablage`:

| file | role |
|---|---|
| `Engine.swift` | watching, settling, the three filing stages, undo, previews |
| `Rule.swift` | rule model and deterministic matching |
| `Extract.swift` | text from PDF, OCR, Office and text files; date recognition |
| `Learner.swift` | text features, examples, the classifier |
| `SearchablePDF.swift` | text layers for scans, kept originals |
| `AI.swift`, `AppleModel.swift` | model providers |
| `Config.swift`, `DefaultConfig.swift` | config model, starter config, rule insertion, validation |
| `Views/` | the panel, the review table, the rule editor |
| `CLI.swift` | the command line |

## What it takes from paperless-ngx

The consumption folder as the one place things arrive. Matching on document content, not just
names, with *any*, *all*, *regex* and *fuzzy* modes. Auto matching: a classifier trained on
everything that gets filed. OCR that ends up inside the PDF, so the archive is searchable.
Correspondent, title and date as the parts a filename is built from. Storage paths with
placeholders. Duplicate detection by checksum. A post-consume script. And the idea that the
document is the source of truth for its own date.

What it leaves out, on purpose: a database, a web server, a document viewer, and any reason
to keep documents anywhere but in folders you already have.
