import AppKit
import SwiftUI

struct ModelDraft: Identifiable {
    let id = UUID()
    var originalName: String?
    var original: [String: Any] = [:]
    var name = ""
    var provider = "openai"
    var endpoint = "https://api.openai.com/v1"
    var model = ""
    var apiKeyFile = ""
    var vision = false
    var automatic = false

    init() {}
    init(name: String, dictionary: [String: Any]) {
        originalName = name; original = dictionary; self.name = name
        provider = dictionary["provider"] as? String ?? "openai"
        endpoint = dictionary["endpoint"] as? String ?? Self.defaultEndpoint(provider)
        model = dictionary["model"] as? String ?? ""
        apiKeyFile = dictionary["apiKeyFile"] as? String ?? ""
        vision = dictionary["vision"] as? Bool ?? false
        automatic = decoded?.runsAutomatically ?? false
    }
    static func defaultEndpoint(_ provider: String) -> String {
        provider == "anthropic" ? "https://api.anthropic.com" : (provider == "apple" ? "" : "https://api.openai.com/v1")
    }
    var dictionary: [String: Any] {
        var result = original
        result["provider"] = provider
        result["endpoint"] = provider == "apple" || endpoint.isEmpty ? nil : endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        result["model"] = provider == "apple" || model.isEmpty ? nil : model.trimmingCharacters(in: .whitespacesAndNewlines)
        result["apiKeyFile"] = provider == "apple" || apiKeyFile.isEmpty ? nil : apiKeyFile
        result["vision"] = provider == "apple" ? false : vision
        result["automatic"] = automatic
        return result
    }
    var decoded: AIModel? {
        guard let data = try? JSONSerialization.data(withJSONObject: original) else { return nil }
        return try? JSONDecoder().decode(AIModel.self, from: data)
    }
    var isLocal: Bool { AIModel(provider: provider, endpoint: endpoint).isLocal }
    var recipient: String {
        if provider == "apple" { return "Apple Intelligence · on your Mac" }
        return URL(string: endpoint)?.host ?? endpoint
    }
    var disclosure: String {
        let data = vision ? "Filenames, document text, and images or scanned pages" : "Filenames and document text"
        if isLocal { return "\(data) go to the model on your Mac when a rule requests it." }
        return "\(data) go to \(recipient) when a rule requests this model. Provider charges may apply."
    }
    mutating func changeProvider(_ value: String) {
        guard value != provider else { return }
        provider = value; changeEndpoint(Self.defaultEndpoint(value))
        model = ""; vision = false; automatic = false
        apiKeyFile = ""; original.removeValue(forKey: "apiKey")
    }
    mutating func changeEndpoint(_ value: String) {
        guard value != endpoint else { return }
        endpoint = value; automatic = false
        apiKeyFile = ""; original.removeValue(forKey: "apiKey")
    }
    func problems(existing: Set<String>) -> [String] {
        var issues: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { issues.append("Give the model a name to use in your rules.") }
        else if originalName != trimmed, existing.contains(trimmed) { issues.append("A model with this name already exists.") }
        if provider != "apple" {
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Enter the model ID supplied by your provider.") }
            if let url = URL(string: endpoint), let host = url.host, !host.isEmpty,
               url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
               ["https", "http"].contains(url.scheme ?? "") {} else {
                issues.append("Enter an HTTP or HTTPS API base URL without credentials, a query or a fragment.")
            }
        }
        return issues
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: ModelDraft?
    @State private var removing: String?
    private var models: [String: [String: Any]] { model.document?.models ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A little help, on your terms.").font(.headline)
                    Text("Let a model choose a rule or fill in document details. External models are manual until you turn on automatic use.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 18)
                Button { editing = ModelDraft() } label: { Label("Add model", systemImage: "plus") }
            }
            if models.isEmpty {
                EmptyState(symbol: "sparkles", title: "Optional by design", detail: "Rules, text recognition and local learning work without a model. Add one when you want help understanding a document.")
            }
            ForEach(models.keys.sorted(), id: \.self) { name in
                let draft = ModelDraft(name: name, dictionary: models[name] ?? [:])
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: draft.isLocal ? "desktopcomputer" : "sparkles").foregroundStyle(Palette.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline)
                            Text(draft.recipient + (draft.model.isEmpty ? "" : " · " + draft.model)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Edit") { editing = draft }
                        Button { removing = name } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove model")
                    }
                    Text(draft.disclosure).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Use automatically when a rule requests this model", isOn: Binding(get: { draft.automatic }, set: { value in
                        model.edit { $0.models[name]?["automatic"] = value }
                    }))
                }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
            }
            Text("Choose a model in Rules → Model assistance. With automatic use off, choose Ask model on a file or explicitly apply a rule. Previews and background text recognition never contact a model.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { draft in
            ModelEditorView(draft: draft, existing: Set(models.keys), onSave: { draft in
                model.edit { $0.models[draft.name.trimmingCharacters(in: .whitespacesAndNewlines)] = draft.dictionary }
                editing = nil
            }, onCancel: { editing = nil })
        }
        .alert("Remove \(removing ?? "model")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let name = removing { model.edit { $0.models.removeValue(forKey: name) } }
                removing = nil
            }
        } message: { Text("Update any rules that use this model before saving your settings.") }
    }
}

struct ModelEditorView: View {
    @State var draft: ModelDraft
    let existing: Set<String>
    let onSave: (ModelDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.originalName == nil ? "Add a model" : "Edit model").font(.system(size: 24, weight: .semibold, design: .serif))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { Text("Name"); TextField("Name used in your rules", text: $draft.name).disabled(draft.originalName != nil) }
                GridRow {
                    Text("Provider")
                    Picker("Provider", selection: Binding(get: { draft.provider }, set: { draft.changeProvider($0) })) {
                        Text("OpenAI-compatible API").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Apple Intelligence · on-device").tag("apple")
                    }.labelsHidden()
                }
                if draft.provider != "apple" {
                    GridRow { Text("API base URL"); TextField("https://…/v1", text: Binding(get: { draft.endpoint }, set: { draft.changeEndpoint($0) })) }
                    GridRow { Text("Model ID"); TextField("From your provider or local server", text: $draft.model) }
                    GridRow {
                        Text("API key file")
                        HStack {
                            TextField("Optional for local servers", text: Binding(get: { draft.apiKeyFile }, set: { draft.apiKeyFile = $0; draft.original.removeValue(forKey: "apiKey") }))
                            Button("Choose…") { chooseKey() }
                        }
                    }
                }
            }.textFieldStyle(.roundedBorder)
            if draft.provider == "apple" {
                Text("Requires macOS 26 and Apple Intelligence enabled on this Mac. Supports document text.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(draft.original["apiKey"] != nil ? "The API key in your configuration is preserved. Choosing a key file replaces it." : "Choose a plain text file containing only your API key. Changing the provider or URL clears the key and resets automatic use.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Send images and scanned pages to this model", isOn: Binding(get: { draft.vision }, set: { if $0 && !draft.vision { draft.automatic = false }; draft.vision = $0 }))
                Text("Enable only if the model accepts images.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use automatically when a rule requests this model", isOn: $draft.automatic)
                Text(draft.disclosure).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            ForEach(draft.problems(existing: existing), id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.red) }
            HStack {
                Text("Applies after saving Settings").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(draft.originalName == nil ? "Add model" : "Done") { onSave(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!draft.problems(existing: existing).isEmpty)
            }
        }.padding(24).frame(width: 590).background(Palette.paper).tint(Palette.blue)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.prompt = "Use key file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.apiKeyFile = Paths.abbreviate(url.path)
        draft.original.removeValue(forKey: "apiKey")
    }
}
