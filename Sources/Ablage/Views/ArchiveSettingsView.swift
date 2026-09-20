import AppKit
import SwiftUI

struct ArchiveSettingsView: View {
    @ObservedObject var model: SettingsModel
    private var folders: [String] { model.document?.root["archiveFolders"] as? [String] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Search your document folders").font(.headline)
            Text("New filings are indexed automatically. Add existing folders to search their contents too. Files stay where they are.").foregroundStyle(.secondary)
            HStack {
                Button("Add folder…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { add(panel.urls.map { Paths.abbreviate($0.path) }) }
                }
                Button("Add my filing destinations") {
                    do {
                        guard let data = try model.document?.encoded() else { return }
                        let config = try JSONDecoder().decode(Config.self, from: data)
                        let candidates = config.resolvedInboxes.flatMap { inbox in
                            ((inbox.rules ?? []) + config.rules).compactMap { rule -> String? in
                                guard let destination = rule.action.destination else { return nil }
                                let root = Template.destinationRoot(destination, inbox: URL(fileURLWithPath: Paths.expand(inbox.path)))
                                guard root.path != "/", !FileIdentity.same(root, Paths.home) else { return nil }
                                return Paths.abbreviate(root.path)
                            }
                        }
                        add(candidates)
                    } catch { model.error = error.localizedDescription }
                }
            }
            ForEach(folders, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(Palette.green)
                    Text(path).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button { model.edit { $0.root["archiveFolders"] = folders.filter { $0 != path } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Stop discovering new documents in this folder")
                }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("After saving, open Archive and refresh the index. Read scans and refresh also runs on-device OCR for scans without a text layer.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Keep original documents forever", isOn: model.option("keepOriginalsForever", fallback: false))
            Text("Preserve a separate copy of each newly filed or indexed document. Copies stay in Ablage’s Application Support folder and use additional disk space. You can export them from Archive. Turning this off stops making new copies; preserved copies remain.").font(.callout).foregroundStyle(.secondary)
            Text("Without this option, originals of PDFs rewritten for OCR are kept for \(model.document?.root["originalsDays"] as? Int ?? 30) days for Undo. Integrity checks compare files against a recorded checksum; intentional edits can be accepted explicitly.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func add(_ paths: [String]) {
        var result = folders
        for path in paths where !result.contains(where: { FileIdentity.same(URL(fileURLWithPath: Paths.expand($0)), URL(fileURLWithPath: Paths.expand(path))) }) { result.append(path) }
        model.edit { $0.root["archiveFolders"] = result }
    }
}
