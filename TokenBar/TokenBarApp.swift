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
    private let usageOverviewItem = NSMenuItem()
    private let fiveHourLimitItem = NSMenuItem(title: "5-hour: Unavailable", action: nil, keyEquivalent: "")
    private let weeklyLimitItem = NSMenuItem(title: "Weekly: Unavailable", action: nil, keyEquivalent: "")
    private let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    private var usageOverviewHostingView: NSHostingView<UsageOverviewView>?
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

        fiveHourLimitItem.isEnabled = false
        weeklyLimitItem.isEnabled = false

        let overviewHostingView = NSHostingView(
            rootView: UsageOverviewView(snapshot: snapshot)
        )
        overviewHostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 258)
        usageOverviewItem.view = overviewHostingView
        usageOverviewHostingView = overviewHostingView

        let menu = NSMenu()
        menu.addItem(usageOverviewItem)
        menu.addItem(.separator())
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
        usageOverviewHostingView?.rootView = UsageOverviewView(snapshot: snapshot)
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

private struct UsageOverviewView: View {
    let snapshot: TokenBarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sol, Terra & Luna")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .top, spacing: 24) {
                UsageMetricColumn(
                    costLabel: "Today cost",
                    cost: snapshot.estimatedAPICostUSD,
                    tokenLabel: "Today tokens",
                    tokens: snapshot.trackedTodayTokens,
                    isAvailable: snapshot.status != .unavailable
                )
                UsageMetricColumn(
                    costLabel: "Last 30 days cost",
                    cost: snapshot.last30DaysAPICostUSD,
                    tokenLabel: "Last 30 days tokens",
                    tokens: snapshot.last30DaysTokens,
                    isAvailable: snapshot.status != .unavailable
                )
            }

            StackedUsageChart(days: snapshot.dailyUsage)

            HStack(spacing: 12) {
                ForEach(CodexTrackedModel.allCases, id: \.rawValue) { model in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.chartColor)
                            .frame(width: 7, height: 7)
                        Text(model.label)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("API-equivalent estimate · other models excluded")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(
                    "Estimated using standard OpenAI API prices as of July 18, 2026; "
                        + "ChatGPT billing may differ."
                )
        }
        .padding(12)
        .frame(width: 360, height: 258, alignment: .topLeading)
    }
}

private struct UsageMetricColumn: View {
    let costLabel: String
    let cost: Decimal?
    let tokenLabel: String
    let tokens: Int64
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(costLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(UsageValueFormatter.cost(cost))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Text(tokenLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(isAvailable ? TokenTextFormatter.compact(tokens) : "Unavailable")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .help(isAvailable ? "\(TokenTextFormatter.exact(tokens)) tokens" : "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StackedUsageChart: View {
    let days: [CodexDailyUsage]

    private let chartHeight: CGFloat = 58

    var body: some View {
        VStack(spacing: 3) {
            if days.isEmpty {
                Text("Usage history unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { day in
                        DailyUsageBar(
                            usage: day,
                            maximumTokens: days.map(\.totalTokens).max() ?? 0,
                            chartHeight: chartHeight
                        )
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)

                HStack {
                    Text("30 days ago")
                    Spacer()
                    Text("Today")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct DailyUsageBar: View {
    let usage: CodexDailyUsage
    let maximumTokens: Int64
    let chartHeight: CGFloat

    private var barHeight: CGFloat {
        guard maximumTokens > 0, usage.totalTokens > 0 else { return 1 }
        return max(2, CGFloat(Double(usage.totalTokens) / Double(maximumTokens)) * chartHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CodexTrackedModel.allCases, id: \.rawValue) { model in
                let modelUsage = usage.usage(for: model)
                model.chartColor
                    .frame(
                        height: usage.totalTokens == 0
                            ? 0
                            : barHeight * CGFloat(
                                Double(modelUsage.tokens) / Double(usage.totalTokens)
                            )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: barHeight, alignment: .bottom)
        .background(usage.totalTokens == 0 ? Color.secondary.opacity(0.16) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(height: chartHeight, alignment: .bottom)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        var lines = [
            usage.day.formatted(date: .abbreviated, time: .omitted),
            "Total: \(TokenTextFormatter.exact(usage.totalTokens)) tokens",
        ]
        for model in CodexTrackedModel.allCases {
            let modelUsage = usage.usage(for: model)
            lines.append(
                "\(model.label): \(TokenTextFormatter.exact(modelUsage.tokens)) · "
                    + UsageValueFormatter.cost(modelUsage.estimatedAPICostUSD)
            )
        }
        return lines.joined(separator: "\n")
    }
}

private enum UsageValueFormatter {
    static func cost(_ cost: Decimal?) -> String {
        guard let cost else { return "Unavailable" }
        let decimals = cost < 1 ? 4 : 2
        return cost.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(decimals))
        )
    }
}

private extension CodexTrackedModel {
    var chartColor: Color {
        switch self {
        case .sol:
            Color(red: 0.18, green: 0.61, blue: 0.82)
        case .terra:
            Color(red: 0.58, green: 0.42, blue: 0.82)
        case .luna:
            Color(red: 0.26, green: 0.70, blue: 0.50)
        }
    }
}
