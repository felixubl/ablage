import AppKit
import SwiftUI

struct RuleDraft {
    var original: [String: Any] = [:]
    var name = ""
    var extensions = ""
    var filename = ""
    var content = ""
    var source = ""
    var fuzzy = false
    var destination = ""
    var rename = ""
    var dateFromContent = false
    var tags = ""
    var trash = false
    var keep = false
    var applyNow = true
    var inboxPath: String?
    var localOnly = false
    var kind = "file"
    var filenameRegex = ""
    var contentAll = ""
    var contentRegex = ""
    var minAge = ""
    var minSize = ""
    var maxSize = ""
    var matchModel = ""
    var modelDescription = ""
    var actionModel = ""

    init() {}
    init(dictionary: [String: Any]) {
        original = dictionary
        name = dictionary["name"] as? String ?? ""
        let m = dictionary["match"] as? [String: Any] ?? [:]
        let a = dictionary["action"] as? [String: Any] ?? [:]
        func joined(_ key: String, in value: [String: Any]) -> String { (value[key] as? [String] ?? []).joined(separator: ", ") }
        extensions = joined("extensions", in: m); filename = joined("filename", in: m)
        content = joined("content", in: m); source = joined("source", in: m)
        fuzzy = m["fuzzy"] as? Bool ?? false
        destination = a["destination"] as? String ?? ""; rename = a["rename"] as? String ?? ""
        tags = joined("tags", in: a); trash = a["trash"] as? Bool ?? false
        dateFromContent = a["dateFrom"] as? String == "content"
        kind = m["kind"] as? String ?? "file"
        filenameRegex = m["filenameRegex"] as? String ?? ""
        contentRegex = m["contentRegex"] as? String ?? ""
        contentAll = joined("contentAll", in: m)
        minAge = (m["minAgeDays"] as? Int).map(String.init) ?? ""
        minSize = (m["minSizeMB"] as? Double).map { String($0) } ?? ""
        maxSize = (m["maxSizeMB"] as? Double).map { String($0) } ?? ""
        let ai = m["ai"] as? [String: Any] ?? [:]
        matchModel = ai["model"] as? String ?? ""
        modelDescription = ai["description"] as? String ?? ""
        actionModel = a["ai"] as? String ?? ""
        keep = !dictionary.isEmpty && a.isEmpty
        applyNow = false
    }

    static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var problems: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the rule a name.") }
        if [extensions, filename, content, source, filenameRegex, contentAll, contentRegex, minAge, minSize, maxSize, matchModel].allSatisfy({ $0.isEmpty }), original.isEmpty {
            out.append("Add at least one match criterion.")
        }
        if !matchModel.isEmpty, modelDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("Describe which documents this model should choose the rule for.") }
        if !trash, !keep, destination.isEmpty, rename.isEmpty, Self.list(tags).isEmpty,
           (original["action"] as? [String: Any])?["run"] == nil {
            out.append("Choose a destination, rename, tags, or Keep in place.")
        }
        if !minAge.isEmpty, Int(minAge).map({ $0 < 0 }) ?? true { out.append("Minimum age must be a whole number of days, zero or greater.") }
        for size in [minSize, maxSize] where !size.isEmpty {
            if Double(size).map({ !$0.isFinite || $0 < 0 }) ?? true { out.append("Sizes must be positive numbers in MB.") }
        }
        if let min = Double(minSize), let max = Double(maxSize), min > max { out.append("Minimum size exceeds maximum size.") }
        for pattern in [filenameRegex, contentRegex] where !pattern.isEmpty {
            if (try? NSRegularExpression(pattern: pattern)) == nil { out.append("Invalid regular expression: " + pattern) }
        }
        return out
    }

    var json: String {
        var rule = original
        rule["name"] = name.trimmingCharacters(in: .whitespaces)
        var match = original["match"] as? [String: Any] ?? [:]
        for (key, value) in [("extensions", extensions), ("filename", filename), ("content", content), ("source", source), ("contentAll", contentAll)] {
            let values = Self.list(value)
            match[key] = values.isEmpty ? nil : (key == "extensions" ? values.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty } : values)
        }
        match["kind"] = kind == "file" ? nil : kind
        match["fuzzy"] = fuzzy ? true : nil
        match["filenameRegex"] = filenameRegex.isEmpty ? nil : filenameRegex
        match["contentRegex"] = contentRegex.isEmpty ? nil : contentRegex
        match["minAgeDays"] = Int(minAge)
        match["minSizeMB"] = Double(minSize)
        match["maxSizeMB"] = Double(maxSize)
        if matchModel.isEmpty { match.removeValue(forKey: "ai") }
        else {
            var ai = match["ai"] as? [String: Any] ?? [:]
            ai["model"] = matchModel; ai["description"] = modelDescription
            match["ai"] = ai
        }
        rule["match"] = match
        var action = original["action"] as? [String: Any] ?? [:]
        action["ai"] = actionModel.isEmpty ? nil : actionModel
        if keep { action = [:] }
        else if trash { action["trash"] = true }
        else {
            action.removeValue(forKey: "trash")
            let folder = destination.trimmingCharacters(in: .whitespaces)
            action["destination"] = folder.isEmpty ? nil : Paths.abbreviate(folder)
            action["rename"] = rename.isEmpty ? nil : rename
            action["tags"] = Self.list(tags).isEmpty ? nil : Self.list(tags)
            if dateFromContent { action["dateFrom"] = "content" }
            else if action["dateFrom"] as? String == "content" { action["dateFrom"] = "file" }
        }
        rule["action"] = action
        return (try? JSONSerialization.data(withJSONObject: rule, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

struct RuleEditorView: View {
    @State var draft: RuleDraft
    let excerpt: String
    let fileName: String?
    let onSave: (RuleDraft) -> Void
    let onCancel: () -> Void
    var availableModels: [String] = []

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text(fileName.map { "New rule from \($0)" } ?? (draft.original.isEmpty ? "New rule" : "Edit rule")).font(.system(size: 22, weight: .semibold, design: .serif))
            field("Name", $draft.name, "Rechnungen")

            Text("Match").font(.subheadline).foregroundStyle(.secondary)
            field("Extensions", $draft.extensions, "pdf, docx")
            field("Filename contains", $draft.filename, "rechnung, invoice")
            field("Text contains", $draft.content, "Rechnungsnummer, Gutschrift")
            field("Downloaded from", $draft.source, "amazon.de")
            Toggle("Tolerate OCR errors", isOn: $draft.fuzzy).padding(.leading, 142)

            DisclosureGroup("More matching options") {
                VStack(spacing: 10) {
                    Picker("Kind", selection: $draft.kind) { Text("Files").tag("file"); Text("Folders").tag("folder"); Text("Files and folders").tag("any") }
                    field("Filename pattern", $draft.filenameRegex, "Regular expression")
                    field("Text contains all", $draft.contentAll, "invoice, paid")
                    field("Text pattern", $draft.contentRegex, "Regular expression")
                    field("Minimum age (days)", $draft.minAge, "0")
                    HStack { field("Min MB", $draft.minSize, "Any"); field("Max MB", $draft.maxSize, "Any") }
                }.padding(.top, 8)
            }
            Text("Action").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("Move to").frame(width: 130, alignment: .trailing)
                HStack {
                    TextField("", text: $draft.destination, prompt: Text("~/Documents/Finanzen/{year}"))
                    Button("Choose…") { choose() }
                }
            }
            .disabled(draft.trash || draft.keep)
            field("Rename to", $draft.rename, "{date}_{name}").disabled(draft.trash || draft.keep)
            field("Tags", $draft.tags, "Rechnung").disabled(draft.trash || draft.keep)
            VStack(alignment: .leading, spacing: 7) {
                    Toggle("Take the date from the document text", isOn: $draft.dateFromContent).disabled(draft.trash || draft.keep)
                    Toggle("Move to Trash instead", isOn: $draft.trash).disabled(draft.keep)
                    Toggle("Keep in place and stop later rules", isOn: $draft.keep)
            }.padding(.leading, 142)

            DisclosureGroup("Model assistance") {
                VStack(alignment: .leading, spacing: 12) {
                    if availableModels.isEmpty && draft.matchModel.isEmpty && draft.actionModel.isEmpty {
                        Text("Add a model in Settings → Models to use these options.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        modelPicker("Choose this rule", selection: $draft.matchModel)
                        if !draft.matchModel.isEmpty { field("Choose when", $draft.modelDescription, "Invoices and receipts for business expenses") }
                        modelPicker("Fill document details", selection: $draft.actionModel).disabled(draft.keep || draft.trash)
                        Text("Plain rules run first. The model can choose this rule or leave a file unmatched. Details include title, correspondent and date. Automatic use is controlled per model in Settings.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 8)
            }

            if !excerpt.isEmpty {
                Text("Document text, for picking keywords").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(excerpt).font(Fonts.mono()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110).padding(6)
                .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("Lists take commas. Templates: {date} {year} {month} {day} {name} {ext} {correspondent} {title}. Advanced JSON settings are preserved.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Document fields: {type} {invoice_number} {amount} {currency} {due_date}. Additional fields use {field.project} for a field named Project. Missing fields wait for Review & file.")
                .font(.caption).foregroundStyle(.secondary)
            if let path = draft.inboxPath { Toggle("Only in " + Paths.abbreviate(path), isOn: $draft.localOnly) }
            ForEach(draft.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.red) }

            HStack {
                if fileName != nil { Toggle("Apply to this file now", isOn: $draft.applyNow) }
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button(draft.original.isEmpty ? "Add rule" : "Save rule") { onSave(draft) }.keyboardShortcut(.defaultAction).disabled(!draft.problems.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 600)
        .background(Palette.paper).tint(Palette.blue)
        }.frame(maxHeight: 760)
    }

    private func field(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 130, alignment: .trailing)
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.destination = Paths.abbreviate(url.path)
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(Array(Set(availableModels + [draft.matchModel, draft.actionModel])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
        }
    }
}

@MainActor
final class RuleEditorController {
    static let shared = RuleEditorController()
    private var window: NSWindow?

    func show(draft: RuleDraft, excerpt: String, fileName: String?, availableModels: [String] = [], onSave: @escaping (RuleDraft) -> Bool) {
        window?.close()
        let view = RuleEditorView(
            draft: draft, excerpt: excerpt, fileName: fileName,
            onSave: { [weak self] draft in
                if onSave(draft) { self?.window?.close() }
            },
            onCancel: { [weak self] in self?.window?.close() }, availableModels: availableModels)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "New rule"
        window.styleMask = [.titled, .closable]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
