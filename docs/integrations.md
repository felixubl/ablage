# Integrations

All integrations are optional. The starter configuration has no models or email accounts.

## Models

Add a model in **Settings → Models**, then select it under **Model assistance** in a rule.
A model can choose between described categories or fill a title, sender, and date.

| Provider | Requirements |
|---|---|
| Apple Intelligence | Supported Mac, macOS 26, Apple Intelligence enabled, and a build made with the macOS 26 SDK |
| OpenAI-compatible | An endpoint such as a local server or a hosted Chat Completions API, plus its model ID |
| Anthropic | API key and an available model ID |

New models added through Settings have automatic use turned off. Use **Ask model** on a
file to make a request, or explicitly apply a model-assisted rule. To allow unattended
requests, enable **Use automatically when a rule requests this model**, then save.
Changing the provider or endpoint resets that permission; enabling image sharing does too.

Example configuration fragment:

```json
{
  "ai": {
    "models": {
      "local": {
        "provider": "openai",
        "endpoint": "http://localhost:1234/v1",
        "model": "your-model-id",
        "automatic": false,
        "vision": false
      }
    },
    "maxChars": 3000,
    "timeoutSeconds": 90
  }
}
```

Store a hosted provider's key in a separate file and reference it with `apiKeyFile`.
The UI supports a key file; legacy inline `apiKey` configuration is also accepted but
will be included when that JSON is exported. Do not share it.

In hand-written JSON, omitted `automatic` defaults to true for Apple Intelligence and
loopback hosts (`localhost`, `127.0.0.1`, `::1`), and false for external hosts. LAN and
`.local` servers count as external. Set the field explicitly to avoid ambiguity.

A request can include the filename, download host, rule descriptions, and a document
text excerpt. With `vision: true`, it can include an image or a rendered PDF page.
Settings shows the recipient and image-sharing choice. Provider limits and charges apply.

File-plan previews and background OCR never make model requests. The **Preview** switch
simulates file actions; an explicitly requested or permitted model call can still happen
while Preview is on. Model output should be reviewed before relying on inferred details.

## Email attachments

Open **Settings → Email**. Add an IMAP host, port, username, app password, mail folder,
and a destination inbox. Use **Test connection**, save, then **Fetch now** or enable polling.

- TLS is required; the default port is 993. Certificates are checked by the system.
- Passwords are stored in macOS Keychain and are bound to the account's host and username.
- Authentication uses a password or provider app password. OAuth and STARTTLS are not supported.
- The mail folder is opened read-only. Fetching does not mark messages read, move them, or delete them.
- Only configured attachment extensions are imported; PDF is the default.

The first fetch includes existing messages in the chosen folder, up to 30 per poll.
A dedicated receipts folder makes this easier to review. Imported attachments follow
the destination inbox's rules, including **Review first**.

Checkpoints and staged delivery records survive restarts. Failed messages are retried;
**Fetch now** retries them immediately. Account status shows connection and import errors.

## Commands after filing

A rule can run a shell command after a successful action:

```json
{
  "name": "Import receipts",
  "match": { "filenameRegex": "^receipt_", "extensions": ["pdf"] },
  "action": {
    "destination": "~/Documents/Receipts",
    "run": "~/bin/import-receipt.sh \"$ABLAGE_TO\""
  }
}
```

The command runs in `zsh` with `ABLAGE_FROM`, `ABLAGE_TO`, and `ABLAGE_RULE` in its
environment. Output and exit status go to the log. Quote path variables. Commands run
with your account's permissions; inspect commands in imported rules before applying them.

Preview does not run the command. A failing command is reported, but does not roll back
the filing. Undo restores supported file actions; it cannot reverse an upload or another
side effect of your script.

## Remote folders

Native SSH/SFTP inboxes and destinations are not implemented yet. A mounted volume has
a local path, but Ablage does not provide reconnection, a transfer queue, remote checksum
verification, or reliable Undo across network failures. It is not a remote sync tool.

The [roadmap](roadmap.md#remote-folders-over-sshsftp) describes the intended workflow.
