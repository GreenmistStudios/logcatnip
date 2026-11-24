import Foundation
import LogcatKit
import SwiftUI
import Testing
@testable import Logcatnip

/// The Source Code section of Settings, with the custom editor selected so its template field shows.
@MainActor
@Suite struct SettingsScreenshotTests {
    @Test func sourceCodeSettings() async throws {
        let view = Form {
            SourceCodeSettings(
                editor: .constant(.custom),
                customTemplate: .constant("zed {file}:{line}"),
                roots: ["/Users/me/AndroidStudioProjects/Logcatnip Sample", "/Users/me/src/aosp/frameworks/base"],
                add: {},
                remove: { _ in }
            )
        }
        .formStyle(.grouped)
        .frame(width: 520)
        try await Snapshot.assertSnapshot(
            of: view,
            named: "settings-source-code",
            size: CGSize(width: 520, height: 400)
        )
    }
}
