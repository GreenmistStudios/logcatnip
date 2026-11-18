import Foundation
import Testing
@testable import LogcatKit

@Suite struct WirelessParsingTests {
    // MARK: QR payload

    @Test func qrPayloadMatchesAndroidStudioFormat() {
        // WiFiPairingServiceImpl.createPairingString in Android Studio.
        let code = QRPairingCode(serviceName: "studio-AbC123xyz-", password: "p@ss(w)rd1+*")
        #expect(code.payload == "WIFI:T:ADB;S:studio-AbC123xyz-;P:p@ss(w)rd1+*;;")
    }

    @Test func randomCodeUsesAndroidStudioAlphabet() {
        let nameCharacters = Set(QRPairingCode.nameCharacters)
        let passwordCharacters = Set(QRPairingCode.passwordCharacters)
        for _ in 0..<200 {
            let code = QRPairingCode.random()
            #expect(code.serviceName.hasPrefix("studio-"))
            let name = code.serviceName.dropFirst("studio-".count)
            #expect(name.count == 10)
            #expect(name.allSatisfy(nameCharacters.contains))
            #expect(code.password.count == 12)
            #expect(code.password.allSatisfy(passwordCharacters.contains))
            for character in ";:,\\\"" {
                #expect(!code.serviceName.contains(character))
                #expect(!code.password.contains(character))
            }
        }
    }

    @Test func randomCodesDiffer() {
        #expect(QRPairingCode.random() != QRPairingCode.random())
    }

    // MARK: adb mdns services

    // adb 37.0.1: instance, type and address separated by tabs, no trailing dot on the type.
    static let servicesList = """
    List of discovered mdns services
    studio-TestPair01\t_adb-tls-pairing._tcp\t192.168.4.250:37999
    adb-ZZTEST0001-AbCdEf\t_adb-tls-connect._tcp\t192.168.4.250:37123

    """

    @Test func parsesMdnsServicesList() throws {
        let services = MdnsService.parseList(Self.servicesList)
        #expect(services.count == 2)
        let pairing = services[0]
        #expect(pairing.kind == .pairing)
        #expect(pairing.isQRCodePairing)
        #expect(pairing.address == "192.168.4.250:37999")
        let connect = services[1]
        #expect(connect.kind == .tlsConnect)
        #expect(connect.deviceSerial == "ZZTEST0001")
        #expect(connect.mdnsName == "adb-ZZTEST0001-AbCdEf._adb-tls-connect._tcp")
    }

    // The comment in Android Studio's QrCodeScanningController shows older adb ending the type with a dot.
    @Test func parsesLegacyMdnsServicesListWithTrailingDot() {
        let services = MdnsService.parseList("""
        List of discovered mdns services
        adb-939AX05XBZ-vWgJpq\t_adb-tls-connect._tcp.\t192.168.1.86:39149
        adb-939AX05XBZ-vWgJpq\t_adb-tls-pairing._tcp.\t192.168.1.86:37313
        """)
        #expect(services.map(\.type) == ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"])
        #expect(services[1].kind == .pairing)
        #expect(!services[1].isQRCodePairing)
        #expect(services[1].deviceSerial == "939AX05XBZ")
    }

    @Test func ignoresMalformedMdnsLines() {
        let text = "* daemon started successfully\ngarbage\nx\t_adb._tcp\tnoport\nx\t_adb._tcp\t1.2.3.4:0\n"
        #expect(MdnsService.parseList(text).isEmpty)
    }

    @Test func parsesIPv6MdnsAddress() {
        let services = MdnsService.parseList("x\t_adb-tls-connect._tcp\t[fe80::1]:5555\n")
        #expect(services.count == 1)
        #expect(services[0].ipv6 == "fe80::1")
        #expect(services[0].ipv4 == nil)
        #expect(services[0].address == "[fe80::1]:5555")
    }

    // MARK: adb mdns track-services --proto-text

    // Captured from adb 37.0.1 with services registered by dns-sd.
    static let trackSnapshot = """

    Services:
    tls {
      service {
        instance: "adb-ZZTEST0002-XyZ123"
        service: "_adb-tls-connect._tcp"
        ipv4: "192.168.4.250"
        port: 37124
        serial: "ZZTEST0002"
        mdns_service_version: "1"
        hostname: "CJP2742RMH.local"
      }
    }
    tls {
      service {
        instance: "adb-ZZTEST0001-AbCdEf"
        service: "_adb-tls-connect._tcp"
        ipv4: "192.168.4.250"
        port: 37123
        mdns_service_version: "1"
        hostname: "CJP2742RMH.local"
      }
    }
    pair {
      service {
        instance: "studio-TestPair01"
        service: "_adb-tls-pairing._tcp"
        ipv4: "192.168.4.250"
        port: 37999
        mdns_service_version: "1"
        hostname: "CJP2742RMH.local"
      }
    }

    """

    @Test func decodesTrackServicesSnapshot() {
        var decoder = MdnsTrackDecoder()
        let snapshots = decoder.feed(Data(Self.trackSnapshot.utf8))
        #expect(snapshots.count == 1)
        let services = snapshots.first ?? []
        #expect(services.count == 3)
        #expect(services[0].serial == "ZZTEST0002")
        #expect(services[0].port == 37124)
        #expect(services[1].serial == nil)
        #expect(services[1].deviceSerial == "ZZTEST0001")
        #expect(services[2].kind == .pairing)
        #expect(services[2].port == 37999)
    }

    // The example in the adb documentation, which also carries ipv6, product_model and given_name.
    @Test func decodesDocsExampleWithModelAndName() {
        var decoder = MdnsTrackDecoder()
        let text = """

        Services:
        tls {
          service {
            instance: "adb-35121FDJH000R8-xyMD0H"
            service: "_adb-tls-connect._tcp"
            ipv4: "192.168.84.23"
            ipv6: "fe80:0:0:0:fc7a:299d:8d38:6c1c"
            port: 37895
            product_model: "Pixel 8"
            build_version_sdk_full: "37.0"
            given_name: "sherifeid Pixel"
            serial: "35121FDJH000R8"
            mdns_service_version: "2.0"
            hostname: "Android_CXUKYJY1.local"
          }
        }

        """
        let services = decoder.feed(Data(text.utf8)).first ?? []
        #expect(services.count == 1)
        #expect(services[0].displayName == "sherifeid Pixel")
        #expect(services[0].productModel == "Pixel 8")
        #expect(services[0].sdkVersion == "37.0")
        #expect(services[0].address == "192.168.84.23:37895")
        #expect(services[0].ipv6 == "fe80:0:0:0:fc7a:299d:8d38:6c1c")
    }

    @Test func emptySnapshotMeansNoServices() {
        var decoder = MdnsTrackDecoder()
        let snapshots = decoder.feed(Data("\nServices:\n".utf8))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isEmpty == true)
    }

    @Test func decodesConsecutiveSnapshots() {
        var decoder = MdnsTrackDecoder()
        let one = """

        Services:
        tls {
          service {
            instance: "adb-A-b"
            service: "_adb-tls-connect._tcp"
            ipv4: "10.0.0.1"
            port: 1234
          }
        }

        Services:

        """
        let snapshots = decoder.feed(Data(one.utf8))
        #expect(snapshots.count == 2)
        #expect(snapshots[0].map(\.instance) == ["adb-A-b"])
        #expect(snapshots[1].isEmpty)
    }

    @Test func waitsForClosingBraces() {
        var decoder = MdnsTrackDecoder()
        let text = Self.trackSnapshot
        // Split inside the second service block, in the middle of a line.
        let split = text.range(of: "instance: \"adb-ZZTEST0001")!.upperBound
        let first = decoder.feed(Data(text[..<split].utf8))
        #expect(first.isEmpty)
        let second = decoder.feed(Data(text[split...].utf8))
        #expect(second.count == 1)
        #expect(second.first?.count == 3)
    }

    @Test func unescapesProtoTextStrings() {
        var decoder = MdnsTrackDecoder()
        let text = """

        Services:
        tls {
          service {
            instance: "adb-A-b"
            service: "_adb-tls-connect._tcp"
            ipv4: "10.0.0.1"
            port: 1234
            given_name: "Jos\\303\\251\\'s \\"Pixel\\""
          }
        }

        """
        let services = decoder.feed(Data(text.utf8)).first ?? []
        #expect(services.first?.givenName == "José's \"Pixel\"")
    }

    @Test func deviceSerialFromInstanceKeepsDashes() {
        #expect(MdnsService.deviceSerial(fromInstance: "adb-ABC-DEF-xyz123") == "ABC-DEF")
        #expect(MdnsService.deviceSerial(fromInstance: "studio-x") == nil)
        #expect(MdnsService.deviceSerial(fromInstance: "adb-") == nil)
    }

    @Test func displayNamePrefersGivenNameThenModelThenSerial() {
        var service = MdnsService(instance: "adb-SER9-q", type: "_adb-tls-connect._tcp", ipv4: "10.0.0.1", port: 1)
        #expect(service.displayName == "SER9")
        service.productModel = "Pixel 8"
        #expect(service.displayName == "Pixel 8")
        service.givenName = ""
        #expect(service.displayName == "Pixel 8")
        service.givenName = "Kitchen tablet"
        #expect(service.displayName == "Kitchen tablet")
        #expect(MdnsService(instance: "studio-x", type: "_adb-tls-pairing._tcp", ipv4: nil, port: 1).displayName == "studio-x")
    }

    // MARK: Typed addresses and codes

    @Test func parsesHostAndPort() {
        let address = WirelessAddress("192.168.1.20:37155")
        #expect(address?.host == "192.168.1.20")
        #expect(address?.port == 37155)
        #expect(address?.description == "192.168.1.20:37155")
    }

    @Test func addsDefaultPort() {
        #expect(WirelessAddress("192.168.1.20")?.description == "192.168.1.20:5555")
        #expect(WirelessAddress(" pixel.local ")?.description == "pixel.local:5555")
    }

    @Test func requiresPortWhenNoDefault() {
        #expect(WirelessAddress("192.168.1.20", defaultPort: nil) == nil)
        #expect(WirelessAddress("192.168.1.20:37155", defaultPort: nil)?.port == 37155)
    }

    @Test func parsesIPv6() {
        #expect(WirelessAddress("[fe80::1]:5555")?.description == "[fe80::1]:5555")
        #expect(WirelessAddress("fe80::1")?.description == "[fe80::1]:5555")
        #expect(WirelessAddress("[fe80::1]")?.description == "[fe80::1]:5555")
    }

    @Test func rejectsBadAddresses() {
        for text in ["", "   ", "host:0", "host:70000", "host:abc", "a b:5555", ":5555", "[]:5555", "[fe80::1"] {
            #expect(WirelessAddress(text) == nil, "\(text)")
        }
    }

    @Test func normalizesSixDigitCodes() {
        #expect(PairingCode.normalized("123456") == "123456")
        #expect(PairingCode.normalized(" 123 456 ") == "123456")
        for text in ["12345", "1234567", "12a456", ""] {
            #expect(PairingCode.normalized(text) == nil, "\(text)")
        }
    }

    // MARK: Diagnostics

    static let serverStatus = """
    usb_backend: NATIVE
    mdns_backend: LIBADBMDNS
    version: "37.0.1"
    build: "15733141"
    executable_absolute_path: "/Users/someone/Library/Android/sdk/platform-tools/adb"
    trace_level: ""
    burst_mode: false
    mdns_enabled: true
    keystore_path: "/Users/someone/.android/adbkey"
    """

    @Test func parsesServerStatus() {
        let status = ADBServerStatus.parse(Self.serverStatus)
        #expect(status.version == "37.0.1")
        #expect(status.mdnsEnabled == true)
        #expect(status.values["mdns_backend"] == "LIBADBMDNS")
        #expect(status.values["trace_level"] == "")
    }

    @Test func mdnsDisabledByServerStatus() {
        let disabled = Self.serverStatus.replacingOccurrences(of: "mdns_enabled: true", with: "mdns_enabled: false")
        #expect(MdnsAvailability.evaluate(serverStatus: disabled, mdnsCheck: "mdns daemon version [x]") == .disabled)
    }

    @Test func mdnsAvailableOnCurrentAdb() {
        let check = "mdns daemon version [adb discovery 0.0.0]\n"
        #expect(MdnsAvailability.evaluate(serverStatus: Self.serverStatus, mdnsCheck: check) == .available)
    }

    @Test func mdnsDisabledByCheck() {
        #expect(MdnsAvailability.evaluate(serverStatus: nil, mdnsCheck: "ERROR: mdns discovery disabled") == .disabled)
    }

    @Test func oldAdbWithoutMdns() {
        #expect(MdnsAvailability.evaluate(serverStatus: nil, mdnsCheck: "adb: unknown command mdns") == .unsupported)
        #expect(MdnsAvailability.evaluate(serverStatus: nil, mdnsCheck: nil) == .unknown)
    }

    // MARK: adb output

    func result(_ stdout: String = "", stderr: String = "", status: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(status: status, stdout: Data(stdout.utf8), stderr: stderr, timedOut: timedOut)
    }

    func pairError(_ result: CommandResult) -> String? {
        if case let .failure(error) = WirelessOutput.pairing(result, timeoutDescription: "90 seconds") { return error.description }
        return nil
    }

    func connectError(_ result: CommandResult) -> String? {
        if case let .failure(error) = WirelessOutput.connection(result, timeoutDescription: "90 seconds") { return error.description }
        return nil
    }

    @Test func pairSuccessReturnsGuid() throws {
        let output = result("Successfully paired to 192.168.1.86:41915 [guid=adb-939AX05XBZ-vWgJpq]\n")
        let guid = try WirelessOutput.pairing(output, timeoutDescription: "90 seconds").get()
        #expect(guid == "adb-939AX05XBZ-vWgJpq")
    }

    @Test func pairSuccessAfterPrompt() throws {
        let output = result("Enter pairing code: Successfully paired to 10.0.0.2:37000 [guid=adb-X-y]\n")
        let guid = try WirelessOutput.pairing(output, timeoutDescription: "90 seconds").get()
        #expect(guid == "adb-X-y")
    }

    @Test func pairSuccessWithoutGuid() throws {
        let output = result("Successfully paired to 10.0.0.2:37000\n")
        let guid = try WirelessOutput.pairing(output, timeoutDescription: "90 seconds").get()
        #expect(guid == nil)
    }

    @Test func wrongPairingCodeShowsAdbMessage() {
        // adb replies OKAY with this text, so it exits 0.
        let output = result("Failed: Wrong password or connection was dropped.\n")
        #expect(pairError(output) == "Failed: Wrong password or connection was dropped.")
    }

    @Test func unreachablePairingPortShowsAdbMessage() {
        let output = result(stderr: "error: protocol fault (couldn't read status message): Undefined error: 0\n", status: 1)
        #expect(pairError(output) == "error: protocol fault (couldn't read status message): Undefined error: 0")
    }

    @Test func pairTimeoutSaysSo() {
        let output = result(status: 15, timedOut: true)
        #expect(pairError(output) == "adb didn't answer within 90 seconds.")
    }

    @Test func timeoutKeepsWhatAdbSaid() {
        let output = result("Enter pairing code: ", status: 15, timedOut: true)
        #expect(pairError(output) == "adb didn't answer within 90 seconds.")
        let verbose = result(stderr: "still trying\n", status: 15, timedOut: true)
        #expect(pairError(verbose) == "adb didn't answer within 90 seconds.\nstill trying")
    }

    @Test func connectSuccessReturnsSerial() throws {
        let serial = try WirelessOutput.connection(result("connected to 192.168.1.20:5555\n"), timeoutDescription: "90 seconds").get()
        #expect(serial == "192.168.1.20:5555")
    }

    @Test func alreadyConnectedIsSuccess() throws {
        let serial = try WirelessOutput.connection(result("already connected to 192.168.1.20:5555\n"), timeoutDescription: "90 seconds").get()
        #expect(serial == "192.168.1.20:5555")
    }

    @Test func connectFailureExitsZeroButIsAnError() {
        let output = result("failed to connect to '192.168.1.20:5555': Connection refused\n")
        #expect(connectError(output) == "failed to connect to '192.168.1.20:5555': Connection refused")
    }

    @Test func connectTimeoutShowsAdbMessage() {
        let output = result("failed to connect to '192.0.2.1:5555': Operation timed out\n")
        #expect(connectError(output) == "failed to connect to '192.0.2.1:5555': Operation timed out")
    }

    @Test func unresolvableHostShowsAdbMessage() {
        let text = "failed to resolve host: 'bogus.invalid': nodename nor servname provided, or not known"
        #expect(connectError(result(text + "\n")) == text)
    }

    @Test func failedToAuthenticateIsAnError() {
        let text = "failed to authenticate to 192.168.1.20:37000"
        #expect(connectError(result(text + "\n")) == text)
    }

    @Test func connectWithNoOutputReportsExitStatus() {
        #expect(connectError(result(status: 1)) == "adb exited with status 1.")
    }

    @Test func disconnectSuccess() {
        if case .failure = WirelessOutput.disconnection(result("disconnected 192.168.1.20:5555\n")) {
            Issue.record("expected success")
        }
    }

    @Test func disconnectUnknownDevice() {
        let output = result(stderr: "error: no such device '192.168.1.20:5555'\n", status: 1)
        guard case let .failure(error) = WirelessOutput.disconnection(output) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description == "error: no such device '192.168.1.20:5555'")
    }

    // MARK: Matching services to devices

    @Test func onlyHostPortTransportsCanBeDisconnected() throws {
        func disconnectable(_ serial: String) throws -> Bool {
            try #require(DeviceDescriptor.parse(line: Substring("\(serial) device"))).isDisconnectable
        }
        #expect(try disconnectable("192.168.1.50:41001"))
        #expect(try disconnectable("127.0.0.1:5555"))
        #expect(try !disconnectable("adb-35121FDJH000R8-xyMD0H._adb-tls-connect._tcp"))
        #expect(try !disconnectable("adb-X-y._adb._tcp"))
        #expect(try !disconnectable("emulator-5554"))
        #expect(try !disconnectable("35121FDJH000R8"))
    }

    static func service(_ instance: String, _ type: String = "_adb-tls-connect._tcp", address: String? = nil) -> MdnsService {
        var host: String?
        var port = 40000
        if let address {
            let parts = address.split(separator: ":")
            host = String(parts[0])
            port = Int(parts[1]) ?? port
        }
        return MdnsService(instance: instance, type: type, ipv4: host, port: port)
    }

    static let a = service("adb-SER1-x", address: "192.168.1.5:40001")
    static let b = service("adb-SER2-y", address: "192.168.1.6:40002")
    static let c = service("adb-SER3-z", "_adb-tls-pairing._tcp", address: "192.168.1.7:40003")
    static let d = service("adb-EMULATOR37X2X12X0-abc", address: "192.168.1.8:40004")
    static let e = service("adb-SER4-w", "_adb._tcp", address: "192.168.1.9:40005")

    func transport(_ serial: String, _ kind: DeviceTransport, _ identity: DeviceIdentity?, online: Bool = true) -> TransportState {
        TransportState(serial: serial, transport: kind, identity: identity, isOnline: online)
    }

    func phone(_ serial: String) -> DeviceIdentity { DeviceIdentity(kind: .serialNumber, value: serial) }

    var all: [MdnsService] { [Self.a, Self.b, Self.c, Self.d, Self.e] }

    @Test func discoveredListsConnectServicesOnly() {
        let shown = WirelessMatching.unconnectedServices(all, transports: [])
        #expect(shown.map(\.instance) == ["adb-SER1-x", "adb-SER2-y", "adb-SER4-w"])
    }

    @Test func discoveredHidesConnectedServices() {
        let online = transport("adb-SER1-x._adb-tls-connect._tcp", .wifi, phone("SER1"))
        let shown = WirelessMatching.unconnectedServices(all, transports: [online])
        #expect(shown.map(\.instance) == ["adb-SER2-y", "adb-SER4-w"])
    }

    @Test func discoveredHidesDeviceOnUSB() {
        let usb = transport("SER2", .usb, phone("SER2"))
        let shown = WirelessMatching.unconnectedServices(all, transports: [usb])
        #expect(!shown.contains(Self.b))
        #expect(shown.contains(Self.a))
    }

    @Test func discoveredHidesHostPortConnection() {
        let connected = transport("192.168.1.6:40002", .wifi, nil)
        let shown = WirelessMatching.unconnectedServices(all, transports: [connected])
        #expect(!shown.contains(Self.b))
    }

    @Test func offlineTransportDoesNotHideService() {
        let offline = transport("adb-SER1-x._adb-tls-connect._tcp", .wifi, phone("SER1"), online: false)
        let shown = WirelessMatching.unconnectedServices(all, transports: [offline])
        #expect(shown.contains(Self.a))
    }

    @Test func discoveredSkipsEmulatorServices() {
        #expect(!WirelessMatching.unconnectedServices(all, transports: []).contains(Self.d))
    }

    @Test func discoveredDedupesSameService() {
        let shown = WirelessMatching.unconnectedServices([Self.a, Self.a], transports: [])
        #expect(shown == [Self.a])
    }

    @Test func pairedTransportFindsAutoConnectedDevice() {
        let name = "adb-SER1-x._adb-tls-connect._tcp"
        #expect(WirelessMatching.pairedTransport(guid: "adb-SER1-x", in: [transport(name, .wifi, phone("SER1"))])?.serial == name)
        #expect(WirelessMatching.pairedTransport(guid: "adb-SER1-x", in: [transport(name, .wifi, nil)]) == nil)
        #expect(WirelessMatching.pairedTransport(guid: "adb-SER1-x", in: [transport(name, .wifi, phone("SER1"), online: false)]) == nil)
    }

    @Test func connectedTransportAcceptsEveryNameTheDeviceCouldHave() {
        let byName = transport("adb-SER1-x._adb-tls-connect._tcp", .wifi, phone("SER1"))
        let byAddress = transport("192.168.1.5:40001", .wifi, phone("SER1"))
        let reported = transport("somewhere-else", .wifi, phone("OTHER"))
        let other = transport("192.168.1.6:40002", .wifi, phone("SER2"))
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: nil, in: [other, byName])?.serial == byName.serial)
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: nil, in: [other, byAddress])?.serial == byAddress.serial)
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: "somewhere-else", in: [other, reported])?.serial == "somewhere-else")
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: nil, in: [other]) == nil)
    }

    @Test func connectedTransportNeedsAnOnlineKnownIdentity() {
        let name = "adb-SER1-x._adb-tls-connect._tcp"
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: name, in: [transport(name, .wifi, nil)]) == nil)
        #expect(WirelessMatching.connectedTransport(for: Self.a, reportedSerial: name, in: [transport(name, .wifi, phone("SER1"), online: false)]) == nil)
    }

    @Test func pairedTransportMatchesByIdentity() {
        let wifi = transport("192.168.1.5:40001", .wifi, phone("SER1"))
        #expect(WirelessMatching.pairedTransport(guid: "adb-SER1-x", in: [wifi])?.serial == "192.168.1.5:40001")
        #expect(WirelessMatching.pairedTransport(guid: "adb-SER2-x", in: [wifi]) == nil)
    }
}

/// Runs `ADB` against a shell script that imitates adb's wireless commands, so no device or network is needed.
@Suite struct WirelessCommandTests {
    static let script = """
    #!/bin/sh
    echo "$*" >> "$(dirname "$0")/calls.log"
    case "$1" in
    pair) if [ "$3" = "123456" ]; then echo "Successfully paired to $2 [guid=adb-SER1-AbCdEf]"; else echo "Failed: Wrong password or connection was dropped."; fi ;;
    connect) if [ "$2" = "10.0.0.5:5555" ]; then echo "connected to $2"; else echo "failed to connect to '$2': Connection refused"; fi ;;
    disconnect) echo "error: no such device '$2'" >&2; exit 1 ;;
    mdns) printf 'List of discovered mdns services\\nadb-SER1-AbCdEf\\t_adb-tls-connect._tcp\\t10.0.0.5:40001\\n' ;;
    host-features) echo "shell_v2,cmd" ;;
    slow) sleep 5 ;;
    *) exit 1 ;;
    esac
    """

    /// Writes the script into a fresh temporary directory and returns the ADB for it and the call log.
    func fakeADB() throws -> (adb: ADB, callLog: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("adb")
        try Self.script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return (ADB(executable: path), directory.appendingPathComponent("calls.log"))
    }

    @Test func pairRunsAdbPairWithCode() async throws {
        let (adb, callLog) = try fakeADB()
        let guid = try await adb.pair(address: "10.0.0.5:37000", code: "123456")
        #expect(guid == "adb-SER1-AbCdEf")
        let calls = try String(contentsOf: callLog, encoding: .utf8)
        #expect(calls.contains("pair 10.0.0.5:37000 123456"))
    }

    @Test func pairWrongCodeThrowsAdbMessage() async throws {
        let (adb, _) = try fakeADB()
        do {
            _ = try await adb.pair(address: "10.0.0.5:37000", code: "654321")
            Issue.record("expected failure")
        } catch let error as ADBError {
            #expect(error.description == "Failed: Wrong password or connection was dropped.")
        }
    }

    @Test func connectReturnsSerial() async throws {
        let (adb, _) = try fakeADB()
        #expect(try await adb.connect("10.0.0.5:5555") == "10.0.0.5:5555")
    }

    @Test func connectFailureThrowsAdbMessage() async throws {
        let (adb, _) = try fakeADB()
        do {
            _ = try await adb.connect("10.0.0.6:5555")
            Issue.record("expected failure")
        } catch let error as ADBError {
            #expect(error.description == "failed to connect to '10.0.0.6:5555': Connection refused")
        }
    }

    @Test func disconnectFailureThrowsAdbMessage() async throws {
        let (adb, _) = try fakeADB()
        do {
            try await adb.disconnect(serial: "10.0.0.5:5555")
            Issue.record("expected failure")
        } catch let error as ADBError {
            #expect(error.description == "error: no such device '10.0.0.5:5555'")
        }
    }

    @Test func mdnsServicesParsesOutput() async throws {
        let (adb, _) = try fakeADB()
        let services = try await adb.mdnsServices()
        #expect(services.count == 1)
        #expect(services[0].kind == .tlsConnect)
        #expect(services[0].address == "10.0.0.5:40001")
    }

    @Test func hostFeaturesSplitsList() async throws {
        let (adb, _) = try fakeADB()
        #expect(try await adb.hostFeatures() == ["shell_v2", "cmd"])
    }

    @Test func trackFallsBackToPolling() async throws {
        let (adb, _) = try fakeADB()
        for await event in adb.trackMdnsServices(pollInterval: .milliseconds(100)) {
            if case let .services(services) = event, !services.isEmpty {
                #expect(services.count == 1)
                #expect(services[0].mdnsName == "adb-SER1-AbCdEf._adb-tls-connect._tcp")
                return
            }
        }
        Issue.record("the stream ended without a service")
    }

    @Test func connectRunTimesOut() async throws {
        let (adb, _) = try fakeADB()
        let result = try await adb.run(["slow"], timeout: .milliseconds(200))
        #expect(result.timedOut)
        let quick = try await adb.run(["host-features"])
        #expect(!quick.timedOut)
    }
}
