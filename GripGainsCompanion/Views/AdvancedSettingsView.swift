import SwiftUI
import Combine

struct AdvancedSettingsView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    let useLbs: Bool
    let canChangeReadingCorrection: Bool
    let onSaveReadingCorrection: (ReadingCorrection, ReadingCorrectionDevice) -> Bool

    @State private var editingDevice: ReadingCorrectionDevice?

    var body: some View {
        List {
            Section {
                Button {
                    editingDevice = bluetoothManager.readingCorrectionDevice
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device reading correction")
                                .foregroundStyle(.primary)
                            if bluetoothManager.readingCorrection.isActive {
                                Text(activeSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(bluetoothManager.connectionState != .connected || bluetoothManager.readingCorrectionDevice == nil)
            } footer: {
                Text(bluetoothManager.connectionState == .connected
                     ? "Adjust readings if your device reports an incorrect scale or offset. Saved for this device."
                     : "Connect a device to adjust its readings if it reports an incorrect scale or offset.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDevice) { device in
            NavigationStack {
                ReadingCorrectionView(
                    bluetoothManager: bluetoothManager,
                    device: device,
                    deviceName: bluetoothManager.connectedDeviceName ?? device.type.displayName,
                    correction: bluetoothManager.readingCorrection,
                    useLbs: useLbs,
                    canChangeReadingCorrection: canChangeReadingCorrection,
                    onSave: onSaveReadingCorrection
                )
            }
        }
    }

    private var activeSummary: String {
        let correction = bluetoothManager.readingCorrection
        let scale = "Active · ×\(correction.multiplierText)"
        guard correction.offsetKg != 0 else { return scale }
        return "\(scale) · offset \(WeightFormatter.format(correction.offsetKg, useLbs: useLbs, decimals: 2))"
    }
}

struct ReadingCorrectionView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    let device: ReadingCorrectionDevice
    let deviceName: String
    let useLbs: Bool
    let canChangeReadingCorrection: Bool
    let onSave: (ReadingCorrection, ReadingCorrectionDevice) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var multiplierText: String
    @State private var offsetText: String
    @State private var reportedForce: Double?
    @State private var showSaveError = false

    init(bluetoothManager: BluetoothManager, device: ReadingCorrectionDevice, deviceName: String,
         correction: ReadingCorrection, useLbs: Bool, canChangeReadingCorrection: Bool,
         onSave: @escaping (ReadingCorrection, ReadingCorrectionDevice) -> Bool) {
        self.bluetoothManager = bluetoothManager
        self.device = device
        self.deviceName = deviceName
        self.useLbs = useLbs
        self.canChangeReadingCorrection = canChangeReadingCorrection
        self.onSave = onSave
        _multiplierText = State(initialValue: correction.multiplierText)
        _offsetText = State(initialValue: correction.offsetText(useLbs: useLbs))
        _reportedForce = State(initialValue: bluetoothManager.latestReportedForce)
    }

    private var draft: ReadingCorrection? {
        ReadingCorrection.parse(multiplier: multiplierText, offset: offsetText, useLbs: useLbs)
    }

    private var isDeviceConnected: Bool {
        bluetoothManager.connectionState == .connected && bluetoothManager.readingCorrectionDevice == device
    }

    private var correctedPreview: Double? {
        guard let reportedForce, isDeviceConnected else { return nil }
        return draft?.apply(to: reportedForce)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Device", value: deviceName)
                HStack {
                    Text("Multiplier")
                    Spacer()
                    TextField("1", text: $multiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Multiplier")
                }
                HStack {
                    Text("Offset (\(useLbs ? "lbs" : "kg"))")
                    Spacer()
                    TextField("0", text: $offsetText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Offset in \(useLbs ? "pounds" : "kilograms")")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Corrected = reported × multiplier + offset")
                    Text("For readings 100× too high, use a multiplier of 0.01 and an offset of 0.")
                    if draft == nil {
                        Text("Enter a positive multiplier and a numeric offset. Decimals may use a dot or comma.")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Live preview") {
                LabeledContent("Reported", value: formatted(isDeviceConnected ? reportedForce : nil))
                LabeledContent("Corrected", value: formatted(correctedPreview))
                if let draft {
                    Text("Corrected = reported × \(draft.multiplierText) + (\(draft.offsetText(useLbs: useLbs)) \(useLbs ? "lbs" : "kg"))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if bluetoothManager.readingCorrection.isActive && bluetoothManager.readingCorrectionDevice == device {
                    Button("Remove correction", role: .destructive) {
                        save(.identity)
                    }
                    .disabled(!isDeviceConnected || !canChangeReadingCorrection)
                }
            } footer: {
                if !isDeviceConnected {
                    Text("Reconnect this device to preview or save its correction.")
                } else if !canChangeReadingCorrection {
                    Text("Finish the current set before saving or removing a correction.")
                } else if draft != nil && reportedForce != nil && correctedPreview == nil {
                    Text("These values produce a reading that is too large. Reduce the multiplier or offset.")
                        .foregroundStyle(.red)
                } else {
                    Text("Remove all load before saving so grip detection can reset its baseline. Saved results stay unchanged.")
                }
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle("Reading correction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let draft { save(draft) }
                }
                .disabled(draft == nil || !isDeviceConnected || !canChangeReadingCorrection ||
                          (reportedForce != nil && correctedPreview == nil))
            }
        }
        .onReceive(bluetoothManager.reportedForceSamples.throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)) { force in
            if isDeviceConnected { reportedForce = force }
        }
        .onChange(of: bluetoothManager.connectionState) { _, state in
            if state != .connected { reportedForce = nil }
        }
        .onChange(of: bluetoothManager.readingCorrectionDevice) { _, _ in
            reportedForce = nil
        }
        .alert("Couldn't save correction", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure this device is connected and the current set has finished, then try again.")
        }
    }

    private func formatted(_ kg: Double?) -> String {
        kg.map { WeightFormatter.format($0, useLbs: useLbs, decimals: 2) } ?? "—"
    }

    private func save(_ correction: ReadingCorrection) {
        guard onSave(correction, device) else {
            showSaveError = true
            return
        }
        dismiss()
    }
}
