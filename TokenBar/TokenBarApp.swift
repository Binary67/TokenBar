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
    private let apiEquivalentCostItem = NSMenuItem(
        title: "API equivalent today: Unavailable",
        action: nil,
        keyEquivalent: ""
    )
    private let fiveHourLimitItem = NSMenuItem(title: "5-hour: Unavailable", action: nil, keyEquivalent: "")
    private let weeklyLimitItem = NSMenuItem(title: "Weekly: Unavailable", action: nil, keyEquivalent: "")
    private let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
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
        apiEquivalentCostItem.isEnabled = false
        apiEquivalentCostItem.toolTip = "Estimated using standard OpenAI API prices as of July 18, 2026; excludes codex-auto-review usage; ChatGPT billing may differ."
        fiveHourLimitItem.isEnabled = false
        weeklyLimitItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(summaryItem)
        menu.addItem(apiEquivalentCostItem)
        menu.addItem(fiveHourLimitItem)
        menu.addItem(weeklyLimitItem)
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

        setStatusIcon(snapshot.status)

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
        apiEquivalentCostItem.title = apiEquivalentCostTitle(snapshot.estimatedAPICostUSD)
        fiveHourLimitItem.title = rateLimitTitle(
            "5-hour",
            window: snapshot.fiveHourLimit,
            includesDate: false
        )
        weeklyLimitItem.title = rateLimitTitle(
            "Weekly",
            window: snapshot.weeklyLimit,
            includesDate: true
        )
    }

    private func apiEquivalentCostTitle(_ cost: Decimal?) -> String {
        guard let cost else { return "API equivalent today: Unavailable" }

        let costText = cost.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(4))
        )
        return "API equivalent today: \(costText)"
    }

    private func rateLimitTitle(
        _ label: String,
        window: CodexRateLimitWindow?,
        includesDate: Bool
    ) -> String {
        guard let window else { return "\(label): Unavailable" }

        guard let resetsAt = window.resetsAt else {
            return "\(label): \(window.percentLeft)% left"
        }

        let resetText = includesDate
            ? resetsAt.formatted(date: .abbreviated, time: .shortened)
            : resetsAt.formatted(date: .omitted, time: .shortened)
        return "\(label): \(window.percentLeft)% left — resets \(resetText)"
    }

    private func setStatusIcon(_ status: CodexStatus) {
        guard let button = statusItem.button,
              let image = NSImage(
                  systemSymbolName: status.symbolName,
                  accessibilityDescription: status.label
              )?.withSymbolConfiguration(iconConfiguration) else {
            return
        }

        image.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(status.label)
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
