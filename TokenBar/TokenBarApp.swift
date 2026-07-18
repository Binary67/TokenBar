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
    private let fiveHourLimitItem = NSMenuItem(title: "5-hour: Unavailable", action: nil, keyEquivalent: "")
    private let weeklyLimitItem = NSMenuItem(title: "Weekly: Unavailable", action: nil, keyEquivalent: "")
    private var iconAnimator: StatusIconAnimator?
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
        iconAnimator?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Loading Codex usage…"
        iconAnimator = StatusIconAnimator(button: button)

        summaryItem.isEnabled = false
        fiveHourLimitItem.isEnabled = false
        weeklyLimitItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(summaryItem)
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

        iconAnimator?.setStatus(snapshot.status)

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

    @objc private func refreshNow() {
        startMonitoring()
    }

    @objc private func systemDidWake() {
        startMonitoring()
    }

    @objc private func systemWillSleep() {
        iconAnimator?.stop()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        iconAnimator?.refreshAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class StatusIconAnimator {
    private let button: NSStatusBarButton
    private let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    private var animationTask: Task<Void, Never>?
    private var currentStatus: CodexStatus?
    private lazy var workingFrames = [
        "MoonWorking01",
        "MoonWorking02",
        "MoonWorking03",
        "MoonWorking04",
        "MoonWorking05",
        "MoonWorking06",
        "MoonWorking07",
        "MoonWorking08",
        "MoonWorking09",
        "MoonWorking10",
        "MoonWorking11",
        "MoonWorking12",
    ].compactMap(assetImage)

    init(button: NSStatusBarButton) {
        self.button = button
    }

    func setStatus(_ status: CodexStatus) {
        guard status != currentStatus else { return }

        animationTask?.cancel()
        animationTask = nil
        currentStatus = status
        button.setAccessibilityLabel(status.label)

        guard status == .working,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.image = staticImage(for: status)
            return
        }

        let frames = workingFrames

        guard !frames.isEmpty else {
            button.image = symbolImage(for: status)
            return
        }

        let button = button
        animationTask = Task {
            var frameIndex = 0

            while !Task.isCancelled {
                button.image = frames[frameIndex]
                frameIndex = (frameIndex + 1) % frames.count

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    func refreshAccessibilitySettings() {
        guard let currentStatus else { return }
        self.currentStatus = nil
        setStatus(currentStatus)
    }

    func stop() {
        animationTask?.cancel()
        animationTask = nil
        currentStatus = nil
    }

    private func staticImage(for status: CodexStatus) -> NSImage? {
        let assetName = switch status {
        case .working:
            "MoonWorking01"
        case .idle:
            "MoonIdle"
        case .error:
            "MoonError"
        case .unavailable:
            "MoonUnavailable"
        }

        return assetImage(named: assetName) ?? symbolImage(for: status)
    }

    private func assetImage(named name: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        image.isTemplate = true
        return image
    }

    private func symbolImage(for status: CodexStatus) -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.label
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}
