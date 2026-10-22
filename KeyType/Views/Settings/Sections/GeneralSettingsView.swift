//
//  GeneralSettingsView.swift
//  KeyType
//
//  The "General" Settings pane: completion length. Split out of SettingsView so each sidebar
//  category lives in its own file.
//

import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLogin.Toggle()
                Text("Start KeyType automatically when you log in to your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Completion length") {
                Picker("Length", selection: $settings.completionLength) {
                    ForEach(CompletionLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                Text("Shorter completions are more conservative; longer ones suggest more at once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("macOS predictions") { // TYLER-INLINEPRED-2026-10-22
                HStack {
                    Text(PermissionsManager.inlinePredictionDefaultEnabled() == false
                         ? "macOS grey predictions are off, so they won't clash with KeyType."
                         : "macOS can draw its own grey predictions on top of KeyType's.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn off macOS predictions") {
                        PermissionsManager.disableSystemInlinePrediction()
                    }
                    .disabled(PermissionsManager.inlinePredictionDefaultEnabled() == false)
                }
            }

            Section("About you") {
                TextEditor(text: $settings.aboutMe)
                    .frame(minHeight: 80)
                    .font(.body)
                Text("Describe who you are and how you write (name, tone, words you use often). KeyType adds this to every prediction so suggestions sound like you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Autocorrect") {
                Toggle("Enable autocorrect suggestions", isOn: $settings.autocorrectSuggestionsEnabled)
                Toggle("Show suggested fixes", isOn: $settings.showSuggestedFixes)
            }
        }
        .formStyle(.grouped)
    }
}
