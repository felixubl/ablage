# Privacy and backups

## What stays on your Mac

File matching, text recognition, archive search, duplicate detection, and learning run
locally. Ablage has no account system or telemetry. It uses the macOS frameworks and
system SQLite library; there is no database server to run.

The index and learned examples are not an encrypted vault. They can contain extracted
text and words from private documents. Protect your Mac and backups accordingly.

## When data leaves your Mac

- **Email:** a configured account connects to its IMAP server.
- **Models:** a manual request or a rule with permission to use a model sends the documented
  input to that provider. [Model inputs and consent](integrations.md#models)
- **Scripts:** a post-filing command can do whatever you configured it to do, including uploading files.

No model or email account is configured on a new install. Files in a cloud-synced folder
remain subject to that folder's own sync service, whether or not Ablage is running.

## Stored files

| Data | Location |
|---|---|
| Configuration | `~/.config/ablage/config.json` |
| Previous Settings save | `~/.config/ablage/config.previous.json` |
| Activity, latest 500 actions | `~/Library/Application Support/Ablage/journal.json` |
| Learned examples | `~/Library/Application Support/Ablage/learned.json` |
| Text index, metadata, saved views, integrity baselines | `~/Library/Application Support/Ablage/archive.sqlite` |
| Permanently preserved originals | `~/Library/Application Support/Ablage/preserved-originals/` |
| Pre-rewrite PDF copies for Undo | `~/Library/Application Support/Ablage/originals/` |
| Email checkpoints and staged attachments | `~/Library/Application Support/Ablage/mail/` |
| Email passwords | macOS Keychain, service `at.fubl.ablage.imap` |
| Model API keys | The key file you select; legacy inline keys may be present in config JSON |
| Log | `~/Library/Logs/Ablage.log` |
| Preview, Pause, window and duplicate-scan preferences | macOS preferences for `at.fubl.ablage` |

Activity and logs contain filenames, paths, rule names, errors, and some inferred document
details. Script output is logged too. Inspect and redact these before attaching them to
an issue. Exported configuration can contain personal paths and account identifiers.

## Back up and restore

Back up your document folders, `~/.config/ablage`, and the complete Ablage Application
Support folder. Back up API key files separately if you need to preserve them.

Quit Ablage before copying `archive.sqlite` manually. If a backup runs while Ablage is
open, it must capture SQLite's accompanying WAL files consistently. Restore the folders
to their original paths before reopening Ablage, or update the configuration paths.

Search text can be rebuilt. Corrected metadata, saved views, learned examples, and integrity
baselines cannot be recovered from filenames alone. Email credentials live in Keychain
and may need to be entered again on another Mac.

## Undo has limits

Undo restores recorded moves, tags, metadata edits, and Trash actions whose Trash location
was recorded. It needs the file to remain available and the action to remain in the journal.
Emptying Trash removes that recovery path. Pre-rewrite PDF originals normally expire after
30 days. Permanent preservation keeps originals separately until you remove them.

Undo does not reverse post-filing scripts or replace a backup.

## Uninstall

Quit Ablage and remove `/Applications/Ablage.app`. Your filed documents remain in their
folders. For a Homebrew installation, use `brew uninstall felixubl/tap/ablage` instead.
Keep the configuration and Application Support folder if you may reinstall;
remove them separately only if you no longer need their history, metadata, or originals.
Remove saved email credentials through Keychain Access if desired. Disabling launch at
login before uninstalling removes Ablage's login item.
