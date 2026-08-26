import Testing
import AppKit
@testable import Ghostty

@Suite
struct TerminalRestorableTests {
    @Test
    func areYouForgettingToAddMigrationTests() {
        #expect(TerminalRestorableState.version == 7)
        #expect(TerminalRestorableState.minimumVersion == 5)

        #expect(QuickTerminalRestorableState.version == 1)
        #expect(QuickTerminalRestorableState.minimumVersion == 1)
    }

    @MainActor
    @Test func quickTerminalRestorableFromV1() throws {
        /* v1
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let state = DummyQuickTerminalRestorableState(
            focusedSurface: "123",
            surfaceTree: tree.0,
            screenStateEntries: [:],
        )
        let data = try archive(CodableBridge(state), className: "CodableBridge<QuickTerminal>")
        print(data.base64EncodedString())
        print(tree.1.id)
        print(tree.2.id)
        */

        let decoded: CodableBridge<DummyQuickTerminalRestorableState> = try unarchive(v1QTData, className: "CodableBridge<QuickTerminal>")
        let state = decoded.value.internalState

        #expect(state.focusedSurface == "123")
        #expect(state.screenStateEntries.isEmpty)
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "2F2F2D93-944C-474A-83BA-4DC1868C3EB9" }))
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "994C673F-B4C5-49EE-B044-65006652636D" }))
    }

    // To generate old data: created a dummy class, archive, and copy the printed result
    @MainActor
    @Test func restoreTerminal57() throws {

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            focusedSurface: "v5",
//            surfaceTree: tree.0,
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v5 = try unarchive(v5Data, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v5.focusedSurface == "v5")
        #expect(v5.effectiveFullscreenMode == nil)
        #expect(v5.tabColor == nil)
        #expect(v5.titleOverride == nil)
        #expect(v5.surfaceTree.contains(where: { $0.id.uuidString == "926F3F2A-824C-40C9-87CA-2CDCA4E11049" }))
        #expect(v5.surfaceTree.contains(where: { $0.id.uuidString == "AC5E829B-85FD-4C69-B196-2EE469C72A90" }))

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            focusedSurface: "v7",
//            surfaceTree: tree.0,
//            effectiveFullscreenMode: .native,
//            tabColor: .green,
//            titleOverride: "1.3.0"
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v7 = try unarchive(v7Data, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v7.focusedSurface == "v7")
        #expect(v7.effectiveFullscreenMode == .native)
        #expect(v7.tabColor == .green)
        #expect(v7.titleOverride == "1.3.0")
        #expect(v7.surfaceTree.contains(where: { $0.id.uuidString == "5D580A7A-81EA-47C6-BB9A-AD4B1783E478" }))
        #expect(v7.surfaceTree.contains(where: { $0.id.uuidString == "96EA1189-7482-41BC-A6CD-26E5190E4BFA" }))

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            .init(
//                focusedSurface: "v7 generic",
//                surfaceTree: tree.0,
//                effectiveFullscreenMode: .native,
//                tabColor: .green,
//                titleOverride: "tip"
//            )
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v7Generic = try unarchive(v7GenericData, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v7Generic.focusedSurface == "v7 generic")
        #expect(v7Generic.effectiveFullscreenMode == .native)
        #expect(v7Generic.tabColor == .green)
        #expect(v7Generic.titleOverride == "tip")
        #expect(v7Generic.surfaceTree.contains(where: { $0.id.uuidString == "953CE952-D91D-4D36-AC72-9D0F1F6BCE73" }))
        #expect(v7Generic.surfaceTree.contains(where: { $0.id.uuidString == "D3223569-2E01-4BC5-9DB2-DBFC3AFF46D1" }))
    }
}

private extension TerminalRestorableTests {
    func archive<T: NSObject & NSSecureCoding>(_ obj: T, className: String?) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        defer { archiver.finishEncoding() }
        if let className {
            archiver.setClassName(className, for: T.self)
        }
        archiver.encode(obj, forKey: NSKeyedArchiveRootObjectKey)
        return archiver.encodedData
    }

    func unarchive<T: NSObject & NSSecureCoding>(_ data: Data, className: String?, as: T.Type = T.self) throws -> T {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding()}
        if let className {
            unarchiver.setClass(T.self, forClassName: className)
        }
        unarchiver.requiresSecureCoding = true
        let result = unarchiver.decodeObject(of: T.self, forKey: NSKeyedArchiveRootObjectKey)
        return try #require(result)
    }
}

// MARK: - Dummy States

@MainActor
private final class DummyTerminalRestorableState: TerminalRestorable {
    static var version: Int {
        TerminalRestorableState.version
    }

    static var minimumVersion: Int {
        TerminalRestorableState.minimumVersion
    }

    required init(copy other: DummyTerminalRestorableState) {
        internalState = other.internalState
    }

    let internalState: TerminalRestorableState.InternalState<MockView>

    init(_ internalState: TerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    required init(from decoder: any Decoder) throws {
        self.internalState = try TerminalRestorableState.InternalState<MockView>(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

@MainActor
struct DummyQuickTerminalRestorableState: TerminalRestorable {
    static var version: Int = QuickTerminalRestorableState.version

    static var minimumVersion: Int = QuickTerminalRestorableState.minimumVersion

    init(copy other: DummyQuickTerminalRestorableState) {
        internalState = other.internalState
    }

    let internalState: QuickTerminalRestorableState.InternalState<MockView>

    init(_ internalState: QuickTerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    init(from decoder: any Decoder) throws {
        self.internalState = try QuickTerminalRestorableState.InternalState<MockView>(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

// MARK: - QuickTerminal V1 (1.3.0)

private let v1QTData = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA6hicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECALDBkaGxwfJicvMDEyODlFRkdISU9QVldYXF1jaWpwcVUkbnVsbNMNDg8QFBhXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6MREhOAAoADgASjFRYXgAWAB4AIgBhfEBJzY3JlZW5TdGF0ZUVudHJpZXNeZm9jdXNlZFN1cmZhY2Vbc3VyZmFjZVRyZWXSDg8dHqCABtIgISIjWiRjbGFzc25hbWVYJGNsYXNzZXNeTlNNdXRhYmxlQXJyYXmjIiQlV05TQXJyYXlYTlNPYmplY3RTMTIz0w0ODygrGKIpKoAJgAqiLC2AC4AMgBhXdmVyc2lvblRyb290EAHTDQ4PMzUYoTSADaE2gA6AGFVzcGxpdNMNDg86PxikOzw9PoAPgBCAEYASpEBBQkOAE4AZgBqAHYAYVXJpZ2h0VXJhdGlvVGxlZnRZZGlyZWN0aW9u0w0OD0pMGKFLgBShTYAVgBhUdmlld9MNDg9RUxihUoAWoVSAF4AYUmlkXxAkOTk0QzY3M0YtQjRDNS00OUVFLUIwNDQtNjUwMDY2NTI2MzZE0iAhWVpfEBNOU011dGFibGVEaWN0aW9uYXJ5o1lbJVxOU0RpY3Rpb25hcnkjP+AAAAAAAADTDQ4PXmAYoUuAFKFhgBuAGNMNDg9kZhihUoAWoWeAHIAYXxAkMkYyRjJEOTMtOTQ0Qy00NzRBLTgzQkEtNERDMTg2OEMzRUI50w0OD2ttGKFsgB6hboAfgBhaaG9yaXpvbnRhbNMNDg9ycxigoIAYAAgAEQAaACQAKQAyADcASQBMAFIAVAB3AH0AhACMAJcAngCiAKQApgCoAKwArgCwALIAtADJANgA5ADpAOoA7ADxAPwBBQEUARgBIAEpAS0BNAE3ATkBOwE+AUABQgFEAUwBUQFTAVoBXAFeAWABYgFkAWoBcQF2AXgBegF8AX4BgwGFAYcBiQGLAY0BkwGZAZ4BqAGvAbEBswG1AbcBuQG+AcUBxwHJAcsBzQHPAdIB+QH+AhQCGAIlAi4CNQI3AjkCOwI9Aj8CRgJIAkoCTAJOAlACdwJ+AoACggKEAoYCiAKTApoCmwKcAAAAAAAAAgEAAAAAAAAAdQAAAAAAAAAAAAAAAAAAAp7RExRaJGNsYXNzbmFtZV8QHENvZGFibGVCcmlkZ2U8UXVpY2tUZXJtaW5hbD4ACAARABoAJAApADIANwBJAEwAUQBTAFgAXgBjAGgAbwBxAHMEHwQiBC0AAAAAAAACAQAAAAAAAAAVAAAAAAAAAAAAAAAAAAAETA==
    """)!

// MARK: - Terminal V5 (1.2.3)

private let v5Data = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA01icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvEB0LDBcYGRoiIyQlKyw4OTo7PEJDSUpLUlNZX2BmZ1UkbnVsbNMNDg8QExZXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6IREoACgAOiFBWABIAFgBVeZm9jdXNlZFN1cmZhY2Vbc3VyZmFjZVRyZWVSdjXTDQ4PGx4WohwdgAaAB6IfIIAIgAmAFVd2ZXJzaW9uVHJvb3QQAdMNDg8mKBahJ4AKoSmAC4AVVXNwbGl00w0ODy0yFqQuLzAxgAyADYAOgA+kMzQ1NoAQgBaAF4AagBVVcmlnaHRVcmF0aW9UbGVmdFlkaXJlY3Rpb27TDQ4PPT8WoT6AEaFAgBKAFVR2aWV30w0OD0RGFqFFgBOhR4AUgBVSaWRfECRBQzVFODI5Qi04NUZELTRDNjktQjE5Ni0yRUU0NjlDNzJBOTDSTE1OT1okY2xhc3NuYW1lWCRjbGFzc2VzXxATTlNNdXRhYmxlRGljdGlvbmFyeaNOUFFcTlNEaWN0aW9uYXJ5WE5TT2JqZWN0Iz/gAAAAAAAA0w0OD1RWFqE+gBGhV4AYgBXTDQ4PWlwWoUWAE6FdgBmAFV8QJDkyNkYzRjJBLTgyNEMtNDBDOS04N0NBLTJDRENBNEUxMTA0OdMNDg9hYxahYoAboWSAHIAVWmhvcml6b250YWzTDQ4PaGkWoKCAFQAIABEAGgAkACkAMgA3AEkATABSAFQAdAB6AIEAiQCUAJsAngCgAKIApQCnAKkAqwC6AMYAyQDQANMA1QDXANoA3ADeAOAA6ADtAO8A9gD4APoA/AD+AQABBgENARIBFAEWARgBGgEfASEBIwElAScBKQEvATUBOgFEAUsBTQFPAVEBUwFVAVoBYQFjAWUBZwFpAWsBbgGVAZoBpQGuAcQByAHVAd4B5wHuAfAB8gH0AfYB+AH/AgECAwIFAgcCCQIwAjcCOQI7Aj0CPwJBAkwCUwJUAlUAAAAAAAACAQAAAAAAAABrAAAAAAAAAAAAAAAAAAACV9ETFFokY2xhc3NuYW1lXxAXQ29kYWJsZUJyaWRnZTxUZXJtaW5hbD4ACAARABoAJAApADIANwBJAEwAUQBTAFgAXgBjAGgAbwBxAHMDxAPHA9IAAAAAAAACAQAAAAAAAAAVAAAAAAAAAAAAAAAAAAAD7A==
    """)!

// MARK: - Terminal V7 (1.3.0)

private let v7Data = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA71icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECMLDB0eHyAhIiMkLC0uLzU2QkNERUZMTVNUVVxdY2lqcHF1dlUkbnVsbNMNDg8QFhxXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6UREhMUFYACgAOABIAFgAalFxgZGhuAB4AIgAmAIYAigBlfEBdlZmZlY3RpdmVGdWxsc2NyZWVuTW9kZV5mb2N1c2VkU3VyZmFjZVtzdXJmYWNlVHJlZVh0YWJDb2xvcl10aXRsZU92ZXJyaWRlVm5hdGl2ZVJ2N9MNDg8lKByiJieACoALoikqgAyADYAZV3ZlcnNpb25Ucm9vdBAB0w0ODzAyHKExgA6hM4APgBlVc3BsaXTTDQ4PNzwcpDg5OjuAEIARgBKAE6Q9Pj9AgBSAGoAbgB6AGVVyaWdodFVyYXRpb1RsZWZ0WWRpcmVjdGlvbtMNDg9HSRyhSIAVoUqAFoAZVHZpZXfTDQ4PTlAcoU+AF6FRgBiAGVJpZF8QJDk2RUExMTg5LTc0ODItNDFCQy1BNkNELTI2RTUxOTBFNEJGQdJWV1hZWiRjbGFzc25hbWVYJGNsYXNzZXNfEBNOU011dGFibGVEaWN0aW9uYXJ5o1haW1xOU0RpY3Rpb25hcnlYTlNPYmplY3QjP+AAAAAAAADTDQ4PXmAcoUiAFaFhgByAGdMNDg9kZhyhT4AXoWeAHYAZXxAkNUQ1ODBBN0EtODFFQS00N0M2LUJCOUEtQUQ0QjE3ODNFNDc40w0OD2ttHKFsgB+hboAggBlaaG9yaXpvbnRhbNMNDg9ycxygoIAZEAdVMS4zLjAACAARABoAJAApADIANwBJAEwAUgBUAHoAgACHAI8AmgChAKcAqQCrAK0ArwCxALcAuQC7AL0AvwDBAMMA3QDsAPgBAQEPARYBGQEgASMBJQEnASoBLAEuATABOAE9AT8BRgFIAUoBTAFOAVABVgFdAWIBZAFmAWgBagFvAXEBcwF1AXcBeQF/AYUBigGUAZsBnQGfAaEBowGlAaoBsQGzAbUBtwG5AbsBvgHlAeoB9QH+AhQCGAIlAi4CNwI+AkACQgJEAkYCSAJPAlECUwJVAlcCWQKAAocCiQKLAo0CjwKRApwCowKkAqUCpwKpAAAAAAAAAgEAAAAAAAAAdwAAAAAAAAAAAAAAAAAAAq/RExRaJGNsYXNzbmFtZV8QF0NvZGFibGVCcmlkZ2U8VGVybWluYWw+AAgAEQAaACQAKQAyADcASQBMAFEAUwBYAF4AYwBoAG8AcQBzBDQENwRCAAAAAAAAAgEAAAAAAAAAFQAAAAAAAAAAAAAAAAAABFw=
    """)!

// MARK: - Terminal V7 Generic (tip)

private let v7GenericData = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA8NicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECMLDB0eHyAhIiMkLC0uLzU2QkNERUZMTVNUVVxdY2lqcHF1dlUkbnVsbNMNDg8QFhxXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6UREhMUFYACgAOABIAFgAalFxgZGhuAB4AIgAmAIYAigBlfEBdlZmZlY3RpdmVGdWxsc2NyZWVuTW9kZV5mb2N1c2VkU3VyZmFjZVtzdXJmYWNlVHJlZVh0YWJDb2xvcl10aXRsZU92ZXJyaWRlVm5hdGl2ZVp2NyBnZW5lcmlj0w0ODyUoHKImJ4AKgAuiKSqADIANgBlXdmVyc2lvblRyb290EAHTDQ4PMDIcoTGADqEzgA+AGVVzcGxpdNMNDg83PBykODk6O4AQgBGAEoATpD0+P0CAFIAagBuAHoAZVXJpZ2h0VXJhdGlvVGxlZnRZZGlyZWN0aW9u0w0OD0dJHKFIgBWhSoAWgBlUdmlld9MNDg9OUByhT4AXoVGAGIAZUmlkXxAkRDMyMjM1NjktMkUwMS00QkM1LTlEQjItREJGQzNBRkY0NkQx0lZXWFlaJGNsYXNzbmFtZVgkY2xhc3Nlc18QE05TTXV0YWJsZURpY3Rpb25hcnmjWFpbXE5TRGljdGlvbmFyeVhOU09iamVjdCM/4AAAAAAAANMNDg9eYByhSIAVoWGAHIAZ0w0OD2RmHKFPgBehZ4AdgBlfECQ5NTNDRTk1Mi1EOTFELTREMzYtQUM3Mi05RDBGMUY2QkNFNzPTDQ4Pa20coWyAH6FugCCAGVpob3Jpem9udGFs0w0OD3JzHKCggBkQB1N0aXAACAARABoAJAApADIANwBJAEwAUgBUAHoAgACHAI8AmgChAKcAqQCrAK0ArwCxALcAuQC7AL0AvwDBAMMA3QDsAPgBAQEPARYBIQEoASsBLQEvATIBNAE2ATgBQAFFAUcBTgFQAVIBVAFWAVgBXgFlAWoBbAFuAXABcgF3AXkBewF9AX8BgQGHAY0BkgGcAaMBpQGnAakBqwGtAbIBuQG7Ab0BvwHBAcMBxgHtAfIB/QIGAhwCIAItAjYCPwJGAkgCSgJMAk4CUAJXAlkCWwJdAl8CYQKIAo8CkQKTApUClwKZAqQCqwKsAq0CrwKxAAAAAAAAAgEAAAAAAAAAdwAAAAAAAAAAAAAAAAAAArXRExRaJGNsYXNzbmFtZV8QF0NvZGFibGVCcmlkZ2U8VGVybWluYWw+AAgAEQAaACQAKQAyADcASQBMAFEAUwBYAF4AYwBoAG8AcQBzBDoEPQRIAAAAAAAAAgEAAAAAAAAAFQAAAAAAAAAAAAAAAAAABGI=
    """)!
