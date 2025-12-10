import Testing
import Foundation
import SwiftUI
import Sparkle
@testable import Ghostty

struct UpdateViewModelTests {
    // MARK: - Text Formatting Tests
    
    @Test func testIdleText() {
        let viewModel = UpdateViewModel()
        viewModel.state = .idle
        #expect(viewModel.text == "")
    }
    
    @Test func testPermissionRequestText() {
        let viewModel = UpdateViewModel()
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        viewModel.state = .permissionRequest(.init(request: request, reply: { _ in }))
        #expect(viewModel.text == "Enable Automatic Updates?")
    }
    
    @Test func testCheckingText() {
        let viewModel = UpdateViewModel()
        viewModel.state = .checking(.init(cancel: {}))
        #expect(viewModel.text == "Checking for Updates…")
    }
    
    @Test func testDownloadingTextWithKnownLength() {
        let viewModel = UpdateViewModel()
        viewModel.state = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 500))
        #expect(viewModel.text == "Downloading: 50%")
    }
    
    @Test func testDownloadingTextWithUnknownLength() {
        let viewModel = UpdateViewModel()
        viewModel.state = .downloading(.init(cancel: {}, expectedLength: nil, progress: 500))
        #expect(viewModel.text == "Downloading…")
    }
    
    @Test func testDownloadingTextWithZeroExpectedLength() {
        let viewModel = UpdateViewModel()
        viewModel.state = .downloading(.init(cancel: {}, expectedLength: 0, progress: 500))
        #expect(viewModel.text == "Downloading…")
    }
    
    @Test func testExtractingText() {
        let viewModel = UpdateViewModel()
        viewModel.state = .extracting(.init(progress: 0.75))
        #expect(viewModel.text == "Preparing: 75%")
    }
    
    @Test func testInstallingText() {
        let viewModel = UpdateViewModel()
        viewModel.state = .installing(.init(isAutoUpdate: false, retryTerminatingApplication: {}, dismiss: {}))
        #expect(viewModel.text == "Installing…")
        viewModel.state = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
        #expect(viewModel.text == "Restart to Complete Update")
    }
    
    @Test func testNotFoundText() {
        let viewModel = UpdateViewModel()
        viewModel.state = .notFound(.init(acknowledgement: {}))
        #expect(viewModel.text == "No Updates Available")
    }
    
    @Test func testErrorText() {
        let viewModel = UpdateViewModel()
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network error"])
        viewModel.state = .error(.init(error: error, retry: {}, dismiss: {}))
        #expect(viewModel.text == "Network error")
    }
    
    // MARK: - Max Width Text Tests
    
    @Test func testMaxWidthTextForDownloading() {
        let viewModel = UpdateViewModel()
        viewModel.state = .downloading(.init(cancel: {}, expectedLength: 1000, progress: 50))
        #expect(viewModel.maxWidthText == "Downloading: 100%")
    }
    
    @Test func testMaxWidthTextForExtracting() {
        let viewModel = UpdateViewModel()
        viewModel.state = .extracting(.init(progress: 0.5))
        #expect(viewModel.maxWidthText == "Preparing: 100%")
    }
    
    @Test func testMaxWidthTextForNonProgressState() {
        let viewModel = UpdateViewModel()
        viewModel.state = .checking(.init(cancel: {}))
        #expect(viewModel.maxWidthText == viewModel.text)
    }
}
