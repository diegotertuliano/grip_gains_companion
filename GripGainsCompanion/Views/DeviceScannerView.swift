import SwiftUI

struct DeviceScannerView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    let onDeviceSelected: (ForceDevice) -> Void
    let onSkipDevice: () -> Void

    @State private var showDeviceTypePicker = false
    @State private var showFrezAccessKey = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if bluetoothManager.selectedDeviceType == .frezDyno {
                VStack(spacing: 8) {
                    Button(bluetoothManager.hasFrezAccessKey ? "Manage Frez API Key" : "Set Up Frez API Key") {
                        showFrezAccessKey = true
                    }
                    Text("Keep your Dyno unloaded while connecting and zeroing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if bluetoothManager.connectionState == .connecting {
                        Button("Cancel Connection") { bluetoothManager.disconnect() }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            Divider()
            deviceListSection
            Spacer()
            changeDeviceButton
            skipButton
        }
        .sheet(isPresented: $showDeviceTypePicker) {
            DeviceTypePickerSheet(
                selectedType: $bluetoothManager.selectedDeviceType,
                onDismiss: {
                    showDeviceTypePicker = false
                    bluetoothManager.startScanning()
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFrezAccessKey) {
            FrezAccessKeyView(bluetoothManager: bluetoothManager)
        }
    }

    private var skipButton: some View {
        Button("Continue without device") {
            bluetoothManager.disconnect(preserveAutoReconnect: true)
            onSkipDevice()
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 24)
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("Select \(bluetoothManager.selectedDeviceType.shortName)")
                .font(.title2)
                .fontWeight(.semibold)

            statusView
        }
        .padding(.vertical, 24)
    }

    private var changeDeviceButton: some View {
        Button {
            showDeviceTypePicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Change Device Type")
            }
            .font(.footnote)
            .foregroundColor(.blue)
        }
        .padding(.bottom, 8)
        .disabled(bluetoothManager.connectionState == .connecting)
    }

    @ViewBuilder
    private var deviceListSection: some View {
        if bluetoothManager.discoveredDevices.isEmpty {
            emptyStateView
        } else {
            deviceListView
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        Spacer()
        VStack(spacing: 12) {
            switch bluetoothManager.connectionState {
            case .initializing:
                // Bluetooth not ready yet - show nothing (statusView shows "Initializing...")
                EmptyView()
            case .scanning:
                // Actively scanning - show nothing (statusView shows spinner)
                EmptyView()
            default:
                // Finished scanning with no results
                Text("No devices found")
                    .foregroundColor(.secondary)
                Button("Scan Again") {
                    bluetoothManager.startScanning()
                }
                .buttonStyle(.bordered)
            }
        }
        Spacer()
    }

    private var deviceListView: some View {
        List(bluetoothManager.discoveredDevices) { device in
            Button {
                onDeviceSelected(device)
            } label: {
                DeviceRowView(device: device)
            }
            .disabled(bluetoothManager.connectionState == .connecting ||
                      (device.type == .frezDyno && !bluetoothManager.hasFrezAccessKey))
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var statusView: some View {
        switch bluetoothManager.connectionState {
        case .initializing:
            StatusIndicator(text: "Initializing...", showProgress: true)
        case .scanning:
            StatusIndicator(text: "Scanning...", showProgress: true)
        case .connecting:
            StatusIndicator(text: bluetoothManager.selectedDeviceType == .frezDyno
                            ? bluetoothManager.frezSetupStatus : "Connecting...", showProgress: true)
        case .error(let msg):
            ErrorStatusView(message: msg, deviceType: bluetoothManager.selectedDeviceType) {
                bluetoothManager.startScanning()
            }
        default:
            Text(bluetoothManager.selectedDeviceType == .frezDyno && !bluetoothManager.hasFrezAccessKey
                 ? "Set up your access key to connect" : "Tap a device to connect")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Device Type Picker Sheet

private struct DeviceTypePickerSheet: View {
    @Binding var selectedType: DeviceType
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(DeviceType.allCases, id: \.self) { deviceType in
                    Button {
                        selectedType = deviceType
                        onDismiss()
                    } label: {
                        HStack {
                            Text(deviceType.displayName)
                                .font(.body)
                                .foregroundColor(.primary)

                            Spacer()

                            if deviceType == selectedType {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Select Device Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Error Status View

private struct ErrorStatusView: View {
    let message: String
    let deviceType: DeviceType
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(userFriendlyMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button(action: onRetry) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(troubleshootingTip)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var userFriendlyMessage: String {
        if deviceType == .frezDyno { return message }
        if message.lowercased().contains("off") {
            return "Bluetooth is turned off"
        } else if message.lowercased().contains("unauthorized") {
            return "Bluetooth permission required"
        } else if message.lowercased().contains("timeout") {
            return "Connection timed out"
        }
        return message
    }

    private var troubleshootingTip: String {
        if deviceType == .frezDyno {
            return "Check your Frez API key, internet connection, and account access before retrying."
        }
        if message.lowercased().contains("off") {
            return "Enable Bluetooth in Settings to continue"
        } else if message.lowercased().contains("unauthorized") {
            return "Go to Settings > Grip Gains Companion > Bluetooth to grant permission"
        } else if message.lowercased().contains("timeout") {
            return "Make sure your \(deviceType.shortName) is powered on and nearby"
        }
        return "Make sure your \(deviceType.shortName) is powered on and nearby"
    }
}

// MARK: - Supporting Views

private struct StatusIndicator: View {
    let text: String
    let showProgress: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showProgress {
                ProgressView()
                    .scaleEffect(0.8)
            }
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct DeviceRowView: View {
    let device: ForceDevice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(device.signalStrength)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "wifi", variableValue: Double(device.signalBars) / 4.0)
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
