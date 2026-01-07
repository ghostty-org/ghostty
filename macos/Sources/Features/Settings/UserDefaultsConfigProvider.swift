//
//  UserDefaultsConfigProvider.swift
//  Ghostty
//
//  Created by luca on 02.11.2025.
//

import Foundation

class UserDefaultsConfigProvider: GhosttyConfigPersistProvider {
    let keyPrefix = "ghostty_config_key_"
    func set(_ value: [String], for key: String) {
        UserDefaults.standard.set(value, forKey: keyPrefix + key)
    }

    func get(for key: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: keyPrefix + key)
    }

    @concurrent
    func export() async -> Data? {
        let contents = UserDefaults.standard.dictionaryRepresentation()
            .filter({ $0.key.hasPrefix(keyPrefix) })
            .compactMap({ pair -> (key: String, value: [String])? in
                guard let stringArray = pair.value as? [String] else { return nil }
                return (key: pair.key.replacingOccurrences(of: keyPrefix, with: ""), value: stringArray)
            })
            .sorted(by: { $0.key > $1.key })
            .map { pair -> String in
                pair.value.map({ "\(pair.key) = \($0)" }).joined(separator: "\n")
            }
            .joined(separator: "\n")

        return contents.data(using: .utf8)
    }
}
