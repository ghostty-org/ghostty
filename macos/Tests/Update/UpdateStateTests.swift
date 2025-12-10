import Testing
import Foundation
import Sparkle
@testable import Ghostty

struct UpdateStateTests {
    // MARK: - Equatable Tests
    
    @Test func testIdleEquality() {
        let state1: UpdateState = .idle
        let state2: UpdateState = .idle
        #expect(state1 == state2)
    }
    
    @Test func testCheckingEquality() {
        let state1: UpdateState = .checking(.init(cancel: {}))
        let state2: UpdateState = .checking(.init(cancel: {}))
        #expect(state1 == state2)
    }
    
    @Test func testNotFoundEquality() {
        let state1: UpdateState = .notFound(.init(acknowledgement: {}))
        let state2: UpdateState = .notFound(.init(acknowledgement: {}))
        #expect(state1 == state2)
    }
    
    @Test func testInstallingEquality() {
        let state1: UpdateState = .installing(.init(isAutoUpdate: false, retryTerminatingApplication: {}, dismiss: {}))
        let state2: UpdateState = .installing(.init(isAutoUpdate: false, retryTerminatingApplication: {}, dismiss: {}))
        #expect(state1 == state2)
        let state3: UpdateState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
        #expect(state3 != state2)
    }
    
    @Test func testPermissionRequestEquality() {
        let request1 = SPUUpdatePermissionRequest(systemProfile: [])
        let request2 = SPUUpdatePermissionRequest(systemProfile: [])
        let state1: UpdateState = .permissionRequest(.init(request: request1, reply: { _ in }))
        let state2: UpdateState = .permissionRequest(.init(request: request2, reply: { _ in }))
        #expect(state1 == state2)
    }
    
    @Test func testDownloadingEqualityWithSameProgress() {
        let state1: UpdateState = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 500))
        let state2: UpdateState = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 500))
        #expect(state1 == state2)
    }
    
    @Test func testDownloadingInequalityWithDifferentProgress() {
        let state1: UpdateState = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 500))
        let state2: UpdateState = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 600))
        #expect(state1 != state2)
    }
    
    @Test func testDownloadingInequalityWithDifferentExpectedLength() {
        let state1: UpdateState = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 500))
        let state2: UpdateState = .downloading(.init(cancel: {}, expectedLength: 2000, progress: 500))
        #expect(state1 != state2)
    }
    
    @Test func testDownloadingEqualityWithNilExpectedLength() {
        let state1: UpdateState = .downloading(.init(cancel: {}, expectedLength: nil, progress: 500))
        let state2: UpdateState = .downloading(.init(cancel: {}, expectedLength: nil, progress: 500))
        #expect(state1 == state2)
    }
    
    @Test func testExtractingEqualityWithSameProgress() {
        let state1: UpdateState = .extracting(.init(progress: 0.5))
        let state2: UpdateState = .extracting(.init(progress: 0.5))
        #expect(state1 == state2)
    }
    
    @Test func testExtractingInequalityWithDifferentProgress() {
        let state1: UpdateState = .extracting(.init(progress: 0.5))
        let state2: UpdateState = .extracting(.init(progress: 0.6))
        #expect(state1 != state2)
    }
    
    @Test func testErrorEqualityWithSameDescription() {
        let error1 = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error message"])
        let error2 = NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Error message"])
        let state1: UpdateState = .error(.init(error: error1, retry: {}, dismiss: {}))
        let state2: UpdateState = .error(.init(error: error2, retry: {}, dismiss: {}))
        #expect(state1 == state2)
    }
    
    @Test func testErrorInequalityWithDifferentDescription() {
        let error1 = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error 1"])
        let error2 = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error 2"])
        let state1: UpdateState = .error(.init(error: error1, retry: {}, dismiss: {}))
        let state2: UpdateState = .error(.init(error: error2, retry: {}, dismiss: {}))
        #expect(state1 != state2)
    }
    
    @Test func testDifferentStatesAreNotEqual() {
        let state1: UpdateState = .idle
        let state2: UpdateState = .checking(.init(cancel: {}))
        #expect(state1 != state2)
    }
    
    // MARK: - isIdle Tests
    
    @Test func testIsIdleTrue() {
        let state: UpdateState = .idle
        #expect(state.isIdle == true)
    }
    
    @Test func testIsIdleFalse() {
        let state: UpdateState = .checking(.init(cancel: {}))
        #expect(state.isIdle == false)
    }
}
