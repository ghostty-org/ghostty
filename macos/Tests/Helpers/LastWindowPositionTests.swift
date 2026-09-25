//
//  LastWindowPositionTests.swift
//  Ghostty
//
//  Created by Lukas on 04.03.2026.
//

import Testing
import AppKit
@testable import Ghostty

@Suite(.serialized)
struct LastWindowPositionTests {
    func usingTemporaryHelper(_ perform: (_ helper: LastWindowPosition) throws -> Void) rethrows {
        let defaults = MockDefaults()
        try perform(LastWindowPosition(defaults: defaults))
        defaults.reset()
    }

    @Test func restorePoint() throws {
        try usingTemporaryHelper { helper in
            helper.defaults.set([20, 20], forKey: "NSWindowLastPosition")
            let rect = try #require(helper.savedWindowRectInfo.values.first)
            #expect(rect == CGRect(x: 20, y: 20, width: 0, height: 0))
        }
    }

    @Test func restoreRect() throws {
        try usingTemporaryHelper { helper in
            helper.defaults.set([20, 20, 30, 30], forKey: "NSWindowLastPosition")
            let rect = try #require(helper.savedWindowRectInfo.values.first)
            #expect(rect == CGRect(x: 20, y: 20, width: 30, height: 30))
        }
    }

    @Test func restoreScreenByRect() throws {
        usingTemporaryHelper { helper in
            helper.defaults.set([
                "main": CGRect(x: 20, y: 20, width: 30, height: 30).dictionaryRepresentation
            ], forKey: "NSWindowLastRectsByScreen")
            #expect(helper.savedWindowRectInfo == [
                "main": CGRect(x: 20, y: 20, width: 30, height: 30)
            ])
        }
    }
}

class MockDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    func reset() {
        values.removeAll()
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        values[defaultName] as? [String: Any]
    }

    override func array(forKey defaultName: String) -> [Any]? {
        values[defaultName] as? [Any]
    }
}
