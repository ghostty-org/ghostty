//
//  DefaultConfigProvider.swift
//  GhosttyKit
//
//  Created by luca on 24.09.2025.
//

@testable import GhosttyKit
import Foundation

class DefaultConfigProvider {
    private var config: ghostty_config_t? {
        didSet {
            // Free the old value whenever we change
            guard let old = oldValue else { return }
            ghostty_config_free(old)
        }
    }

    init() {
        guard
            let cfg = ghostty_config_new()
        else {
            fatalError("Failed to create ghostty config")
        }
        if !isRunningInXcode() {
            ghostty_config_load_cli_args(cfg)
        }

        // Finalize to make defaults available
        ghostty_config_finalize(cfg)
        self.config = cfg
    }

    deinit {
        self.config = nil
    }

    func getColor(_ key: String) -> ghostty_config_color_s? {
        guard let config = config else { return nil }
        var value: ghostty_config_color_s?
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return value
    }
}
