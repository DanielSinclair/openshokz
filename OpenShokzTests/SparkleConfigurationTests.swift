import Foundation
import Testing
@testable import OpenShokz

/// Hosted unit tests: Bundle.main is the app bundle.
@Suite("Sparkle configuration")
struct SparkleConfigurationTests {
    @Test("Info.plist points Sparkle at the site appcast")
    func feedURL() {
        let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String
        #expect(feed == "https://danielsinclair.github.io/openshokz/appcast.xml")
    }

    @Test("Info.plist carries a real EdDSA public key")
    func publicKey() throws {
        let key = try #require(Bundle.main.infoDictionary?["SUPublicEDKey"] as? String)
        #expect(!key.contains("PLACEHOLDER"))
        let decoded = try #require(Data(base64Encoded: key))
        #expect(decoded.count == 32, "Ed25519 public keys are 32 bytes")
    }

    @Test("automatic checks are pre-consented (no first-run prompt)")
    func automaticChecks() {
        #expect(Bundle.main.infoDictionary?["SUEnableAutomaticChecks"] as? Bool == true)
    }
}
