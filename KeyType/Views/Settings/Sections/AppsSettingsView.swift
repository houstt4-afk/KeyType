//
//  AppsSettingsView.swift
//  KeyType
//
//  The "Apps" Settings pane: per-app completion toggles for the currently running apps. Split out of
//  SettingsView so each sidebar category lives in its own file.
//

import AppKit
import SwiftUI

struct AppsSettingsView: View {
    @Bindable var settings: SettingsStore
    let addApp: () -> Void

    @State private var detectedApps: [AppListItem] = []

    private var listedApps: [AppListItem] {
        Self.mergeApps(
            detectedApps: detectedApps,
            manualAppDisplayNames: settings.manualPerAppDisplayNames
        )
    }

    var body: some View {
        Form {
            Section("Per-app completions") {
                if listedApps.isEmpty {
                    Text("No apps detected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(listedApps) { app in
                    HStack {
                        Toggle(app.name, isOn: Binding(
                            get: { settings.isAppEnabled(app.bundleIdentifier) },
                            set: { settings.setApp(app.bundleIdentifier, enabled: $0) }
                        ))
                        Picker("Length", selection: Binding(
                            get: { settings.perAppCompletionLength[app.bundleIdentifier] ?? "default" },
                            set: { newValue in
                                if newValue == "default" {
                                    settings.perAppCompletionLength.removeValue(forKey: app.bundleIdentifier)
                                } else {
                                    settings.perAppCompletionLength[app.bundleIdentifier] = newValue
                                }
                            }
                        )) {
                            Text("Default").tag("default")
                            ForEach(CompletionLength.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    } // TYLER-PERAPP-2026-10-22
                }

                HStack(spacing: 8) {
                    Button("Add app", action: addApp)
                    Button("Refresh app list") { refreshDetectedApps() }
                }
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .task { refreshDetectedApps() }
    }

    private func refreshDetectedApps() {
        detectedApps = Self.loadRunningApps()
    }

    private static func mergeApps(
        detectedApps: [AppListItem],
        manualAppDisplayNames: [String: String]
    ) -> [AppListItem] {
        var appsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: detectedApps.map { ($0.bundleIdentifier, $0) }
        )

        for (bundleIdentifier, name) in manualAppDisplayNames where appsByBundleIdentifier[bundleIdentifier] == nil {
            appsByBundleIdentifier[bundleIdentifier] = AppListItem(
                bundleIdentifier: bundleIdentifier,
                name: name
            )
        }

        return appsByBundleIdentifier.values.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    private static func loadRunningApps() -> [AppListItem] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { (app: NSRunningApplication) -> AppListItem? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return AppListItem(bundleIdentifier: bundleID, name: app.localizedName ?? bundleID)
            }
            .reduce(into: [AppListItem]()) { acc, app in
                if !acc.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    acc.append(app)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct AppListItem: Identifiable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier }
    }
}
