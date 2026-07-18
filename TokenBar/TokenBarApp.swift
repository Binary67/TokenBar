//
//  TokenBarApp.swift
//  TokenBar
//
//  Created by Frank on 18/07/2026.
//

import AppKit
import SwiftUI

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = CodexMonitor()
    private let summaryItem = NSMenuItem(title: "Loading Codex usage…", action: nil, keyEquivalent: "")
    private var monitoringTask: Task<Void, Never>?
    private var snapshot = TokenBarSnapshot(status: .unavailable, todayTokens: 0, lastUpdated: .now)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Loading Codex usage…"

        summaryItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit TokenBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        apply(snapshot)
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self, monitor] in
            await monitor.run { snapshot in
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: TokenBarSnapshot) {
        self.snapshot = snapshot

        let tokenText = snapshot.status == .unavailable
            ? "—"
            : TokenTextFormatter.compact(snapshot.todayTokens)
        let exactTokenText = TokenTextFormatter.exact(snapshot.todayTokens)
        let detail = snapshot.status == .unavailable
            ? "Codex data unavailable"
            : "\(snapshot.status.label) — \(exactTokenText) tokens today"

        if let image = NSImage(
            systemSymbolName: snapshot.status.symbolName,
            accessibilityDescription: snapshot.status.label
        ) {
            image.isTemplate = true
            statusItem.button?.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            )
        }

        statusItem.button?.attributedTitle = NSAttributedString(
            string: tokenText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                )
            ]
        )
        statusItem.button?.toolTip = detail
        summaryItem.title = detail
    }

    @objc private func refreshNow() {
        startMonitoring()
    }

    @objc private func systemDidWake() {
        startMonitoring()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
