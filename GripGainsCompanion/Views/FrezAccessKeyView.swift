import SwiftUI

struct FrezAccessKeyView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link("Open Frez Developer Dashboard", destination: URL(string: "https://developers.frez.app/en")!)
                    Text("Sign in to Frez, enroll in its Developer Program, and copy your personal access key.")
                    Link("Frez Developer Agreement", destination: URL(string: "https://developers.frez.app/en/policy")!)
                } header: {
                    Text("Your Frez account")
                } footer: {
                    Text("Frez controls API access and device limits. Each user must use their own key.")
                }

                Section {
                    if bluetoothManager.hasFrezAccessKey {
                        Label("Access key saved on this iPhone", systemImage: "checkmark.shield")
                    }
                    SecureField(bluetoothManager.hasFrezAccessKey ? "Paste replacement access key" : "Paste access key", text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!bluetoothManager.canEditFrezAccessKey)

                    Button(bluetoothManager.hasFrezAccessKey ? "Replace Key" : "Save Key") {
                        do {
                            try bluetoothManager.saveFrezAccessKey(key)
                            key = ""
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bluetoothManager.canEditFrezAccessKey)

                    if bluetoothManager.hasFrezAccessKey {
                        Button("Remove Saved Key", role: .destructive) { showDeleteConfirmation = true }
                            .disabled(!bluetoothManager.canEditFrezAccessKey)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                } header: {
                    Text("Personal access key")
                } footer: {
                    Text(bluetoothManager.canEditFrezAccessKey
                         ? "Stored in iOS Keychain on this device. Your key and Dyno serial are sent only to Frez to retrieve calibration when connecting. The key is verified when you connect a Dyno."
                         : "Disconnect your Frez Dyno before changing or removing its key.")
                }

                Section {
                    Text("Internet access is required each time you connect. Keep the Dyno unloaded until zeroing is complete.")
                    Text("Calibration is provided by Frez's official API. Readings may differ slightly from the Frez app.")
                } footer: {
                    Text("Unofficial app — not affiliated with or endorsed by Frez.")
                }
            }
            .navigationTitle("Frez API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { key = ""; dismiss() }
                }
            }
            .confirmationDialog("Remove your saved Frez access key?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Remove Key", role: .destructive) {
                    do {
                        try bluetoothManager.deleteFrezAccessKey()
                        key = ""
                        errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .onDisappear { key = "" }
    }
}
