//
//  LegacyLengthEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// Hides icons by inflating the separator until everything on its hidden side
// leaves the visible bar. macOS <= 26 lays out any practical length. macOS 27
// instead ejects an over-long status item, which pushes nothing, so that system
// first calibrates the largest length WindowServer will still keep in the menu
// bar and reuses it until the display configuration changes.
final class LegacyLengthEngine: MenuBarEngine {
    private weak var items: MenuBarItemProvider?

    private let operatingSystemMajorVersion: () -> Int
    private let requestedCollapseLength: () -> CGFloat
    private let itemFrame: (NSStatusItem) -> CGRect?
    private let isLTR: () -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    private let expandedLength: CGFloat = 20
    private var calibratedCollapseLength: CGFloat?
    private var generation = 0

    private var alwaysHiddenEnabled = false
    private var separatorsHidden = false

    private(set) var state: MenuBarEngineState = .expanded

    init(items: MenuBarItemProvider,
         operatingSystemMajorVersion: @escaping () -> Int = {
             ProcessInfo.processInfo.operatingSystemVersion.majorVersion
         },
         requestedCollapseLength: @escaping () -> CGFloat = {
             let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
             return max(500, min(screenWidth * 2, 10_000))
         },
         itemFrame: @escaping (NSStatusItem) -> CGRect? = { $0.button?.window?.frame },
         isLTR: @escaping () -> Bool = { Constant.isUsingLTRLanguage },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
         }) {
        self.items = items
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
        self.requestedCollapseLength = requestedCollapseLength
        self.itemFrame = itemFrame
        self.isLTR = isLTR
        self.schedule = schedule
        items.separatorItem.length = expandedLength
        items.separatorItem.isVisible = true
    }

    private var needsCalibration: Bool {
        return operatingSystemMajorVersion() >= 27
    }

    private var effectiveCollapseLength: CGFloat {
        return calibratedCollapseLength ?? requestedCollapseLength()
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        switch state {
        case .collapsed:
            return completion(.collapsed)
        case .calibrating:
            return
        case .expanded, .unavailable:
            break
        }

        guard needsCalibration, calibratedCollapseLength == nil else {
            applyCollapsedPresentation()
            return completion(.collapsed)
        }

        // Measure the arrow-facing edge while the separator is still at its
        // resting width. A laid-out item grows away from this edge; an ejected
        // one lets the edge jump by approximately the requested length.
        guard let restingEdge = separatorEdgeFacingArrow() else {
            // The backing window can be absent very early during launch. Keep
            // the old behavior for this attempt; a later display invalidation or
            // relaunch can retry calibration without making the UI unresponsive.
            applyCollapsedPresentation()
            return completion(.collapsed)
        }

        state = .calibrating
        generation += 1
        let generation = self.generation
        binarySearchHonoredLength(restingEdge: restingEdge,
                                  upperBound: requestedCollapseLength(),
                                  generation: generation,
                                  completion: completion)
    }

    func expand() {
        generation += 1
        state = .expanded
        items?.separatorItem.length = expandedLength
        applyAlwaysHiddenPresentation()
    }

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool) {
        alwaysHiddenEnabled = enabled
        separatorsHidden = separatorHidden
        applyAlwaysHiddenPresentation()
    }

    var isArrangementValid: Bool {
        return MenuBarOrder.isItem(items?.separatorItem, onHiddenSideOf: items?.toggleItem)
    }

    var isAlwaysHiddenSeparatorPlaced: Bool {
        return MenuBarOrder.isItem(items?.alwaysHiddenItem, onHiddenSideOf: items?.separatorItem)
    }

    func invalidateLayout() {
        let shouldRecollapse = state == .collapsed || state == .calibrating
        generation += 1
        calibratedCollapseLength = nil
        guard shouldRecollapse else { return }

        state = .expanded
        items?.separatorItem.length = expandedLength
        schedule(0.1) { [weak self] in
            self?.collapse { _ in }
        }
    }

    private func applyCollapsedPresentation() {
        items?.separatorItem.length = effectiveCollapseLength
        state = .collapsed
        applyAlwaysHiddenPresentation()
    }

    private func applyAlwaysHiddenPresentation() {
        let length: CGFloat
        if separatorsHidden {
            length = alwaysHiddenEnabled ? effectiveCollapseLength : 0
        } else {
            length = alwaysHiddenEnabled ? expandedLength : 0
        }
        items?.alwaysHiddenItem?.length = length
    }

    private func separatorEdgeFacingArrow() -> CGFloat? {
        guard let separator = items?.separatorItem,
              let frame = itemFrame(separator) else { return nil }
        return isLTR() ? frame.maxX : frame.minX
    }

    private func isSeparatorLaidOut(restingEdge: CGFloat) -> Bool {
        guard let edge = separatorEdgeFacingArrow() else { return false }
        // The status window has roughly 8pt of padding. Half an icon leaves
        // enough tolerance for that padding without mistaking an ejected item
        // for one that WindowServer kept in the layout.
        return abs(edge - restingEdge) <= 24
    }

    private func binarySearchHonoredLength(restingEdge: CGFloat,
                                           upperBound: CGFloat,
                                           generation: Int,
                                           completion: @escaping (CollapseResult) -> Void) {
        var low = expandedLength
        var high = max(expandedLength, upperBound)
        var best = expandedLength
        var iterations = 0

        func finish() {
            guard generation == self.generation else { return }
            let calibrated = max(best, self.expandedLength + 1)
            self.calibratedCollapseLength = calibrated
            self.items?.separatorItem.length = calibrated
            self.state = .collapsed
            self.applyAlwaysHiddenPresentation()
            NSLog("HideMechanism: calibrated collapse length \(calibrated)pt (requested \(upperBound)pt)")
            if best <= self.expandedLength {
                NSLog("HideMechanism: no inflated length is laid out on this display")
            }
            completion(.collapsed)
        }

        func probeNext() {
            guard generation == self.generation else { return }
            guard iterations < 9, high - low > 8 else { return finish() }

            iterations += 1
            let candidate = ((low + high) / 2).rounded()
            self.items?.separatorItem.length = candidate
            self.schedule(0.25) { [weak self] in
                guard let self = self, generation == self.generation else { return }
                let laidOut = self.isSeparatorLaidOut(restingEdge: restingEdge)
                NSLog("HideMechanism: probe \(candidate)pt edge=\(self.separatorEdgeFacingArrow() ?? -1) resting=\(restingEdge) -> \(laidOut ? "laid out" : "ejected")")
                if laidOut {
                    best = candidate
                    low = candidate
                } else {
                    high = candidate
                }
                probeNext()
            }
        }

        probeNext()
    }
}
