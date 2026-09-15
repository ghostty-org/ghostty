import Foundation
import Testing
@testable import Ghostty

struct OhMyGhosttyVersionTests {
    @Test func appBundlePublishesReleaseMetadata() {
        let versions = OhMyGhosttyVersion()

        #expect(versions.omg == "0.13.0")
        #expect(versions.ghostty == "1.3.2-dev")
        #expect(versions.ghosttyRevision == "9ae02a326f62bd88f7f5508cf1807c67e7775cb5")
    }

    @Test func appBundleUsesIndependentOMGIdentity() {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]

        #expect(bundle.bundleIdentifier == "com.jischeng.omg.debug")
        #expect(bundle.bundleURL.lastPathComponent == "OMG.app")
        #expect(info["CFBundleExecutable"] as? String == "omg")
        #expect(info["CFBundleVersion"] as? String == "26")
        #expect(info["SUPublicEDKey"] as? String ==
            "5oid6CANuDnOWeNWfNljTv/mzdKBVGMw1o5j7naHwYY=")
        #expect(OhMyGhosttyVersion.updateFeedURL?.absoluteString ==
            "https://github.com/jischeng/oh-my-ghostty/releases/latest/download/appcast.xml")
        #expect((info["CFBundleDisplayName"] as? String)?.hasPrefix("OMG") == true)
        #expect(info["CFBundleIconName"] as? String == "OMG")
    }

    @Test func readsIndependentOMGAndGhosttyVersions() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "OMGVersion": "0.4.2",
            "CFBundleShortVersionString": "9.9.9",
            "GhosttyBaseVersion": "1.3.2-dev",
            "GhosttyBaseRevision": "9ae02a326f62bd88f7f5508cf1807c67e7775cb5",
        ])

        #expect(versions.omg == "0.4.2")
        #expect(versions.ghostty == "1.3.2-dev")
        #expect(versions.ghosttyRevision == "9ae02a326f62bd88f7f5508cf1807c67e7775cb5")
        #expect(versions.releaseTag == "v0.4.2")
    }

    @Test func fallsBackToBundleMarketingVersion() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.5.1",
        ])

        #expect(versions.omg == "0.5.1")
        #expect(versions.ghostty == "unknown")
        #expect(versions.ghosttyRevision == "unknown")
        #expect(versions.releaseTag == "v0.5.1")
    }

    @Test func nonSemverOMGVersionDoesNotProduceReleaseTag() {
        let versions = OhMyGhosttyVersion(infoDictionary: [
            "OMGVersion": "0.3.1-dev",
        ])

        #expect(versions.releaseTag == nil)
    }
}
