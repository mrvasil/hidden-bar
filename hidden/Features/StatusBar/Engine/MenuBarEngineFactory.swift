//
//  MenuBarEngineFactory.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import Foundation

// The single place that picks a hiding mechanism for the running OS.
enum MenuBarEngineFactory {
    static func make(items: MenuBarItemProvider) -> MenuBarEngine {
        // LegacyLengthEngine calibrates macOS 27's ejection cutoff at runtime,
        // while preserving the original behavior on older systems. Unlike the
        // assessment-mode engine it also works in ad-hoc local builds and never
        // hides Hidden Bar's own arrow because of code-signing/LaunchServices
        // identity mismatches.
        return LegacyLengthEngine(items: items)
    }
}
