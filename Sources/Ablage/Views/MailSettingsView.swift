import SwiftUI

struct MailSettingsView: View {
    @ObservedObject var model: SettingsModel
    private var accounts: [MailAccount] {
        guard let raw = model.document?.root["mailAccounts"], let data = try? JSONSerialization.data(withJSONObject: raw) else { return [] }
        return (try? JSONDecoder().decode([MailAccount].self, from: data)) ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A home for email attachments").font(.headline)
                    Text("Read a mail folder over encrypted IMAP and deliver attachments to an inbox.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add account") {
                    var account = MailAccount()
                    account.inbox = model.document?.inboxes.first?["path"] as? String ?? "~/Downloads"
                    update(accounts + [account])
                }
            }
            Text("Use your provider’s IMAP hostname and an app password where required. Credentials are stored in macOS Keychain. Messages are never marked as read, moved or deleted.").font(.caption).foregroundStyle(.secondary)
            Text("The first fetch includes existing messages in the chosen folder, 30 emails at a time. Use a dedicated folder for documents you want to import.").font(.caption).foregroundStyle(.secondary)
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Account name", text: binding(account.id, \.name)).font(.headline)
                        Toggle("Fetch automatically", isOn: binding(account.id, \.enabled)).toggleStyle(.switch).controlSize(.small)
                        Button { update(accounts.filter { $0.id != account.id }) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove account")
                    }
                    HStack {
                        TextField("IMAP host, e.g. imap.example.com", text: binding(account.id, \.host))
                        TextField("Port", value: binding(account.id, \.port), format: .number.grouping(.never)).frame(width: 70)
                    }
                    TextField("Username / email address", text: binding(account.id, \.username))
                    SecureField("App password · leave blank to keep the saved password", text: Binding(get: { model.mailPasswords[account.id] ?? "" }, set: { model.mailPasswords[account.id] = $0; model.dirty = true }))
                    TextField("Mail folder, e.g. INBOX or Receipts", text: binding(account.id, \.folder))
                    Picker("Deliver into", selection: binding(account.id, \.inbox)) {
                        ForEach(Array((model.document?.inboxes ?? []).enumerated()), id: \.offset) { _, inbox in
                            Text(inbox["name"] as? String ?? inbox["path"] as? String ?? "").tag(inbox["path"] as? String ?? "")
                        }
                    }
                    HStack {
                        Stepper("Every \(account.intervalMinutes) minutes", value: binding(account.id, \.intervalMinutes), in: 1...1440)
                        Spacer()
                        Stepper("Up to \(account.maxMessageMB) MB per email", value: binding(account.id, \.maxMessageMB), in: 1...100)
                    }.font(.callout)
                    TextField("Attachment extensions, e.g. pdf, jpg", text: Binding(get: { account.extensions.joined(separator: ", ") }, set: { value in change(account.id) { $0.extensions = RuleDraft.list(value) } }))
                    HStack {
                        Button("Test connection") {
                            model.mailTests[account.id] = "Connecting…"
                            let entered = model.mailPasswords[account.id]
                            Task {
                                do {
                                    let result = try await Task.detached {
                                        let password = try entered.flatMap { $0.isEmpty ? nil : $0 } ?? MailKeychain.read(account.credentialKey)
                                        return try MailIngestor.test(account, password: password)
                                    }.value
                                    model.mailTests[account.id] = result
                                } catch { model.mailTests[account.id] = error.localizedDescription }
                            }
                        }.disabled(model.mailTests[account.id] == "Connecting…")
                        Button("Fetch now") { MailIngestor.shared.fetchNow(account) }.disabled(model.dirty).help("Save account changes before fetching")
                        Spacer()
                    }
                    if let message = model.mailTests[account.id] { Text(message).font(.caption).textSelection(.enabled) }
                    Text(MailIngestor.shared.status(account.id)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.textFieldStyle(.roundedBorder).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if accounts.isEmpty { EmptyState(symbol: "envelope", title: "Receipts can arrive on their own", detail: "Choose a dedicated mail folder and a destination inbox. Enable Review first on that inbox to approve each attachment.") }
        }.onReceive(NotificationCenter.default.publisher(for: .ablageMailStatus)) { _ in model.objectWillChange.send() }
    }
    private func update(_ accounts: [MailAccount]) {
        guard let data = try? JSONEncoder().encode(accounts), let object = try? JSONSerialization.jsonObject(with: data) else { return }
        model.edit { $0.root["mailAccounts"] = object }
    }
    private func change(_ id: String, _ mutate: (inout MailAccount) -> Void) {
        var values = accounts
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        mutate(&values[index]); update(values)
    }
    private func binding<T>(_ id: String, _ key: WritableKeyPath<MailAccount, T>) -> Binding<T> {
        Binding(get: { (accounts.first { $0.id == id } ?? MailAccount())[keyPath: key] }, set: { value in change(id) { $0[keyPath: key] = value } })
    }
}
