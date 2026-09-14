import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var legalPage: LegalPage?

    var body: some View {
        NavigationStack {
            SettingsContent(
                model: model,
                legalPage: $legalPage
            )
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { dismiss() }
                }
            }
            .navigationDestination(item: $legalPage) { LegalPageView(page: $0) }
        }
    }
}

private struct SettingsContent: View {
    @ObservedObject var model: AppModel
    @Binding var legalPage: LegalPage?

    private let interfaceLanguages: [(String, String)] = [
        ("system", "settings.system_default"),
        ("en", "settings.language.english"),
        ("zh-Hans", "settings.language.simplified_chinese"),
        ("ja", "settings.language.japanese"),
        ("fr", "settings.language.french"),
        ("de", "settings.language.german"),
        ("es", "settings.language.spanish"),
        ("it", "settings.language.italian"),
        ("pt", "settings.language.portuguese"),
        ("ko", "settings.language.korean")
    ]

    var body: some View {
        Form {
            Section("settings.section.app") {
                Picker(
                    L10n.text("settings.interface_language"),
                    selection: Binding(
                        get: { model.interfaceLanguagePreference },
                        set: { model.setInterfaceLanguagePreference($0) }
                    )
                ) {
                    ForEach(interfaceLanguages, id: \.0) { item in
                        Text(LocalizedStringKey(item.1)).tag(item.0)
                    }
                }
            }

            Section("iCloud Backup") {
                Toggle(
                    "Back Up to iCloud",
                    isOn: Binding(
                        get: { model.iCloudBackupEnabled },
                        set: { model.setICloudBackupEnabled($0) }
                    )
                )
                LabeledContent("Status", value: model.iCloudBackup.status.text)
                if model.iCloudBackupEnabled {
                    Button("Sync Now") { Task { await model.syncICloudNow() } }
                }
                Text("Backs up favorites and language settings. Your movie database is never uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.privacy_legal") {
                pageRow(.privacy)
                pageRow(.terms)
            }

            Section("settings.section.support") {
                pageRow(.help)
                pageRow(.about)
                LabeledContent(L10n.text("settings.app_version"), value: appVersion)
            }
        }
    }

    private func pageRow(_ page: LegalPage) -> some View {
        Link(destination: page.externalURL) {
            HStack {
                Text(page.title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
