import Foundation

enum DefaultConfig {
    static let json = #"""
{
  "_help": [
    "Ablage watches the inbox folder. Rules run top to bottom, first match wins.",
    "match: every listed criterion must hold. Lists inside one criterion are OR.",
    "  kind: file | folder | any (default file)",
    "  extensions, filename (substrings), filenameRegex, source (substrings of the download URL)",
    "  content (any of), contentAll, contentRegex: text of PDFs, images (OCR), Office files, text files",
    "  minAgeDays, minSizeMB, maxSizeMB, fuzzy (true: filename and content terms may have OCR errors)",
    "  ai: { model, description }: once the other criteria hold and no plain rule matched, that model",
    "    reads the file and picks between all such rules. Remote models only do this on request",
    "    (Ask model in the panel) unless they carry automatic: true. Local models run on their own.",
    "action: destination (folder template), rename (template, no extension), tags (Finder tags),",
    "  correspondent, trash (true), dateFrom (file | content | filename), run (shell command after",
    "  filing, gets ABLAGE_FROM, ABLAGE_TO, ABLAGE_RULE), ai (model name that fills {correspondent},",
    "  {title} and the date). A rule without action keeps the file in the inbox and stops later",
    "  rules from matching it.",
    "templates: {date} {year} {month} {day} {name} {ext} {correspondent} {title} {rule} {host}",
    "  Destinations without ~ or / are relative to the inbox.",
    "ai.models: provider apple (on-device, macOS 26, needs Apple Intelligence), openai (LM Studio,",
    "  Ollama or any compatible endpoint; localhost counts as local), anthropic (Claude, remote).",
    "  vision: true sends screenshots and scans as images. Keys go in apiKeyFile, not here.",
    "learning: every filing trains a classifier. Apply rule counts at once; rule filings count after",
    "  confirmAfterHours without an undo. Files no rule matches get the rule the classifier is sure",
    "  about, marked (learned). Undo takes the example back and records a counterexample.",
    "searchablePDFs: scanned PDFs get an invisible text layer after filing, so Spotlight finds them.",
    "  The original bytes are kept for originalsDays so Undo can restore them.",
    "inboxes: replace inbox with a list to watch several folders, each with its own rules:",
    "  \"inboxes\": [ { \"path\": \"~/Desktop\", \"rules\": [ ... ] }, { \"path\": \"~/Scans\" } ]",
    "  The top-level rules apply to every inbox after the inbox's own rules.",
    "Rules with minAgeDays also run on the periodic rescan. Everything else runs on new files,",
    "  or on all files when you press Sort now. Edits to this file are picked up immediately."
  ],
  "inbox": "~/Downloads",
  "ignore": [],
  "settleSeconds": 3,
  "rescanMinutes": 30,
  "sortExistingOnRescan": false,
  "notifications": true,
  "ocr": true,
  "ocrPages": 2,
  "ocrMaxMB": 25,
  "searchablePDFs": true,
  "textLayerMaxPages": 60,
  "originalsDays": 30,
  "learning": { "enabled": true, "minExamples": 2, "minConfidence": 0.8, "minSimilarity": 0.25, "fromRules": true, "confirmAfterHours": 24 },
  "ai": {
    "models": {
      "apple": { "provider": "apple" },
      "local": { "provider": "openai", "endpoint": "http://localhost:1234/v1", "model": "", "vision": false },
      "claude": { "provider": "anthropic", "model": "claude-opus-5", "apiKeyFile": "~/.config/ablage/anthropic.key", "vision": true, "automatic": false }
    },
    "maxChars": 3000,
    "timeoutSeconds": 90
  },
  "rules": [
    {
      "name": "Screenshots",
      "match": { "extensions": ["png", "jpg", "jpeg"], "filenameRegex": "^(Screenshot|Bildschirmfoto|CleanShot|SCR-)" },
      "action": { "destination": "~/Pictures/Screenshots/{year}" }
    },
    {
      "name": "Rechnungen",
      "match": { "extensions": ["pdf"], "content": ["Rechnung", "Invoice", "Rechnungsnummer", "Gutschrift", "Receipt", "Zahlungsbeleg"] },
      "action": { "destination": "~/Documents/Finanzen/{year}", "rename": "{date}_{name}", "dateFrom": "content", "tags": ["Rechnung"] }
    },
    {
      "name": "Kontoauszüge",
      "match": { "extensions": ["pdf", "csv"], "content": ["Kontoauszug", "Umsatzübersicht", "Account Statement", "Kartenumsätze"] },
      "action": { "destination": "~/Documents/Finanzen/Konto/{year}", "rename": "{date}_{name}", "dateFrom": "content", "tags": ["Konto"] }
    },
    {
      "name": "Verträge",
      "match": { "extensions": ["pdf"], "content": ["Mietvertrag", "Vertrag", "Polizze", "Versicherungsschein", "Contract"] },
      "action": { "destination": "~/Documents/Vertraege", "rename": "{date}_{name}", "dateFrom": "content", "tags": ["Vertrag"] }
    },
    {
      "name": "Uni (Quelle)",
      "match": { "source": ["univie.ac.at", "moodle", "uspace"] },
      "action": { "destination": "~/Documents/Uni/Inbox", "tags": ["Uni"] }
    },
    {
      "name": "Uni (Inhalt)",
      "match": { "extensions": ["pdf", "docx", "pptx", "tex"], "content": ["Universität Wien", "Lehrveranstaltung", "Vorlesung", "Seminararbeit", "Matrikelnummer"] },
      "action": { "destination": "~/Documents/Uni/Inbox", "tags": ["Uni"] }
    },
    {
      "name": "Poker",
      "match": { "kind": "any", "filename": ["pokerstars", "ggpoker", "hand history", "handhistory"] },
      "action": { "destination": "~/Documents/Poker" }
    },
    {
      "name": "Installer nach 14 Tagen in den Papierkorb",
      "match": { "extensions": ["dmg", "pkg"], "minAgeDays": 14 },
      "action": { "trash": true }
    },
    {
      "name": "Bilder",
      "enabled": false,
      "match": { "extensions": ["jpg", "jpeg", "png", "heic", "gif", "webp"] },
      "action": { "destination": "~/Pictures/Downloads/{year}" }
    },
    {
      "name": "Beleg (Modell)",
      "enabled": false,
      "match": { "extensions": ["pdf"], "ai": { "model": "apple", "description": "Rechnung, Beleg, Quittung, Bestellbestätigung oder Zahlungsbestätigung" } },
      "action": { "destination": "~/Documents/Finanzen/{year}", "rename": "{date}_{correspondent}_{title}", "tags": ["Rechnung"] }
    },
    {
      "name": "Screenshot benennen (Modell)",
      "enabled": false,
      "match": { "extensions": ["png", "jpg", "jpeg"], "ai": { "model": "local", "description": "Screenshot, Foto oder Grafik" } },
      "action": { "destination": "~/Pictures/Downloads/{year}", "rename": "{date}_{title}" }
    },
    {
      "name": "Archiv nach 30 Tagen",
      "enabled": false,
      "match": { "kind": "any", "minAgeDays": 30 },
      "action": { "destination": "Archiv/{year}-{month}" }
    }
  ]
}
"""#
}
