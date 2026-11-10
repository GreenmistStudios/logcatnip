import LogcatKit
import SwiftUI

/// The Connect over Wi-Fi sheet: pair with a QR code or a pairing code, or connect to an address.
struct WirelessConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var pairingCode = ""
    @State private var selectedServiceID: String?
    @State private var manualPairAddress = ""
    @State private var ipAddress = ""

    var body: some View {
        @Bindable var wireless = app.wireless
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect over Wi-Fi")
                .font(.title2)

            if let message = diagnostic(for: wireless.availability) {
                Label {
                    // LocalizedStringKey renders the backticks as code.
                    Text(LocalizedStringKey(message))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Method", selection: $wireless.tab) {
                Text("QR Code").tag(WirelessModel.Tab.qrCode)
                Text("Pairing Code").tag(WirelessModel.Tab.pairingCode)
                Text("IP Address").tag(WirelessModel.Tab.ipAddress)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch wireless.tab {
                case .qrCode: qrTab(wireless)
                case .pairingCode: pairingCodeTab(wireless)
                case .ipAddress: ipAddressTab(wireless)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Close") { wireless.sheetDismissed() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 500)
    }

    // MARK: Diagnostics

    private func diagnostic(for availability: MdnsAvailability?) -> String? {
        switch availability {
        case .disabled:
            "adb's mDNS discovery is off (`adb server-status` shows `mdns_enabled: false`), so Logcatnip can't find devices to pair. Set the `ADB_MDNS` environment variable to `1`, then restart the adb server with `adb kill-server` and `adb start-server`. Connecting by IP address still works."
        case .unsupported:
            "This adb can't discover devices on the network. Update the Android SDK Platform Tools to pair over Wi-Fi. Connecting by IP address still works."
        default:
            nil
        }
    }

    // MARK: QR code

    private func qrTab(_ wireless: WirelessModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                QRCodeView(payload: wireless.qrCode.payload)
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. On your Android 11 or later device, open Developer options › Wireless debugging.")
                    Text("2. Tap Pair device with QR code.")
                    Text("3. Scan this code.")
                    Text("Your Mac and the device must be on the same network.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            statusRow(wireless.qrPhase, idle: "Waiting for a device to scan the code…") {
                Button("Show New Code") { wireless.newQRCode() }
            }
        }
    }

    // MARK: Pairing code

    private func pairingCodeTab(_ wireless: WirelessModel) -> some View {
        let services = wireless.pairingServices
        let selected = services.first { $0.id == selectedServiceID }
        let hasTarget = selected != nil || !manualPairAddress.trimmingCharacters(in: .whitespaces).isEmpty
        let canPair = PairingCode.normalized(pairingCode) != nil && hasTarget && !wireless.isBusy
        return VStack(alignment: .leading, spacing: 10) {
            Text("On the device, open Wireless debugging and tap Pair device with pairing code.")
                .fixedSize(horizontal: false, vertical: true)
            if services.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").foregroundStyle(.secondary)
                }
            } else {
                List(services, selection: $selectedServiceID) { service in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.displayName)
                        Text(service.address ?? service.instance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(service.id)
                }
                .frame(height: 110)
            }
            Text("Not listed? Enter the IP address and port shown on the device:")
                .foregroundStyle(.secondary)
            TextField("Address", text: $manualPairAddress, prompt: Text("192.168.1.20:37155"))
                .labelsHidden()
                .onSubmit { if canPair { startPairing(wireless, selected) } }
            HStack {
                TextField("Pairing code", text: $pairingCode, prompt: Text("6-digit code"))
                    .onSubmit { if canPair { startPairing(wireless, selected) } }
                Button("Pair") { startPairing(wireless, selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPair)
            }
            statusRow(wireless.codePhase)
        }
    }

    private func startPairing(_ wireless: WirelessModel, _ selected: MdnsService?) {
        wireless.pair(code: pairingCode, service: selected, manualAddress: manualPairAddress)
    }

    // MARK: IP address

    private func ipAddressTab(_ wireless: WirelessModel) -> some View {
        let canConnect = !ipAddress.trimmingCharacters(in: .whitespaces).isEmpty && !wireless.isBusy
        return VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a device that is already paired, or one listening after `adb tcpip`.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Address", text: $ipAddress, prompt: Text("192.168.1.20:5555"))
                    .labelsHidden()
                    .onSubmit { if canConnect { wireless.connect(addressText: ipAddress) } }
                Button("Connect") { wireless.connect(addressText: ipAddress) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
            if !wireless.recentHosts.isEmpty {
                Text("Recent")
                    .font(.headline)
                    .padding(.top, 4)
                List(wireless.recentHosts, id: \.self) { host in
                    Button {
                        ipAddress = host
                        wireless.connect(addressText: host)
                    } label: {
                        Label(host, systemImage: "wifi")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(wireless.isBusy)
                    .contextMenu {
                        Button("Remove") { wireless.forgetRecentHost(host) }
                    }
                }
                .frame(height: 110)
            }
            statusRow(wireless.ipPhase)
        }
    }

    // MARK: Status

    /// Progress, success, or adb's message, selectable so it can be copied into a bug report or search.
    @ViewBuilder
    private func statusRow(_ phase: WirelessModel.Phase, idle: String? = nil,
                           @ViewBuilder failureAction: () -> some View = { EmptyView() }) -> some View {
        switch phase {
        case .idle:
            if let idle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(idle).foregroundStyle(.secondary)
                }
            }
        case let .working(text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        case let .failed(text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                failureAction()
            }
        case let .done(text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
