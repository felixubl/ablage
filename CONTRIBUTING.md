# Contributing to Ablage

Small, focused changes are welcome. For a larger feature, open an issue first with the
workflow you want to improve. The [roadmap](docs/roadmap.md) shows the current direction.

## Report a problem

Include your macOS version, Ablage version or commit, what you expected, and what happened.
A small fictional document and a minimal rule are often enough to reproduce a filing bug.
Redact filenames, paths, account details, and document text from logs and screenshots.
Report security issues [privately](SECURITY.md).

## Send a change

1. Fork the repository and create a branch.
2. Make one coherent change. Follow the surrounding Swift style.
3. Run `swift test` and `python3 scripts/check-docs.py`. For app or packaging changes,
   also run `make app SIGN_ID=-`.
4. Describe the problem, the resulting behavior, and how you checked it in the pull request.

Add regression coverage when changing matching, file actions, migrations, permissions,
or data handling. Use generated fixtures; never commit personal documents, credentials,
or actual configuration files. For interface changes, check light and dark appearances
and a small window. Update the relevant guide when behavior changes.

The [development guide](docs/development.md) explains isolated runs and visual previews.
Documentation improvements and useful example rules are contributions too.

## A few design rules

- Leave unmatched files alone and make proposed actions understandable.
- Keep Preview, Review first, and Undo dependable.
- Keep everyday filing local. External services must be optional and explicit.
- Prefer standard macOS controls and short labels over extra settings.

By submitting a contribution, you agree that it may be distributed under the project's
[MIT license](LICENSE). No contributor license agreement is required.
