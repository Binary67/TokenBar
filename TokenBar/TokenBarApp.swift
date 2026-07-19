//
//  TokenBarApp.swift
//  TokenBar
//
//  Created by Frank on 18/07/2026.
//

import AppKit
import SwiftUI

private final class StatusIconImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

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
    private let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    private let statusIconImageView = StatusIconImageView()
    private var usageOverviewHostingView: NSHostingView<UsageOverviewView>?
    private var monitoringTask: Task<Void, Never>?
    private var displayedStatus: CodexStatus?
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
        statusIconImageView.imageScaling = .scaleProportionallyDown
        button.addSubview(statusIconImageView)

        let overviewHostingView = NSHostingView(
            rootView: UsageOverviewView(snapshot: snapshot)
        )
        overviewHostingView.frame.size = overviewHostingView.fittingSize
        usageOverviewItem.view = overviewHostingView
        usageOverviewHostingView = overviewHostingView

        let menu = NSMenu()
        menu.addItem(usageOverviewItem)
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

        statusItem.button?.attributedTitle = NSAttributedString(
            string: tokenText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                )
            ]
        )
        setStatusIcon(snapshot.status)
        statusItem.button?.toolTip = detail
        if let usageOverviewHostingView {
            usageOverviewHostingView.rootView = UsageOverviewView(snapshot: snapshot)
            usageOverviewHostingView.frame.size = usageOverviewHostingView.fittingSize
        }
    }

    private func setStatusIcon(_ status: CodexStatus) {
        guard status != displayedStatus else { return }

        guard let button = statusItem.button,
              let image = NSImage(
                  systemSymbolName: status.symbolName,
                  accessibilityDescription: status.label
              )?.withSymbolConfiguration(iconConfiguration) else {
            return
        }

        image.isTemplate = true
        button.image = NSImage(
            size: NSSize(width: image.size.width + 3, height: image.size.height)
        )
        button.layoutSubtreeIfNeeded()
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        statusIconImageView.frame = NSRect(
            x: imageRect.minX,
            y: button.bounds.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        statusIconImageView.image = image
        statusIconImageView.removeAllSymbolEffects()
        if status == .working {
            statusIconImageView.addSymbolEffect(
                .rotate.clockwise.wholeSymbol,
                options: .repeat(.continuous)
            )
        }

        button.setAccessibilityLabel(status.label)
        displayedStatus = status
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Codex Usage")
                    .font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.status.indicatorColor)
                        .frame(width: 6, height: 6)
                    Text(snapshot.status.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .top, spacing: 24) {
                UsagePeriodColumn(
                    title: "Today",
                    cost: snapshot.estimatedAPICostUSD,
                    tokens: snapshot.trackedTodayTokens,
                    isAvailable: snapshot.status != .unavailable
                )
                UsagePeriodColumn(
                    title: "Last 30 days",
                    cost: snapshot.last30DaysAPICostUSD,
                    tokens: snapshot.last30DaysTokens,
                    isAvailable: snapshot.status != .unavailable
                )
            }

            StackedUsageChart(days: snapshot.dailyUsage)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Usage limits")
                    .font(.caption.weight(.medium))
                RateLimitRow(
                    label: "5-hour",
                    window: snapshot.fiveHourLimit,
                    includesDate: false
                )
                RateLimitRow(
                    label: "Weekly",
                    window: snapshot.weeklyLimit,
                    includesDate: true
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 10)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UsagePeriodColumn: View {
    let title: String
    let cost: Decimal?
    let tokens: Int64
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Text(UsageValueFormatter.cost(cost))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(isAvailable ? "\(TokenTextFormatter.compact(tokens)) tokens" : "Not reported")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(isAvailable ? "\(TokenTextFormatter.exact(tokens)) tokens" : "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StackedUsageChart: View {
    let days: [CodexDailyUsage]
    @State private var hoveredDay: CodexDailyUsage?

    private let chartHeight: CGFloat = 44

    private var maximumTokens: Int64 {
        days.map(\.totalTokens).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Daily tokens")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(chartSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if days.isEmpty {
                Text("No history reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(height: 1)

                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(days) { day in
                            DailyUsageBar(
                                usage: day,
                                maximumTokens: maximumTokens,
                                chartHeight: chartHeight,
                                isHovered: hoveredDay?.id == day.id
                            ) { isHovering in
                                if isHovering {
                                    hoveredDay = day
                                } else if hoveredDay?.id == day.id {
                                    hoveredDay = nil
                                }
                            }
                        }
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

            HStack(spacing: 12) {
                ForEach(CodexTrackedModel.allCases, id: \.rawValue) { model in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.chartColor)
                            .frame(width: 6, height: 6)
                        Text(model.label)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var chartSummary: String {
        guard let hoveredDay else {
            return UsageValueFormatter.dateRange(days)
        }

        let date = hoveredDay.day.formatted(
            .dateTime.month(.abbreviated).day()
        )
        return "\(date) · \(TokenTextFormatter.compact(hoveredDay.totalTokens)) tokens · "
            + UsageValueFormatter.cost(hoveredDay.estimatedAPICostUSD)
    }
}

private struct DailyUsageBar: View {
    let usage: CodexDailyUsage
    let maximumTokens: Int64
    let chartHeight: CGFloat
    let isHovered: Bool
    let onHover: (Bool) -> Void

    private var barHeight: CGFloat {
        guard maximumTokens > 0, usage.totalTokens > 0 else { return 0 }
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
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .brightness(isHovered ? 0.12 : 0)
        .frame(height: chartHeight, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        var lines = [
            usage.day.formatted(date: .abbreviated, time: .omitted),
            "Total: \(TokenTextFormatter.exact(usage.totalTokens)) tokens",
            "API equivalent: \(UsageValueFormatter.cost(usage.estimatedAPICostUSD))",
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

private struct RateLimitRow: View {
    let label: String
    let window: CodexRateLimitWindow?
    let includesDate: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var detail: String {
        guard let window else { return "Not reported" }
        guard let resetsAt = window.resetsAt else {
            return "\(window.percentLeft)% left"
        }

        let resetText = includesDate
            ? resetsAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : resetsAt.formatted(.dateTime.hour().minute())
        return "\(window.percentLeft)% left · \(resetText)"
    }
}

private enum UsageValueFormatter {
    static func cost(_ cost: Decimal?) -> String {
        guard let cost else { return "Not reported" }
        let decimals = cost < 1 ? 4 : 2
        return cost.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(decimals))
        )
    }

    static func dateRange(_ days: [CodexDailyUsage]) -> String {
        guard let first = days.first?.day, let last = days.last?.day else { return "" }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }
}

private extension CodexTrackedModel {
    var chartColor: Color {
        switch self {
        case .sol:
            .blue
        case .terra:
            .indigo
        case .luna:
            .mint
        }
    }
}

private extension CodexStatus {
    var indicatorColor: Color {
        switch self {
        case .working:
            .blue
        case .idle:
            .secondary
        case .error:
            .red
        case .unavailable:
            .orange
        }
    }
}
