# Getting started

## Choose an inbox

Ablage starts with `~/Downloads`. Open **Settings → Inboxes** to add another folder.
Each inbox has a name, its own rules, and a **Review first** setting.

Good inboxes are places where files arrive: Downloads, a scanner's output folder,
or Desktop screenshots. Ablage watches the direct contents of each inbox, not every
folder inside it. Destination folders inside an inbox are excluded from normal intake.

The starter rules are deliberately small. A filename starting with `KEEP_` stays put;
screenshots get a proposed folder by year. The invoice and installer examples are
disabled until you adapt and enable them. Existing installations keep their rules.

## Understand the three switches

| Setting | Effect |
|---|---|
| **Preview** | Simulates filing and Trash actions across Ablage. Activity records what would happen. |
| **Review first** | Holds files in this inbox until you approve them or explicitly run a filing action. |
| **Pause** | Holds automatic processing and queued text recognition until resumed. |

Preview is a dry run. Review first is an approval workflow. You can turn Preview off
and leave Review first on: approved actions then happen, while new arrivals wait.
An explicit **Sort now**, **Apply rule**, or **File selection** is a request to act;
Review first does not cancel it. Preview still applies.

Automatic text recognition can finish while you review a file. It updates the plan
without moving the file or contacting a model.

## Review a few files

Open **Review…** from the panel. The table shows each file's planned action. Select one
to see its full destination, rename, tags, and rule. Use **Review & file…** to inspect
and edit a document's details alongside its preview.

Try a few files with Preview on. Inspect Activity, then turn Preview off and approve
the files you want to move. **Activity & Undo** restores supported actions one at a time.

To file automatically later, turn Review first off for that inbox. Old files normally
wait for an explicit action. Age rules can process them during periodic rescans;
**Sort existing files on rescan** also allows broader processing.

## Add a rule

Right-click a file and choose **New rule from this file…**. Start with a distinctive
filename, download source, or document heading. Check the proposed destination before
applying it. A word such as “invoice” appearing anywhere in a lecture note is usually
too broad a test.

Rules belonging to an inbox run before shared rules. The first matching ordinary rule
wins. [Rule examples and matching details](rules.md)

## Find copies

Choose **Find duplicates…** from the gear menu or Review window. The scan starts with
your inbox and archive folders. Choose other folders or turn off **Include subfolders**
for a smaller search. Nothing is removed by scanning.

[Reviewing duplicate groups](duplicates.md)

## Shortcuts

| Where | Shortcut | Action |
|---|---|---|
| Review | ⌘F | Search |
| Review | ⌘A | Select the filtered list |
| Review | Space | Quick Look |
| Review | Return | File or preview the selection |
| Panel / Review | ⌘R | Refresh plans |
| Settings | ⌘S | Save changes |
| Duplicate finder | ⌘R | Scan again |

Changing Review filters clears the selection. Settings changes wait for **Save changes**.
