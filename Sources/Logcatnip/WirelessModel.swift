import Foundation
import LogcatKit
import Observation

/// State behind the Connect over Wi-Fi sheet and the sidebar's Discovered list: mDNS discovery through adb,
/// and the three ways to add a device (QR code, pairing code, address).
@MainActor
@Observable
final class WirelessModel {
    enum Tab: String, CaseIterable, Identifiable {
        case qrCode = "qr"
        case pairingCode = "code"
        case ipAddress = "ip"

        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done(String)

        var debugDescription: String {
            let singleLine = { (text: String) in text.replacingOccurrences(of: "\n", with: " ") }
            switch self {
            case .idle: return "idle"
            case let .working(text): return "working(\(singleLine(text)))"
            case let .failed(text): return "failed(\(singleLine(text)))"
            case let .done(text): return "done(\(singleLine(text)))"
            }
        }

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    /// The flow a sheet action reports into.
    private enum Flow {
        case qr, code, ip
    }

    var isSheetPresented = false
    var tab: Tab = .qrCode
    private(set) var services: [MdnsService] = []
    private(set) var availability: MdnsAvailability?
    private(set) var qrCode = QRPairingCode.random()
    private(set) var qrPhase: Phase = .idle
    private(set) var codePhase: Phase = .idle
    private(set) var ipPhase: Phase = .idle
    /// `MdnsService.id`s of Discovered rows with a Connect in flight.
    private(set) var connecting: Set<String> = []
    private(set) var connectErrors: [String: String] = [:]
    /// Set when a disconnect fails; the window shows it in an alert.
    var alertMessage: String?
    private(set) var recentHosts: [String] = WirelessHosts.recent

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var adb: ADB?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// The sheet's one in-flight action; closing the sheet cancels it, which kills the running adb.
    @ObservationIgnored private var sheetTask: Task<Void, Never>?
    @ObservationIgnored private var lastFailure: String?

    /// Services that could be connected to right now: not online over any transport yet.
    var discovered: [MdnsService] {
        WirelessMatching.unconnectedServices(services, transports: app?.devices.map(\.resolvedState) ?? [])
    }

    /// Devices offering a pairing code. The service behind our own QR code is not among them.
    var pairingServices: [MdnsService] {
        services.filter { $0.kind == .pairing && !$0.isQRCodePairing }
    }

    var isBusy: Bool { qrPhase.isWorking || codePhase.isWorking || ipPhase.isWorking }

    // MARK: Lifecycle

    func start(adb: ADB, app: AppModel) {
        discoveryTask?.cancel()
        self.adb = adb
        self.app = app
        services = []
        discoveryTask = Task { [weak self] in
            for await event in adb.trackMdnsServices() {
                guard let self else { return }
                switch event {
                case let .services(list):
                    if list != self.services { self.services = list }
                    self.matchQRCode()
                case let .failed(message):
                    self.lastFailure = message
                }
            }
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        sheetTask?.cancel()
        sheetTask = nil
    }

    func presentSheet(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        sheetTask?.cancel()
        sheetTask = nil
        qrCode = .random()
        qrPhase = .idle
        codePhase = .idle
        ipPhase = .idle
        recentHosts = WirelessHosts.recent
        isSheetPresented = true
        if let adb {
            Task { [weak self] in
                let result = await adb.mdnsAvailability()
                self?.availability = result
            }
        }
        matchQRCode()
    }

    func sheetDismissed() {
        sheetTask?.cancel()
        sheetTask = nil
        qrPhase = .idle
        codePhase = .idle
        ipPhase = .idle
        isSheetPresented = false
    }

    func newQRCode() {
        qrCode = .random()
        qrPhase = .idle
        matchQRCode()
    }

    // MARK: Pairing

    /// Starts pairing as soon as the device advertises the service named in our QR code. Matching the whole
    /// instance name keeps another Android Studio on the network from triggering it.
    private func matchQRCode() {
        guard isSheetPresented, qrPhase == .idle, !isBusy,
              let service = services.first(where: { $0.kind == .pairing && $0.instance == qrCode.serviceName })
        else { return }
        runPair(.qr, address: service.address ?? service.instance, code: qrCode.password,
                label: service.displayName)
    }

    /// Pairing-code tab. `service` is the picked device; `manualAddress` is the typed `ip:port`.
    func pair(code: String, service: MdnsService?, manualAddress: String) {
        guard let normalized = PairingCode.normalized(code) else {
            codePhase = .failed("Enter the 6-digit code shown on the device.")
            return
        }
        let address = service.flatMap { $0.address ?? $0.instance }
            ?? WirelessAddress(manualAddress, defaultPort: nil)?.description
        guard let address else {
            codePhase = .failed("Pick a device, or enter the IP address and port shown on the device.")
            return
        }
        runPair(.code, address: address, code: normalized, label: service?.displayName ?? address)
    }

    private func runPair(_ flow: Flow, address: String, code: String, label: String) {
        guard let adb, let app else { return }
        setPhase(.working("Pairing with \(label)…"), for: flow)
        // adb connects to the device by itself right after pairing, which can beat our reply.
        let before = Set(app.devices.map(\.serial))
        startSheetTask { [weak self] in
            await self?.pairAndWait(flow, adb: adb, address: address, code: code, before: before)
        }
    }

    private func pairAndWait(_ flow: Flow, adb: ADB, address: String, code: String, before: Set<String>) async {
        let guid: String?
        do {
            guid = try await adb.pair(address: address, code: code)
        } catch {
            if !Task.isCancelled { setPhase(.failed("\(error)"), for: flow) }
            return
        }
        guard !Task.isCancelled else { return }
        setPhase(.working("Paired. Waiting for the device to connect…"), for: flow)
        var reconnect: (@Sendable () async -> Void)?
        if let guid {
            reconnect = { _ = try? await adb.connect("\(guid)._adb-tls-connect._tcp") }
        }
        let serial = await waitForDevice(timeout: .seconds(20), reconnectAfter: .seconds(5), reconnect: reconnect) { states in
            if let guid { return WirelessMatching.pairedTransport(guid: guid, in: states) }
            return states.first { $0.isOnline && $0.identity != nil && $0.transport == .wifi && !before.contains($0.serial) }
        }
        guard !Task.isCancelled else { return }
        if let serial {
            finish(flow, serial: serial)
        } else {
            setPhase(.failed("Paired, but the device didn't connect within 20 seconds. Make sure Wireless debugging is still on, then connect it from Discovered in the sidebar."), for: flow)
        }
    }

    // MARK: Connecting

    /// IP address tab.
    func connect(addressText: String) {
        guard let adb, app != nil else { return }
        guard let address = WirelessAddress(addressText) else {
            ipPhase = .failed("Enter an IP address or host name, optionally with a port, like 192.168.1.20:5555.")
            return
        }
        ipPhase = .working("Connecting to \(address)…")
        startSheetTask { [weak self] in
            do {
                let serial = try await adb.connect(address.description)
                guard let self, !Task.isCancelled else { return }
                // Only an address adb accepted is worth offering again.
                WirelessHosts.remember(address.description)
                self.recentHosts = WirelessHosts.recent
                let found = await self.waitForDevice(timeout: .seconds(20), reconnectAfter: nil, reconnect: nil) { states in
                    states.first { $0.isOnline && $0.identity != nil && $0.serial == serial }
                }
                guard !Task.isCancelled else { return }
                if let found {
                    self.finish(.ip, serial: found)
                } else {
                    self.setPhase(.failed("adb connected to \(serial), but the device didn't come online. Check the device for an authorization prompt."), for: .ip)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setPhase(.failed("\(error)"), for: .ip)
            }
        }
    }

    /// A Discovered row's Connect button. Uses the mDNS name, which is the serial adb's own auto-connect
    /// would give the transport: a second connection by `ip:port` would add a second Wi-Fi transport for
    /// the same device. Falls back to `ip:port` if adb cannot resolve the name.
    func connect(_ service: MdnsService) {
        guard let adb, let app, !connecting.contains(service.id) else { return }
        connecting.insert(service.id)
        connectErrors[service.id] = nil
        Task { [weak self] in
            var reported: String?
            var failure: String?
            do {
                reported = try await adb.connect(service.mdnsName)
            } catch {
                failure = "\(error)"
                if let address = service.address {
                    do {
                        reported = try await adb.connect(address)
                        failure = nil
                    } catch {
                        failure = "\(error)"
                    }
                }
            }
            guard let self else { return }
            if let failure {
                self.connectErrors[service.id] = failure
            } else {
                let serial = await self.waitForDevice(timeout: .seconds(20), reconnectAfter: nil, reconnect: nil) { states in
                    WirelessMatching.connectedTransport(for: service, reportedSerial: reported, in: states)
                }
                if let serial {
                    app.showDevice(serial: serial)
                } else {
                    self.connectErrors[service.id] = "adb connected, but the device didn't come online. Check the device for an authorization prompt."
                }
            }
            self.connecting.remove(service.id)
        }
    }

    func disconnect(serial: String) {
        guard let adb else { return }
        Task { [weak self] in
            do {
                try await adb.disconnect(serial: serial)
            } catch {
                self?.alertMessage = "\(error)"
            }
        }
    }

    func forgetRecentHost(_ host: String) {
        WirelessHosts.forget(host)
        recentHosts = WirelessHosts.recent
    }

    // MARK: Helpers

    private func setPhase(_ phase: Phase, for flow: Flow) {
        switch flow {
        case .qr: qrPhase = phase
        case .code: codePhase = phase
        case .ip: ipPhase = phase
        }
    }

    private func startSheetTask(_ body: @escaping @MainActor () async -> Void) {
        sheetTask?.cancel()
        sheetTask = Task { await body() }
    }

    /// The user asked for this device, so it gets a session whatever the auto-open setting says.
    private func finish(_ flow: Flow, serial: String) {
        let name = app?.device(serial: serial)?.displayName ?? serial
        app?.showDevice(serial: serial)
        setPhase(.done("Connected to \(name)"), for: flow)
        isSheetPresented = false
    }

    /// Polls the device list until `matches` finds a transport, or `timeout` passes. After `reconnectAfter`
    /// it calls `reconnect` once: some devices pair but are not picked up by adb's own auto-connect.
    private func waitForDevice(timeout: Duration, reconnectAfter: Duration?, reconnect: (@Sendable () async -> Void)?,
                               matches: ([TransportState]) -> TransportState?) async -> String? {
        guard let app else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        var reconnected = false
        while !Task.isCancelled {
            if let found = matches(app.devices.map(\.resolvedState)) { return found.serial }
            let elapsed = clock.now - start
            if elapsed >= timeout { return nil }
            if let reconnectAfter, let reconnect, !reconnected, elapsed >= reconnectAfter {
                reconnected = true
                await reconnect()
                continue
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Waits for a Discovered or pairing candidate, for the launch hooks.
    private func waitForService(timeout: Duration, in list: () -> [MdnsService]) async -> MdnsService? {
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            if let first = list().first { return first }
            if clock.now - start >= timeout { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: Debugging

    /// Drives the flows without clicking, so they can be run from a terminal. Each calls the method the UI
    /// calls. `LOGCATNIP_WIFI_SHEET=qr|code|ip`; `LOGCATNIP_WIFI_CONNECT=host:port|discovered`;
    /// `LOGCATNIP_WIFI_PAIR="host:port|discovered CODE"`.
    func runLaunchHooks(environment: [String: String]) {
        let sheet = environment["LOGCATNIP_WIFI_SHEET"]
        let connect = environment["LOGCATNIP_WIFI_CONNECT"]
        let pair = environment["LOGCATNIP_WIFI_PAIR"]
        guard sheet != nil || connect != nil || pair != nil else { return }
        Task { [weak self] in
            // Let device tracking and discovery start first.
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            if let sheet {
                self.presentSheet(tab: Tab(rawValue: sheet) ?? .qrCode)
            }
            if let connect {
                if connect == "discovered" {
                    if let service = await self.waitForService(timeout: .seconds(30), in: { self.discovered }) {
                        self.connect(service)
                    }
                } else {
                    self.connect(addressText: connect)
                }
            }
            if let pair, let space = pair.lastIndex(of: " ") {
                let target = String(pair[..<space])
                let code = String(pair[pair.index(after: space)...])
                if target == "discovered" {
                    let service = await self.waitForService(timeout: .seconds(30), in: { self.pairingServices })
                    self.pair(code: code, service: service, manualAddress: "")
                } else {
                    self.pair(code: code, service: nil, manualAddress: target)
                }
            }
        }
    }

    /// One line for `LOGCATNIP_DEBUG`. Never includes the QR password or a pairing code.
    var debugSummary: String {
        func entry(_ service: MdnsService) -> String { "\(service.mdnsName)@\(service.address ?? "-")" }
        let errors = connectErrors.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "; ")
        return "wireless: mdns=\(availability?.rawValue ?? "-") services=\(services.count) "
            + "discovered=[\(discovered.map(entry).joined(separator: ","))] "
            + "pairing=[\(pairingServices.map { "\($0.instance)@\($0.address ?? "-")" }.joined(separator: ","))] "
            + "sheet=\(isSheetPresented ? 1 : 0) tab=\(tab.rawValue) qr=\(qrCode.serviceName) "
            + "qrPhase=\(qrPhase.debugDescription) codePhase=\(codePhase.debugDescription) "
            + "ipPhase=\(ipPhase.debugDescription) connecting=\(connecting.count) errors=[\(errors)] "
            + "recent=[\(recentHosts.joined(separator: ","))] "
            + "lastFailure=\(lastFailure?.replacingOccurrences(of: "\n", with: " ") ?? "-")"
    }
}
