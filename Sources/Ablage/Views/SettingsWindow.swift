import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published var document: ConfigDocument?
    @Published var error: String?
    @Published var dirty = false
    @Published var notice: String?
    @Published var mailPasswords: [String: String] = [:]
    @Published var mailTests: [String: String] = [:]
    @Published var section = "inboxes"

    init() { reload() }
    init(document: ConfigDocument) { self.document = document }
    func reload() {
        do { document = try .load(); error = nil; dirty = false; notice = nil; mailPasswords.removeAll(); mailTests.removeAll() }
        catch { self.error = ConfigStore.describe(error) }
    }
    func edit(_ change: (inout ConfigDocument) -> Void) {
        guard var document else { return }
        change(&document)
        self.document = document
        dirty = true
        notice = nil
    }
    func save() {
        do {
            guard var document else { return }
            _ = try document.encoded()
            let configuration = try JSONDecoder().decode(Config.self, from: document.encoded())
            for account in configuration.mailAccounts {
                if let password = mailPasswords[account.id], !password.isEmpty { try MailKeychain.save(password, account: account.credentialKey) }
            }
            try document.save()
            mailPasswords.removeAll()
            self.document = document
            dirty = false
            error = nil
            notice = "Settings saved."
        } catch { self.error = ConfigStore.describe(error) }
    }
    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Review configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ConfigDocument(data: Data(contentsOf: url))
            _ = try imported.encoded()
            edit { $0.root = imported.root }
            error = nil
            notice = "Imported for review. Save to apply this configuration."
        } catch { self.error = ConfigStore.describe(error) }
    }
    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ablage-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try document?.encoded().write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func addInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add inbox"
        guard panel.runModal() == .OK else { return }
        edit { document in
            var folders = document.inboxes
            for url in panel.urls {
                if !folders.contains(where: { URL(fileURLWithPath: Paths.expand($0["path"] as? String ?? "")).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) {
                    folders.append(["path": Paths.abbreviate(url.path), "name": url.lastPathComponent])
                }
            }
            document.inboxes = folders
        }
    }
    func inboxBinding<T>(_ index: Int, _ key: String, fallback: T) -> Binding<T> {
        Binding(get: { self.document?.inboxes[safe: index]?[key] as? T ?? fallback }, set: { value in
            self.edit { document in
                var folders = document.inboxes
                guard folders.indices.contains(index) else { return }
                folders[index][key] = value
                document.inboxes = folders
            }
        })
    }
    func option(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { self.document?.root[key] as? Bool ?? fallback }, set: { value in self.edit { $0.root[key] = value } })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @EnvironmentObject private var state: AppState
    @State private var scope = -1
    @State private var editingRule: RuleEditRequest?
    @State private var removeInbox: Int?
    @State private var deleteRule: Int?

    init(model: SettingsModel, section: String? = nil) { self.model = model; if let section { model.section = section } }

    private var rules: [[String: Any]] { model.document?.rules(in: scope < 0 ? nil : scope) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("A place for everything.").font(.system(size: 24, weight: .semibold, design: .serif)) }
                    Text("Set up once. File with confidence.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Picker("Settings section", selection: $model.section) {
                Text("Inboxes").tag("inboxes")
                Text("Rules").tag("rules")
                Text("Archive").tag("archive")
                Text("Email").tag("email")
                Text("Models").tag("models")
                Text("Preferences").tag("preferences")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 22).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.document != nil {
                        switch model.section {
                        case "rules": rulesSection
                        case "preferences": preferences
                        case "archive": ArchiveSettingsView(model: model)
                        case "email": MailSettingsView(model: model)
                        case "models": ModelSettingsView(model: model)
                        default: inboxesSection
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error { Text(error).font(.callout).foregroundStyle(Palette.red).textSelection(.enabled) }
                if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(Palette.green) }
                HStack {
                    Menu {
                        Button("Import configuration…") { model.importConfig(); scope = -1 }
                        Button("Export configuration…") { model.exportConfig() }
                        Button("Open configuration JSON") { state.openConfig() }
                        Button("Open log") { state.openLog() }
                    } label: { Label("Advanced", systemImage: "ellipsis.circle") }.fixedSize()
                    Spacer()
                    Text(model.dirty ? "Unsaved changes" : "Changes apply after saving").font(.caption).foregroundStyle(.secondary)
                    Button("Reload") { model.reload(); scope = -1 }
                    Button("Save changes") { model.save() }.buttonStyle(.borderedProminent).disabled(!model.dirty).keyboardShortcut("s")
                }
            }.padding(16)
        }
        .background(Palette.paper).tint(Palette.blue)
        .frame(minWidth: 660, minHeight: 580)
        .sheet(item: $editingRule) { request in
            RuleEditorView(draft: RuleDraft(dictionary: request.rule), excerpt: "", fileName: nil,
                onSave: { draft in
                    guard let data = draft.json.data(using: .utf8), let rule = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    model.edit { document in
                        var rules = document.rules(in: request.scope)
                        if let index = request.index { rules[index] = rule } else { rules.append(rule) }
                        document.setRules(rules, in: request.scope)
                    }
                    editingRule = nil
                }, onCancel: { editingRule = nil }, availableModels: Array(model.document?.models.keys ?? [:].keys).sorted())
        }
        .alert("Remove this inbox?", isPresented: Binding(get: { removeInbox != nil }, set: { if !$0 { removeInbox = nil } })) {
            Button("Cancel", role: .cancel) { removeInbox = nil }
            Button("Remove", role: .destructive) {
                if let index = removeInbox { model.edit { $0.inboxes.remove(at: index) }; scope = -1 }
                removeInbox = nil
            }
        } message: { Text("Its files stay where they are. Its local rules will be removed from the configuration when you save.") }
        .alert("Delete this rule?", isPresented: Binding(get: { deleteRule != nil }, set: { if !$0 { deleteRule = nil } })) {
            Button("Cancel", role: .cancel) { deleteRule = nil }
            Button("Delete", role: .destructive) {
                if let index = deleteRule { model.edit { var list = $0.rules(in: scope < 0 ? nil : scope); list.remove(at: index); $0.setRules(list, in: scope < 0 ? nil : scope) } }
                deleteRule = nil
            }
        } message: { Text("Files already filed by this rule stay where they are.") }
    }

    private var inboxesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your inboxes").font(.headline)
                    Text("Downloads, scans, screenshots. Give every arrival a home.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.addInbox() } label: { Label("Add folder…", systemImage: "plus") }
            }
            ForEach(Array((model.document?.inboxes ?? []).enumerated()), id: \.offset) { index, inbox in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.full").font(.title2).foregroundStyle(Palette.green)
                        TextField("Inbox name", text: model.inboxBinding(index, "name", fallback: URL(fileURLWithPath: Paths.expand(inbox["path"] as? String ?? "")).lastPathComponent)).font(.headline).textFieldStyle(.plain)
                        Toggle("Watch", isOn: model.inboxBinding(index, "enabled", fallback: true)).toggleStyle(.switch).controlSize(.small)
                            .help("Automatically file new arrivals. Manual review remains available when off.")
                        Button { removeInbox = index } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            .disabled((model.document?.inboxes.count ?? 0) < 2).help("Remove inbox")
                    }
                    Button(inbox["path"] as? String ?? "") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.expand(inbox["path"] as? String ?? ""))) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    DisclosureGroup("Options") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Review first — wait for my approval", isOn: model.inboxBinding(index, "reviewFirst", fallback: false))
                            Text("New arrivals get a plan, but stay here until you approve or manually sort them.").font(.caption).foregroundStyle(.secondary)
                            TextField("Ignore patterns, separated by commas", text: Binding(
                                get: { (model.document?.inboxes[safe: index]?["ignore"] as? [String] ?? []).joined(separator: ", ") },
                                set: { value in model.edit { $0.inboxes[index]["ignore"] = RuleDraft.list(value) } }))
                                .textFieldStyle(.roundedBorder)
                            Toggle("Include existing files in periodic sorting", isOn: model.inboxBinding(index, "sortExistingOnRescan", fallback: model.document?.root["sortExistingOnRescan"] as? Bool ?? false))
                            Text("Existing files wait for manual review unless this is on. Shared ignore patterns also apply.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.font(.callout)
                }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
            }
            Label("Folders keep their files. Ablage watches new arrivals without importing a library.", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Rules for", selection: $scope) {
                    Text("All inboxes · shared").tag(-1)
                    ForEach(Array((model.document?.inboxes ?? []).enumerated()), id: \.offset) { index, inbox in
                        Text(inbox["name"] as? String ?? inbox["path"] as? String ?? "Inbox").tag(index)
                    }
                }.frame(maxWidth: 350)
                Spacer()
                Button { editingRule = RuleEditRequest(scope: scope < 0 ? nil : scope, index: nil, rule: [:]) } label: { Label("New rule", systemImage: "plus") }
            }
            Text("First match wins. Inbox rules run before shared rules. Move rules up or down to set their priority.").font(.callout).foregroundStyle(.secondary)
            if rules.isEmpty { EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Start with one useful rule", detail: "Match a file type, a name or words inside a document. Choose where it belongs.") }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 10) {
                    Toggle("Enable \(rule["name"] as? String ?? "rule")", isOn: Binding(get: { rule["enabled"] as? Bool ?? true }, set: { value in updateRule(index) { $0["enabled"] = value } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule["name"] as? String ?? "Untitled").font(.headline)
                        Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button { moveRule(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Earlier")
                    Button { moveRule(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == rules.count - 1).help("Later")
                    Button("Edit") { editingRule = RuleEditRequest(scope: scope < 0 ? nil : scope, index: index, rule: rule) }
                    Menu {
                        Button("Duplicate") { model.edit { var list = $0.rules(in: scope < 0 ? nil : scope); var copy = rule; copy["name"] = (rule["name"] as? String ?? "Rule") + " copy"; list.insert(copy, at: index + 1); $0.setRules(list, in: scope < 0 ? nil : scope) } }
                        Button("Delete…", role: .destructive) { deleteRule = index }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Everyday") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch Ablage at login", isOn: $state.launchAtLogin)
                    Toggle("Notify me when files are filed", isOn: model.option("notifications", fallback: true))
                    Text("Launch at login takes effect immediately.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            GroupBox("Documents") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Read scans and images with on-device OCR", isOn: model.option("ocr", fallback: true))
                    Text("Pending document plans read their text in the background. Pause holds the queue; no file is changed.").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Stepper("First \(model.document?.root["ocrPages"] as? Int ?? 2) PDF pages", value: Binding(get: { model.document?.root["ocrPages"] as? Int ?? 2 }, set: { value in model.edit { $0.root["ocrPages"] = value } }), in: 1...500)
                        Stepper("Up to \(Int(model.document?.root["ocrMaxMB"] as? Double ?? 25)) MB", value: Binding(get: { model.document?.root["ocrMaxMB"] as? Double ?? 25 }, set: { value in model.edit { $0.root["ocrMaxMB"] = value } }), in: 1...1000, step: 5)
                    }.font(.callout).disabled(!(model.document?.root["ocr"] as? Bool ?? true))
                    Toggle("Make filed PDFs searchable", isOn: model.option("searchablePDFs", fallback: true))
                    Toggle("Learn from the files I sort", isOn: Binding(get: { (model.document?.root["learning"] as? [String: Any])?["enabled"] as? Bool ?? true }, set: { value in model.edit { var learning = $0.root["learning"] as? [String: Any] ?? [:]; learning["enabled"] = value; $0.root["learning"] = learning } }))
                    Text("OCR and learning run on your Mac. Remote models only run when explicitly configured and allowed.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            GroupBox("A little breathing room") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Wait \(Int(model.document?.root["settleSeconds"] as? Double ?? 3)) seconds after a file stops changing", value: Binding(get: { model.document?.root["settleSeconds"] as? Double ?? 3 }, set: { value in model.edit { $0.root["settleSeconds"] = value } }), in: 1...60, step: 1)
                    Picker("Periodic sorting", selection: Binding(get: { model.document?.root["rescanMinutes"] as? Double ?? 30 }, set: { value in model.edit { $0.root["rescanMinutes"] = value } })) {
                        Text("Off").tag(0.0); Text("Every 5 minutes").tag(5.0); Text("Every 15 minutes").tag(15.0); Text("Every 30 minutes").tag(30.0); Text("Every hour").tag(60.0)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private func updateRule(_ index: Int, _ change: (inout [String: Any]) -> Void) {
        model.edit { var list = $0.rules(in: scope < 0 ? nil : scope); change(&list[index]); $0.setRules(list, in: scope < 0 ? nil : scope) }
    }
    private func moveRule(_ index: Int, by offset: Int) {
        model.edit { var list = $0.rules(in: scope < 0 ? nil : scope); list.swapAt(index, index + offset); $0.setRules(list, in: scope < 0 ? nil : scope) }
    }
    private func ruleSummary(_ rule: [String: Any]) -> String {
        let match = rule["match"] as? [String: Any] ?? [:]
        let action = rule["action"] as? [String: Any] ?? [:]
        var parts = (match["extensions"] as? [String] ?? []).map { "." + $0 }
        if let terms = match["filename"] as? [String] { parts.append(contentsOf: terms) }
        if let terms = match["content"] as? [String] { parts.append("Text: " + terms.joined(separator: ", ")) }
        let destination = action["trash"] as? Bool == true ? "Trash" : action["destination"] as? String ?? (action.isEmpty ? "Keep in place" : "Rename / tag")
        return (parts.isEmpty ? "Matching files" : parts.joined(separator: " · ")) + " → " + destination
    }
}

struct RuleEditRequest: Identifiable {
    let id = UUID()
    let scope: Int?
    let index: Int?
    let rule: [String: Any]
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()
    private var window: NSWindow?
    private var model: SettingsModel?
    func show(state: AppState, section: String? = nil) {
        if let window, window.isVisible {
            if let section { model?.section = section }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        let model = SettingsModel()
        if let section { model.section = section }
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model).environmentObject(state)))
        window.delegate = self
        window.title = "Ablage · Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 690))
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.dirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes?"
        alert.informativeText = "Your settings haven’t been applied yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Keep editing")
        alert.addButton(withTitle: "Discard changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model?.save(); return model?.dirty == false
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
