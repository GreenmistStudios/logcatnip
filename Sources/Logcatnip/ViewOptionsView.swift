import LogcatKit
import SwiftUI

extension LogViewOptions.Preset {
    var menuTitle: String {
        switch self {
        case .standard: "Standard"
        case .compact: "Compact"
        }
    }
}

/// A picker over the presets. Options that match neither add a "Custom" entry, which is shown but cannot
/// be chosen: choosing a preset again is how a Custom view goes back to a known one.
struct PresetPicker: View {
    let title: String
    @Binding var options: LogViewOptions

    var body: some View {
        Picker(title, selection: Binding(
            get: { options.preset },
            set: { if let preset = $0 { options.apply(preset) } }
        )) {
            ForEach(LogViewOptions.Preset.allCases, id: \.self) { preset in
                Text(preset.menuTitle).tag(Optional(preset))
            }
            if options.preset == nil {
                Text("Custom").tag(Optional<LogViewOptions.Preset>.none)
            }
        }
    }
}

/// The presets as menu items, with a checkmark on the active one. The View menu and the toolbar's More
/// menu share it. Choosing the active preset again restores it, which is how a Custom view resets. A preset
/// keeps the layout, so it picks the fields of a card as it picks the columns of the table.
struct ViewPresetMenuItems: View {
    let session: LogSession?

    var body: some View {
        ForEach(LogViewOptions.Preset.allCases, id: \.self) { preset in
            Toggle(preset.menuTitle, isOn: Binding(
                get: { session?.viewOptions.preset == preset },
                set: { _ in session?.viewOptions.apply(preset) }
            ))
        }
        Toggle("Custom", isOn: .constant(session.map { $0.viewOptions.preset == nil } ?? false))
            .disabled(true)
    }
}

/// Switches the session between the column table and one card per entry. The View menu and the toolbar's
/// More menu share it.
struct CardLayoutToggle: View {
    let session: LogSession?

    var body: some View {
        Toggle("Card Layout", isOn: Binding(
            get: { session?.viewOptions.layout == .cards },
            set: { session?.viewOptions.layout = $0 ? .cards : .table }
        ))
    }
}

private extension TimestampStyle {
    var displayName: String {
        switch self {
        case .dateTime: "Date and time"
        case .time: "Time"
        case .epoch: "Epoch seconds"
        case .sinceStart: "Since session start"
        case .delta: "Delta from previous line"
        }
    }
}

/// The settings behind Modify View and the default in Settings: what each column shows. It edits the
/// options live, so whatever shows them (a session's table) follows every change.
struct ViewOptionsForm: View {
    @Binding var options: LogViewOptions

    var body: some View {
        Form {
            Section {
                PresetPicker(title: "Preset", options: $options)
                    .pickerStyle(.segmented)
                Picker("Layout", selection: $options.layout) {
                    Text("Table").tag(LogLayout.table)
                    Text("Cards").tag(LogLayout.cards)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    "Cards show each entry with its level, tag and time on top, the message below, and the PID, TID "
                        + "and package underneath. The fields follow the columns you show; presets keep the layout. "
                        + "Widths and Hide repeated apply to the table."
                )
            }

            Section("Timestamp") {
                Toggle("Show", isOn: visible(.time))
                Picker("Format", selection: $options.timestampStyle) {
                    ForEach(TimestampStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .disabled(!options.isVisible(.time))
                Picker("Time zone", selection: $options.timeZone) {
                    Text("Local").tag(TimestampZone.local)
                    Text("UTC").tag(TimestampZone.utc)
                }
                .pickerStyle(.segmented)
                .disabled(!options.isVisible(.time) || !(options.timestampStyle == .dateTime || options.timestampStyle == .time))
            }

            Section("Process and thread") {
                Toggle("Show PID", isOn: visible(.pid))
                Picker("Format", selection: $options.pidStyle) {
                    Text("PID").tag(PidStyle.pid)
                    Text("PID-TID").tag(PidStyle.pidTid)
                }
                .pickerStyle(.segmented)
                .disabled(!options.isVisible(.pid))
            }

            Section("Tag") {
                Toggle("Show", isOn: visible(.tag))
                widthStepper(.tag)
                Toggle("Hide repeated", isOn: $options.hideRepeatedTags)
                    .disabled(!options.isVisible(.tag))
                Toggle("Color tags", isOn: $options.colorTags)
                    .disabled(!options.isVisible(.tag))
            }

            Section("Package") {
                Toggle("Show", isOn: visible(.package))
                widthStepper(.package)
                Toggle("Hide repeated", isOn: $options.hideRepeatedPackages)
                    .disabled(!options.isVisible(.package))
            }

            Section {
                Toggle("Show", isOn: visible(.process))
                widthStepper(.process)
                Toggle("Hide repeated", isOn: $options.hideRepeatedProcesses)
                    .disabled(!options.isVisible(.process))
            } header: {
                Text("Process")
            } footer: {
                Text("The full process name, such as com.example.app:remote. Package shows the part before the colon.")
            }

            Section("Level") {
                Toggle("Show", isOn: visible(.level))
            }
        }
        .formStyle(.grouped)
    }

    private func visible(_ column: LogColumn) -> Binding<Bool> {
        Binding(get: { options.isVisible(column) }, set: { options.setVisible(column, $0) })
    }

    @ViewBuilder
    private func widthStepper(_ column: LogColumn) -> some View {
        let characters = options.width(of: column) ?? 0
        Stepper(
            value: Binding(get: { characters }, set: { options.setWidth($0, of: column) }),
            in: LogViewOptions.widthRange
        ) {
            Text("Width: \(characters) characters")
        }
        .disabled(!options.isVisible(column))
    }
}

/// View › Modify View…: the session's view options, applied as they change.
struct ModifyViewSheet: View {
    @Bindable var session: LogSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.defaultViewOptions) private var savedDefault = ""

    var body: some View {
        VStack(spacing: 0) {
            ViewOptionsForm(options: $session.viewOptions)
            Divider()
            HStack {
                Button("Use as Default for New Sessions") {
                    Defaults.setViewOptions(session.viewOptions)
                }
                .disabled(session.viewOptions == (LogViewOptions(json: savedDefault) ?? .standard))
                .help("Sessions opened from now on start with this view")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 620)
    }
}
