# Roadmap

These are directions for future work, not features in the current app or promised release
dates. The aim is to make filing more dependable without making the daily interface busier.

## Remote folders over SSH/SFTP

Start with a remote destination: review a document locally, then file it to a server or
NAS. Use SSH keys or an agent, verify the server's host key, upload under a temporary name,
verify the completed transfer, and only then finish the local action. A failed connection
must leave the local document available and offer a clear retry.

Remote inboxes can follow: fetch new arrivals into a local review queue with checkpoints
and duplicate protection. Remote deletion should be an explicit option. This needs clear
offline status, collision handling, and recovery rules before it can behave like a local
inbox. Two-way folder sync is outside the intended scope.

## Stale files and document versions

Suggest old screenshots, installers, and forgotten downloads for review. Show the evidence:
age, last modification, and last-used information when macOS provides it. An unknown
last-used date must not mean “never opened.” Offer Keep and Remind me later alongside Trash.

Group related versions separately from byte-identical duplicates. Let people mark the
current CV, contract, or application, with separate choices for language or purpose.
A newer timestamp alone cannot decide which version matters.

## Better rule explanations

Test a draft rule against sample files before saving it. Show which condition passed or
failed, competing matches, and the resulting destination. The current per-file plan is
the starting point; a batch rule tester would make larger configurations easier to maintain.

## Easier installation and broader access

Provide signed, notarized releases and a trustworthy update path. Add English and German
localization, then check longer labels, keyboard use, and VoiceOver throughout the interface.
Keep migrations and backup guidance part of each release.

Have a concrete workflow these miss? [Open a feature request](https://github.com/felixubl/ablage/issues/new?template=feature.yml)
with an example of what you are trying to file.
