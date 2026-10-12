import SwiftUI

struct SettingsView: View {
    let app: AppState
    var body: some View {
        @Bindable var store = app.settingsStore
        Form {
            Section("Video") {
                Picker("Resolution", selection: $store.settings.resolution) {
                    ForEach(VideoResolution.allCases, id: \.self) { resolution in Text(resolution.title).tag(resolution) }
                }
                Picker("Frame Rate", selection: $store.settings.frameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                Toggle("Show Cursor", isOn: $store.settings.showsCursor)
            }
            Section("Audio") {
                Toggle("Record System Audio", isOn: $store.settings.systemAudio)
                Toggle("Record Microphone", isOn: $store.settings.microphone)
                Picker("Microphone Device", selection: $store.settings.microphoneDeviceID) {
                    Text("System Default").tag(String?.none)
                    ForEach(app.microphoneDevices) { device in Text(device.name).tag(Optional(device.id)) }
                    if let selected = store.settings.microphoneDeviceID, !app.microphoneDevices.contains(where: { $0.id == selected }) {
                        Text("Disconnected Device").tag(Optional(selected))
                    }
                }.disabled(!store.settings.microphone)
                Button("Refresh Devices", action: app.refreshMicrophones).font(.caption)
                Text("Window mode records the selected app's audio, including its other windows. Microphone permission is requested when recording starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                Picker("Countdown", selection: $store.settings.countdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Save Location")
                        Text(store.settings.saveFolder).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { app.chooseFolder() }
                }
                Toggle("Open Folder After Recording", isOn: $store.settings.openFolderAfterRecording)
            }
            if app.coordinator.state.isBusy {
                Text("Changes apply to the next recording. The current recording keeps its original settings.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .frame(width: 540, height: 555)
        .onAppear { app.refreshMicrophones() }
    }
}
