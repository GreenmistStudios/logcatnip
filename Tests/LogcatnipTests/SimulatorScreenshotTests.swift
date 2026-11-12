import AppKit
import Foundation
import LogcatKit
import SwiftUI
import Testing
@testable import Logcatnip

/// Screenshots of iOS simulator support: unified log entries in the table, and simulators in the sidebar.
@MainActor
@Suite(.serialized)
struct SimulatorScreenshotTests {
    init() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix("LogTable") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func simulatorSession() async throws {
        let session = LogSession(source: .simulator(udid: SimulatorFixtures.simulator.udid), model: AppModel())
        session.show(SimulatorFixtures.entries, status: .streaming)
        try await Snapshot.assertSnapshot(
            of: SessionContent(session: session, fontSize: 12, showDate: false, wrapLines: false),
            named: "session-simulator",
            size: CGSize(width: 1000, height: 300)
        )
    }

    @Test func sidebarWithSimulator() async throws {
        let model = AppModel()
        model.updateSimulators([SimulatorFixtures.simulator])
        try await Snapshot.assertSnapshot(
            of: SidebarView().environment(model),
            named: "sidebar-simulator",
            size: CGSize(width: 260, height: 160)
        )
    }
}

enum SimulatorFixtures {
    static let simulator = SimulatorDevice(
        udid: "AF226314-2CA8-4EC2-8227-3DCEBA9C7858",
        name: "iPhone 17 Pro",
        state: "Booted",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    )

    static let app = "Catnip"

    static let entries: [LogEntry] = [
        LogEntry(timestamp: Fixtures.time(9, 41, 0, 12), uid: "501", pid: 4242, tid: 88001, level: .debug,
                 tag: "com.example.catnip:network", message: "GET https://api.example.com/v1/cats?page=2", processName: app),
        LogEntry(timestamp: Fixtures.time(9, 41, 0, 230), uid: "501", pid: 4242, tid: 88001, level: .info,
                 tag: "UIKitCore", message: "Scene will enter foreground", processName: app),
        LogEntry(timestamp: Fixtures.time(9, 41, 1, 7), uid: "501", pid: 101, tid: 2201, level: .info,
                 tag: "com.apple.runningboard:assertion", message: "Acquiring assertion for app<com.example.catnip>",
                 processName: "runningboardd"),
        LogEntry(timestamp: Fixtures.time(9, 41, 2, 333), uid: "501", pid: 4242, tid: 88014, level: .error,
                 tag: "com.example.catnip:store", message: "Failed to save bowl: disk full", processName: app),
        LogEntry.marker("Simulator shut down", at: Fixtures.time(9, 41, 3, 0)),
        LogEntry(timestamp: Fixtures.time(9, 41, 4, 450), uid: "501", pid: 4242, tid: 88001, level: .assert,
                 tag: "com.example.catnip:bowl", message: "Bowl invariant violated: food < 0", processName: app),
    ]
}
