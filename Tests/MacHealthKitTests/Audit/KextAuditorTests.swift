import Testing
@testable import MacHealthKit

struct KextAuditorTests {

    @Test func cleanSystemHasNoThirdPartyKexts() {
        let metrics = KextAuditor(shell: intelShell()).audit()
        #expect(metrics.isCleanNative)
        #expect(metrics.nonAppleKextsCount == 0)
        #expect(metrics.status == "CLEAN_NATIVE")
    }

    @Test func thirdPartyKextIsExtractedByName() {
        let metrics = KextAuditor(shell: intelShell(kmutil: Fix.kmutilDirty)).audit()
        #expect(!metrics.isCleanNative)
        #expect(metrics.nonAppleKextNames == ["com.rugarciap.DisableTurboBoost"])
        #expect(metrics.status == "UNSAFE_LEGACY_KEXTS_LOADED")
    }
}
