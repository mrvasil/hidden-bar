//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit

private final class FullMenuBarAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class StatusBarController: MenuBarItemProvider {
    
    //MARK: - Variables
    private var timer:Timer? = nil
    
    //MARK: - BarItems
        
    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil

    var toggleItem: NSStatusItem { btnExpandCollapse }
    var separatorItem: NSStatusItem { btnSeparate }
    var alwaysHiddenItem: NSStatusItem? { btnAlwaysHidden }

    // The engine preserves separator-length hiding on older systems and
    // calibrates macOS 27's maximum in-layout length at runtime.
    private lazy var menuBarEngine: MenuBarEngine = MenuBarEngineFactory.make(items: self)
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        return menuBarEngine.state == .collapsed
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        return menuBarEngine.isAlwaysHiddenSeparatorPlaced
    }
    
    private var isToggle = false

    // AppKit does not expose which third-party status items were dropped because
    // the active application's menus consumed the available width. When the user
    // opts into the full-menu-bar mode, claim the menu bar before revealing the
    // hidden items and publish an empty main menu. This gives status items the
    // widest supported layout without touching another application's menu.
    private var standardMainMenu: NSMenu?
    private let expandedMainMenu = NSMenu(title: "Expanded Status Items")
    private var isUsingFullMenuBar = false
    private var fullMenuBarAnchorPanel: NSPanel?

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        let wc = PreferencesWindowController.shared
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
    }
    
    //MARK: - Methods
    init() {
        setupUI()
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }
        
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
            }
        }
    }
    
    @objc private func handleScreenParametersChanged() {
        let wasCollapsed = isCollapsed
        menuBarEngine.invalidateLayout()
        if wasCollapsed && Preferences.areSeparatorsHidden {
            menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: true)
        }
    }
    
    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
        // Construct the engine only after both items have their autosave names
        // and have been restored to the bar.
        _ = menuBarEngine
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
        }
        let menu = self.getContextMenu()
        btnSeparate.menu = menu

        updateAutoCollapseMenuTitle()
        
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        let eventDescription = NSApp.currentEvent.map {
            "type=\($0.type.rawValue) modifiers=\($0.modifierFlags.rawValue)"
        } ?? "nil"
        NSLog("FullMenuClick: event=\(eventDescription) collapsed=\(isCollapsed) toggle=\(isToggle) fullMode=\(Preferences.useFullStatusBarOnExpandEnabled)")

        if let event = NSApp.currentEvent {
            let isOptionKeyPressed = event.modifierFlags.contains(NSEvent.ModifierFlags.option)

            if event.type == NSEvent.EventType.leftMouseUp && !isOptionKeyPressed{
                self.expandCollapseIfNeeded()
            } else if event.type == NSEvent.EventType.rightMouseUp && !isOptionKeyPressed {
                // Right-click opens the same context menu the separator has (#356),
                // making settings reachable from the control everyone clicks.
                // The separators/always-hidden toggle stays on option-click.
                showContextMenu(from: sender)
            } else {
                // Both option+left and option+right land here: separators toggle.
                self.showHideSeparatorsAndAlwayHideArea()
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = btnSeparate.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }
    
    func showHideSeparatorsAndAlwayHideArea() {
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
        
        if self.isCollapsed {self.expandMenubar()}
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: false)
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: true)
    }
    
    func expandCollapseIfNeeded() {
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        self.isCollapsed ? self.expandMenubar() : self.collapseMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar() {
        guard menuBarEngine.isArrangementValid && !self.isCollapsed else {
            restoreApplicationMenuIfNeeded()
            autoCollapseIfNeeded()
            return
        }

        menuBarEngine.collapse { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .collapsed:
                if let button = self.btnExpandCollapse.button {
                    button.image = Assets.expandImage
                }
                self.restoreApplicationMenuIfNeeded()
            case .unavailable:
                if let button = self.btnExpandCollapse.button {
                    button.image = Assets.collapseImage
                }
                self.restoreApplicationMenuIfNeeded()
                self.autoCollapseIfNeeded()
            }
        }
    }

    private func expandMenubar() {
        guard self.isCollapsed else {return}

        if Preferences.useFullStatusBarOnExpandEnabled {
            // A status-item mouse-up does not make its accessory app active.
            // Finish the click first, then request a coordinated activation from
            // the app that currently owns the menu bar. Reveal only after AppKit
            // confirms the transfer via didBecomeActiveNotification.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCollapsed else { return }
                self.prepareFullMenuBarForExpansion()
                DispatchQueue.main.async { [weak self] in
                    self?.requestFullMenuBarActivation()
                }
            }
        } else {
            revealExpandedMenuBar()
        }
    }

    private func revealExpandedMenuBar() {
        guard self.isCollapsed else {return}
        menuBarEngine.expand()
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
        autoCollapseIfNeeded()
    }

    private func prepareFullMenuBarForExpansion() {
        guard !isUsingFullMenuBar else { return }

        standardMainMenu = NSApp.mainMenu
        NSApp.mainMenu = expandedMainMenu
        isUsingFullMenuBar = true
        showFullMenuBarAnchor()
        traceFullMenuBarAnchor(stage: "shown-accessory")
        NSApp.setActivationPolicy(.regular)
        traceFullMenuBarAnchor(stage: "after-regular-policy")
    }

    private func showFullMenuBarAnchor() {
        let panel: NSPanel
        if let existingPanel = fullMenuBarAnchorPanel {
            panel = existingPanel
        } else {
            // Order this key-capable window into the clicked fullscreen Space
            // while Hidden Bar is still an accessory app. Switching to regular
            // policy first makes WindowServer attach a newly created window to
            // Hidden Bar's ordinary Space instead.
            panel = FullMenuBarAnchorPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .black
            panel.alphaValue = 0.01
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.isExcludedFromWindowsMenu = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .canJoinAllApplications,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle
            ]
            panel.level = .statusBar
            fullMenuBarAnchorPanel = panel
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen = screen {
            panel.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        panel.orderFrontRegardless()
    }

    private func requestFullMenuBarActivation() {
        guard isUsingFullMenuBar, isCollapsed else { return }

        if NSApp.isActive {
            revealExpandedMenuBar()
            return
        }

        // activate(from:) can report success without transferring either
        // frontmost or menu-bar ownership on macOS 27. The NSApplication path
        // still performs that transfer, and the anchor panel keeps it in the
        // clicked Space (including a fullscreen Space).
        NSApp.activate(ignoringOtherApps: true)

        // Activation can be denied by the system. Bound the request so the
        // arrow never remains stuck and regular activation policy is restored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self,
                  self.isUsingFullMenuBar,
                  self.isCollapsed,
                  !NSApp.isActive else { return }
            self.fallBackToStandardExpansion()
        }
    }

    private func fallBackToStandardExpansion() {
        restoreApplicationMenuIfNeeded()
        if isCollapsed {
            revealExpandedMenuBar()
        }
    }

    @objc private func applicationDidBecomeActive() {
        if isUsingFullMenuBar && isCollapsed {
            traceFullMenuBarAnchor(stage: "did-become-active")
            fullMenuBarAnchorPanel?.makeKeyAndOrderFront(nil)
            traceFullMenuBarAnchor(stage: "made-key")
            revealExpandedMenuBar()
        }
    }

    private func traceFullMenuBarAnchor(stage: String) {
        guard let panel = fullMenuBarAnchorPanel else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let owner = NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier ?? "nil"
        NSLog("FullMenuAnchor: stage=\(stage) visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) key=\(panel.isKeyWindow) active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) front=\(frontmost) owner=\(owner)")
    }

    private func restoreApplicationMenuIfNeeded() {
        guard isUsingFullMenuBar else { return }
        fullMenuBarAnchorPanel?.orderOut(nil)

        if let standardMainMenu = standardMainMenu {
            NSApp.mainMenu = standardMainMenu
        }
        standardMainMenu = nil
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
        isUsingFullMenuBar = false
    }
    
    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers.
            if self.isMouseInMenuBar || self.isPreferencesWindowVisible {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }
    
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()
        
        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)
        
        let toggleAutoHideItem = NSMenuItem(title: "Toggle Auto Collapse".localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        toggleAutoHideItem.tag = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    private func updateAutoCollapseMenuTitle() {
        guard let toggleAutoHideItem = btnSeparate.menu?.item(withTag: 1) else { return }
        if Preferences.isAutoHide {
            toggleAutoHideItem.title = "Disable Auto Collapse".localized
        } else {
            toggleAutoHideItem.title = "Enable Auto Collapse".localized
        }
    }
    
    @objc func updateAutoHide() {
        updateAutoCollapseMenuTitle()
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        if Preferences.alwaysHiddenSectionEnabled {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = NSStatusBar.system.statusItem(withLength: 0)
            menuBarEngine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
            }
            self.btnAlwaysHidden?.autosaveName = "hiddenbar_terminate"
            self.btnAlwaysHidden?.isVisible = true
        } else {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
            menuBarEngine.updateAlwaysHiddenSection(enabled: false, separatorHidden: Preferences.areSeparatorsHidden)
        }
    }
}
