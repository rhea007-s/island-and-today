import SwiftUI

struct SettingsView: View {
    @Bindable var model: IslandModel
    @State private var launchAtLogin = false

    private var settings: IslandSettings { model.settings }

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Appearance") {
                IslandStylePicker(selection: $settings.style, accent: settings.accent.color)
                    .padding(.vertical, 4)
                Picker("Accent", selection: $settings.accent) {
                    ForEach(IslandAccent.allCases) { accent in
                        HStack {
                            Circle().fill(accent.color).frame(width: 10, height: 10)
                            Text(accent.rawValue.capitalized)
                        }
                        .tag(accent)
                    }
                }
                Toggle("Open a preview when the pointer reaches the notch", isOn: $settings.hoverToPeek)
                Toggle("Show music in the notch while it plays", isOn: $settings.showMusicInCompact)
                Toggle("Haptic feedback on the trackpad", isOn: $settings.haptics)
            }

            Section {
                if !model.geometry.hasNotch {
                    slider("Resting length", $settings.pillWidth, 120...360)
                    slider("Resting height", $settings.pillHeight, 24...44)
                }
                slider("Side wings", $settings.wingWidth, 50...140)
                slider("Open width", $settings.expandedWidth, 460...820)
                slider("Open height", $settings.expandedHeight, 200...420)
                slider("Roundness", $settings.roundness, 12...44)
                HStack {
                    Button("Preview open island") { model.open() }
                    Spacer()
                    Button("Reset size") { settings.resetSize() }
                }
            } header: {
                Text("Size")
            } footer: {
                Text("Changes show on the island right away.")
            }

            Section("Calendar") {
                Toggle("Show today's events in the island", isOn: $settings.showCalendar)
                Stepper("Count down \(settings.remindMinutes) min before an event", value: $settings.remindMinutes, in: 1...60)
                    .onChange(of: settings.remindMinutes) { model.calendar.reload() }
                if model.calendar.access != .granted {
                    Button("Allow calendar access") { model.calendar.requestAccess() }
                }
            }

            Section {
                SyncView()
            } header: {
                Text("Sync with iPhone")
            }

            Section("Focus") {
                Stepper("Focus length: \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Break length: \(settings.breakMinutes) min", value: $settings.breakMinutes, in: 1...30)
                Toggle("Start the break automatically", isOn: $settings.autoStartBreak)
            }

            Section("Clipboard") {
                Toggle("Keep a clipboard history", isOn: $settings.clipboardEnabled)
                    .onChange(of: settings.clipboardEnabled) { _, on in
                        on ? model.clipboard.start() : model.clipboard.stop()
                    }
                Text("Text only, last 30 items, never saved to disk. Copies marked secret by password managers are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Island at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in settings.launchAtLogin = on }
                LabeledContent("This Mac", value: "\(model.system.mac.chip) · \(model.system.mac.model)")
                LabeledContent("Display", value: model.geometry.hasNotch ? "Notch, \(Int(model.geometry.notchSize.width)) pt wide" : "No notch — floating pill")
                Button("Quit Island") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.visible)
        .frame(width: 460)
        .frame(minHeight: 520)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 2)
                    .frame(width: 200)
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
