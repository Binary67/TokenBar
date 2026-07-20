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
    private let agentActivityItem = NSMenuItem()
    private let usageValueItem = NSMenuItem()
    private let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    private let statusIconImageView = StatusIconImageView()
    private var usageOverviewHostingView: NSHostingView<UsageOverviewView>?
    private var agentActivityHostingView: NSHostingView<AgentActivityDetailView>?
    private var usageValueHostingView: NSHostingView<UsageValueDetailView>?
    private var monitoringTask: Task<Void, Never>?
    private var displayedStatus: CodexStatus?
    private var snapshot = TokenBarSnapshot(status: .loading, todayTokens: 0, lastUpdated: .now)

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

        let agentActivityHostingView = NSHostingView(
            rootView: AgentActivityDetailView(snapshot: snapshot)
        )
        agentActivityHostingView.frame.size = agentActivityHostingView.fittingSize
        let agentActivityDetailItem = NSMenuItem()
        agentActivityDetailItem.view = agentActivityHostingView
        let agentActivityMenu = NSMenu()
        agentActivityMenu.addItem(agentActivityDetailItem)
        agentActivityItem.submenu = agentActivityMenu
        self.agentActivityHostingView = agentActivityHostingView

        let usageValueHostingView = NSHostingView(
            rootView: UsageValueDetailView(snapshot: snapshot)
        )
        usageValueHostingView.frame.size = usageValueHostingView.fittingSize
        let usageValueDetailItem = NSMenuItem()
        usageValueDetailItem.view = usageValueHostingView
        let usageValueMenu = NSMenu()
        usageValueMenu.addItem(usageValueDetailItem)
        usageValueItem.submenu = usageValueMenu
        self.usageValueHostingView = usageValueHostingView

        let menu = NSMenu()
        menu.addItem(usageOverviewItem)
        menu.addItem(agentActivityItem)
        menu.addItem(usageValueItem)
        menu.addItem(.separator())

        let actionFooterHostingView = NSHostingView(
            rootView: MenuActionFooterView(
                refreshAction: { [weak self] in
                    self?.statusItem.menu?.cancelTracking()
                    self?.startMonitoring()
                },
                quitAction: { [weak self] in
                    self?.statusItem.menu?.cancelTracking()
                    NSApp.terminate(nil)
                }
            )
        )
        actionFooterHostingView.frame.size = actionFooterHostingView.fittingSize
        let actionFooterItem = NSMenuItem()
        actionFooterItem.view = actionFooterHostingView
        menu.addItem(actionFooterItem)

        let refreshShortcutItem = NSMenuItem(
            title: "",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshShortcutItem.target = self
        refreshShortcutItem.isHidden = true
        refreshShortcutItem.allowsKeyEquivalentWhenHidden = true
        menu.addItem(refreshShortcutItem)

        let quitShortcutItem = NSMenuItem(
            title: "",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitShortcutItem.target = self
        quitShortcutItem.isHidden = true
        quitShortcutItem.allowsKeyEquivalentWhenHidden = true
        menu.addItem(quitShortcutItem)

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
        let isLoading = snapshot.status == .loading
        agentActivityItem.isHidden = isLoading
        usageValueItem.isHidden = isLoading

        let tokenText: String
        let detail: String
        if snapshot.status == .loading {
            tokenText = "…"
            detail = "Preparing Codex usage history"
        } else if snapshot.usageScope == .unavailable {
            tokenText = "—"
            detail = "Codex account usage unavailable"
        } else {
            tokenText = TokenTextFormatter.compact(snapshot.todayTokens)
            detail = "\(snapshot.status.label) — "
                + "\(TokenTextFormatter.exact(snapshot.todayTokens)) tokens today"
        }

        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
        ]
        if isLoading {
            titleAttributes[.baselineOffset] = 2
        }
        statusItem.button?.attributedTitle = NSAttributedString(
            string: tokenText,
            attributes: titleAttributes
        )
        setStatusIcon(snapshot.status)
        statusItem.button?.toolTip = detail
        if let usageOverviewHostingView {
            usageOverviewHostingView.rootView = UsageOverviewView(snapshot: snapshot)
            usageOverviewHostingView.frame.size = usageOverviewHostingView.fittingSize
        }
        if let agentTime = snapshot.todayAgentTimeMilliseconds {
            agentActivityItem.title = "Agent Activity · This Mac · "
                + "\(AgentTimeFormatter.compact(agentTime)) Today"
        } else {
            agentActivityItem.title = "Agent Activity · This Mac · Not Reported"
        }
        if let valueMultiple = snapshot.subscriptionValueMultiple {
            usageValueItem.title = "Account Usage Value · "
                + "\(UsageValueFormatter.multiple(valueMultiple)) Plan Price"
        } else {
            usageValueItem.title = "Account Usage Value · Not Reported"
        }
        if let agentActivityHostingView {
            agentActivityHostingView.rootView = AgentActivityDetailView(snapshot: snapshot)
            agentActivityHostingView.frame.size = agentActivityHostingView.fittingSize
        }
        if let usageValueHostingView {
            usageValueHostingView.rootView = UsageValueDetailView(snapshot: snapshot)
            usageValueHostingView.frame.size = usageValueHostingView.fittingSize
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
        if status == .loading || status == .working {
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

private struct MenuActionFooterView: View {
    let refreshAction: () -> Void
    let quitAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Spacer()

            Button(action: refreshAction) {
                Label("Refresh Now", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh Now (⌘R)")
            .accessibilityLabel("Refresh Now")

            Button(action: quitAction) {
                Label("Quit TokenBar", systemImage: "power")
                    .labelStyle(.iconOnly)
            }
            .help("Quit TokenBar (⌘Q)")
            .accessibilityLabel("Quit TokenBar")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 340)
    }
}

private struct UsageOverviewView: View {
    let snapshot: TokenBarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(headerTitle)
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

            if snapshot.status == .loading {
                LoadingHistoryView()
            } else {
                HStack(alignment: .top, spacing: 24) {
                    UsagePeriodColumn(
                        title: "Today",
                        cost: snapshot.estimatedAPICostUSD,
                        tokens: snapshot.todayTokens,
                        isAvailable: snapshot.usageScope != .unavailable
                    )
                    UsagePeriodColumn(
                        title: "Last 30 Days",
                        cost: snapshot.last30DaysAPICostUSD,
                        tokens: snapshot.last30DaysTokens,
                        isAvailable: snapshot.usageScope != .unavailable
                    )
                }

                AccountUsageChart(days: snapshot.accountDailyUsage)

                if snapshot.usageScope == .account {
                    AccountRefreshStatusView(
                        lastCheckedAt: snapshot.accountLastCheckedAt,
                        nextCheckAt: snapshot.accountNextCheckAt
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Usage Limits")
                        .font(.caption.weight(.medium))
                    RateLimitRow(
                        label: "5-Hour",
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

            if snapshot.status != .loading {
                Divider()

                Text("Activity & Value")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .padding(.top, 10)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headerTitle: String {
        guard let subscriptionPlan = snapshot.subscriptionPlan else { return "Codex" }
        return "Codex · \(subscriptionPlan.label)"
    }
}

private struct AccountRefreshStatusView: View {
    let lastCheckedAt: Date?
    let nextCheckAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                Text(lastCheckedText(at: context.date))
                Spacer()
                Text(nextCheckText(at: context.date))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func lastCheckedText(at now: Date) -> String {
        guard let lastCheckedAt else { return "Account not checked yet" }
        let seconds = max(0, Int(now.timeIntervalSince(lastCheckedAt)))
        return seconds < 1 ? "Account checked now" : "Account checked \(seconds)s ago"
    }

    private func nextCheckText(at now: Date) -> String {
        guard let nextCheckAt else { return "Checking now" }
        let seconds = max(0, Int(nextCheckAt.timeIntervalSince(now).rounded(.up)))
        return seconds == 0 ? "Checking now" : "Next check in \(seconds)s"
    }
}

private struct LoadingHistoryView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(spacing: 3) {
                Text("Preparing usage history…")
                    .font(.subheadline.weight(.medium))
                Text("This may take a moment after an update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentActivityDetailView: View {
    let snapshot: TokenBarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Agent Activity · This Mac")
                .font(.headline)

            Divider()

            HStack {
                Spacer()
                Text("Today")
                    .frame(width: 64, alignment: .trailing)
                Text("Last 30 Days")
                    .frame(width: 86, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack {
                Text("Threads Started")
                Spacer()
                Text(threadsToday)
                    .frame(width: 64, alignment: .trailing)
                    .monospacedDigit()
                Text(threadsLast30Days)
                    .frame(width: 86, alignment: .trailing)
                    .monospacedDigit()
            }
            .font(.caption)

            HStack {
                Text("Agent Runtime")
                Spacer()
                Text(agentTimeToday)
                    .frame(width: 64, alignment: .trailing)
                    .monospacedDigit()
                Text(agentTimeLast30Days)
                    .frame(width: 86, alignment: .trailing)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var threadsToday: String {
        snapshot.todayThreadsStarted.map(String.init) ?? "—"
    }

    private var threadsLast30Days: String {
        snapshot.last30DaysThreadsStarted.map(String.init) ?? "—"
    }

    private var agentTimeToday: String {
        snapshot.todayAgentTimeMilliseconds.map(AgentTimeFormatter.compact) ?? "—"
    }

    private var agentTimeLast30Days: String {
        snapshot.last30DaysAgentTimeMilliseconds.map(AgentTimeFormatter.compact) ?? "—"
    }
}

private struct UsageValueDetailView: View {
    let snapshot: TokenBarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Account Usage Value")
                .font(.headline)

            Divider()

            UsageDetailRow(label: "Usage Scope", detail: usageScopeDetail)
            UsageDetailRow(label: "Cost Basis", detail: costBasisDetail)
            UsageDetailRow(label: "Value Multiple", detail: valueMultipleDetail)
            UsageDetailRow(label: "Estimated Break-Even", detail: breakEvenDuration)
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var valueMultipleDetail: String {
        guard let valueMultiple = snapshot.subscriptionValueMultiple else {
            return "Not Reported"
        }
        return "\(UsageValueFormatter.multiple(valueMultiple)) Plan Price"
    }

    private var usageScopeDetail: String {
        snapshot.usageScope == .account ? "All Devices" : "Not Reported"
    }

    private var costBasisDetail: String {
        let days = snapshot.costEstimateObservedDays
        guard days > 0 else { return "Not Reported" }
        return "Sol · \(days) observed \(days == 1 ? "day" : "days")"
    }

    private var breakEvenDuration: String {
        guard let days = snapshot.estimatedBreakEvenDays else { return "Not Reported" }
        return "\(days) \(days == 1 ? "day" : "days")"
    }
}

private struct UsageDetailRow: View {
    let label: String
    let detail: String

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
}

private struct UsagePeriodColumn: View {
    let title: String
    let cost: Decimal?
    let tokens: Int64
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
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

private struct AccountUsageChart: View {
    let days: [CodexAccountDailyUsage]
    @State private var hoveredDay: CodexAccountDailyUsage?

    private let chartHeight: CGFloat = 44
    private let peakLineInset: CGFloat = 6

    private var maximumTokens: Int64 {
        days.map(\.tokens).max() ?? 0
    }

    private var peakDayIndex: Int? {
        guard let index = days.indices.max(by: { days[$0].tokens < days[$1].tokens }),
              days[index].tokens > 0 else {
            return nil
        }
        return index
    }

    private var peakCost: Decimal? {
        guard let peakDayIndex,
              let cost = days[peakDayIndex].estimatedAPICostUSD,
              cost > 0 else {
            return nil
        }
        return cost
    }

    private var isPeakCostLeading: Bool {
        guard let peakDayIndex else { return false }
        return peakDayIndex * 2 > days.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Account Daily Tokens")
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
                            AccountDailyUsageBar(
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

                    if let peakCost {
                        HStack(spacing: 6) {
                            if isPeakCostLeading {
                                Text(UsageValueFormatter.compactCost(peakCost))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            HorizontalDashedLine()
                                .stroke(
                                    Color.secondary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                )
                                .frame(height: 1)
                            if !isPeakCostLeading {
                                Text(UsageValueFormatter.compactCost(peakCost))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Peak API equivalent cost: \(UsageValueFormatter.cost(peakCost))"
                        )
                    }
                }
                .frame(
                    height: chartHeight + (peakCost == nil ? 0 : peakLineInset),
                    alignment: .bottom
                )

                HStack {
                    Text("30 Days Ago")
                    Spacer()
                    Text("Today")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var chartSummary: String {
        guard let hoveredDay else {
            return UsageValueFormatter.dateRange(days.map(\.day))
        }

        let date = hoveredDay.day.formatted(
            .dateTime.month(.abbreviated).day()
        )
        return "\(date) · \(TokenTextFormatter.compact(hoveredDay.tokens)) tokens · "
            + UsageValueFormatter.cost(hoveredDay.estimatedAPICostUSD)
    }
}

private struct HorizontalDashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let y = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
    }
}

private struct AccountDailyUsageBar: View {
    let usage: CodexAccountDailyUsage
    let maximumTokens: Int64
    let chartHeight: CGFloat
    let isHovered: Bool
    let onHover: (Bool) -> Void

    private var barHeight: CGFloat {
        guard maximumTokens > 0, usage.tokens > 0 else { return 0 }
        return max(2, CGFloat(Double(usage.tokens) / Double(maximumTokens)) * chartHeight)
    }

    var body: some View {
        CodexTrackedModel.sol.chartColor
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
        [
            usage.day.formatted(date: .abbreviated, time: .omitted),
            "Account total: \(TokenTextFormatter.exact(usage.tokens)) tokens",
            "API equivalent: \(UsageValueFormatter.cost(usage.estimatedAPICostUSD))",
        ]
        .joined(separator: "\n")
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

    static func compactCost(_ cost: Decimal) -> String {
        guard cost >= 1 else { return "<$1" }

        let locale = Locale(identifier: "en_US")
        if cost < 999.5 {
            return cost.formatted(
                .currency(code: "USD")
                    .locale(locale)
                    .precision(.fractionLength(0))
            )
        }

        let divisor: Decimal
        let suffix: String
        if cost < 999_500 {
            divisor = 1_000
            suffix = "K"
        } else {
            divisor = 1_000_000
            suffix = "M"
        }
        let scaledCost = cost / divisor
        let maximumDecimals = scaledCost < 10 ? 1 : 0
        let value = scaledCost.formatted(
            .number
                .locale(locale)
                .precision(.fractionLength(0...maximumDecimals))
        )
        return "$\(value)\(suffix)"
    }

    static func dateRange(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    static func multiple(_ value: Decimal) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(1))
        ) + "×"
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
        case .loading, .working:
            .blue
        case .needsInput:
            .orange
        case .idle:
            .secondary
        case .error:
            .red
        case .unavailable:
            .orange
        }
    }
}
