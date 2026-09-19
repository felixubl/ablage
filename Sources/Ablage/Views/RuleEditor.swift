import AppKit
import SwiftUI

struct RuleDraft {
    var name = ""
    var extensions = ""
    var filename = ""
    var content = ""
    var source = ""
    var destination = ""
    var rename = ""
    var dateFromContent = false
    var tags = ""
    var trash = false
    var applyNow = true

    static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var problems: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the rule a name.") }
        if [extensions, filename, content, source].allSatisfy({ Self.list($0).isEmpty }) {
            out.append("Add at least one match criterion.")
        }
        let destinationEmpty = destination.trimmingCharacters(in: .whitespaces).isEmpty
        if !trash, destinationEmpty, rename.trimmingCharacters(in: .whitespaces).isEmpty, Self.list(tags).isEmpty {
            out.append("Choose a destination, a rename template, tags, or Trash.")
        }
        return out
    }

    /// The rule as it will appear in config.json, formatted like the defaults.
    var json: String {
        func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + "\""
        }
        func array(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ", ") + "]" }

        var match: [String] = []
        let exts = Self.list(extensions).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
        if !exts.isEmpty { match.append("\"extensions\": \(array(exts))") }
        if !Self.list(filename).isEmpty { match.append("\"filename\": \(array(Self.list(filename)))") }
        if !Self.list(content).isEmpty { match.append("\"content\": \(array(Self.list(content)))") }
        if !Self.list(source).isEmpty { match.append("\"source\": \(array(Self.list(source)))") }

        var action: [String] = []
        if trash {
            action.append("\"trash\": true")
        } else {
            let folder = destination.trimmingCharacters(in: .whitespaces)
            if !folder.isEmpty { action.append("\"destination\": \(quote(Paths.abbreviate(folder)))") }
            let template = rename.trimmingCharacters(in: .whitespaces)
            if !template.isEmpty { action.append("\"rename\": \(quote(template))") }
            if dateFromContent { action.append("\"dateFrom\": \"content\"") }
            if !Self.list(tags).isEmpty { action.append("\"tags\": \(array(Self.list(tags)))") }
        }
        return """
            {
              "name": \(quote(name.trimmingCharacters(in: .whitespaces))),
              "match": { \(match.joined(separator: ", ")) },
              "action": { \(action.joined(separator: ", ")) }
            }
            """
    }
}

struct RuleEditorView: View {
    @State var draft: RuleDraft
    let excerpt: String
    let fileName: String?
    let onSave: (RuleDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fileName.map { "New rule from \($0)" } ?? "New rule").font(.headline)
            field("Name", $draft.name, "Rechnungen")

            Text("Match").font(.subheadline).foregroundStyle(.secondary)
            field("Extensions", $draft.extensions, "pdf, docx")
            field("Filename contains", $draft.filename, "rechnung, invoice")
            field("Text contains", $draft.content, "Rechnungsnummer, Gutschrift")
            field("Downloaded from", $draft.source, "amazon.de")

            Text("Action").font(.subheadline).foregroundStyle(.secondary)
            LabeledContent("Move to") {
                HStack {
                    TextField("", text: $draft.destination, prompt: Text("~/Documents/Finanzen/{year}"))
                    Button("Choose…") { choose() }
                }
            }
            .disabled(draft.trash)
            field("Rename to", $draft.rename, "{date}_{name}").disabled(draft.trash)
            field("Tags", $draft.tags, "Rechnung").disabled(draft.trash)
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Take the date from the document text", isOn: $draft.dateFromContent).disabled(draft.trash)
                    Toggle("Move to Trash instead", isOn: $draft.trash)
                }
            }

            if !excerpt.isEmpty {
                Text("Document text, for picking keywords").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(excerpt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110).padding(6)
                .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("Lists take commas. Templates: {date} {year} {month} {day} {name} {ext} {correspondent} {title}. The rule goes to the end of the shared rules.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(draft.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }

            HStack {
                if fileName != nil { Toggle("Apply to this file now", isOn: $draft.applyNow) }
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add rule") { onSave(draft) }.keyboardShortcut(.defaultAction).disabled(!draft.problems.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 560)
    }

    private func field(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        LabeledContent(label) { TextField("", text: text, prompt: Text(prompt)) }
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
}

@MainActor
final class RuleEditorController {
    static let shared = RuleEditorController()
    private var window: NSWindow?

    func show(draft: RuleDraft, excerpt: String, fileName: String?, onSave: @escaping (RuleDraft) -> Void) {
        window?.close()
        let view = RuleEditorView(
            draft: draft, excerpt: excerpt, fileName: fileName,
            onSave: { [weak self] draft in
                onSave(draft)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "New rule"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
