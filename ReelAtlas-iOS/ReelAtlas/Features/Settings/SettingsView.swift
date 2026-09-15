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
        ("en", "settings.language.english"),
        ("zh-Hans", "settings.language.simplified_chinese")
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

            Section("Movie Cache") {
                LabeledContent("Stored on this device", value: cacheSizeText)
                Button("Clear Movie Cache", role: .destructive) {
                    Task { await model.clearMovieCache() }
                }
                Text("Movie details and posters are kept for up to 30 days with a shared 150 MiB limit. Story locations, favorites, and preferences are not removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { model.refreshMovieCacheSize() }

            Section("settings.section.privacy_legal") {
                pageRow(.privacy)
                pageRow(.terms)
            }

            Section("settings.section.sources") {
                pageRow(.sources)
                pageRow(.tmdb)
            }

            Section("settings.section.support") {
                pageRow(.help)
                pageRow(.about)
            }
        }
    }

    @ViewBuilder
    private func pageRow(_ page: LegalPage) -> some View {
        if page.isLocal {
            Button { legalPage = page } label: {
                rowLabel(page)
            }
            .buttonStyle(.plain)
        } else {
            Link(destination: page.externalURL) {
                rowLabel(page)
            }
        }
    }

    private func rowLabel(_ page: LegalPage) -> some View {
        HStack {
            Text(page.title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }

    private var cacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: model.movieCacheBytes, countStyle: .file)
    }
}
