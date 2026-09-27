import UIKit

/// How provider accounts read everywhere they appear (Settings summary, the
/// accounts page): order, names, the most-used window, reset wording, meter
/// colors. Thresholds come from the core (`usage_level`, same as desktop).
enum ProviderUsage {
    /// Desktop's provider order.
    static let order = ["claude-code", "codex", "cursor", "antigravity", "grok", "devin", "opencode", "pi", "hermes"]

    static func rank(_ harness: String) -> Int { order.firstIndex(of: harness) ?? order.count }

    /// Accounts grouped per provider, in desktop order; the one in use first.
    static func groups(_ snapshot: AgentAccountsSnapshot) -> [(harness: String, accounts: [AgentAccount], warnings: [String])] {
        let byHarness = Dictionary(grouping: snapshot.accounts, by: \.harness)
        let harnesses = Set(byHarness.keys).union(snapshot.warnings.map(\.harness))
        return harnesses.sorted { (rank($0), $0) < (rank($1), $1) }.map { h in
            let accounts = (byHarness[h] ?? []).sorted { a, b in
                if a.active != b.active { return a.active }
                return title(a).localizedCaseInsensitiveCompare(title(b)) == .orderedAscending
            }
            return (h, accounts, snapshot.warnings.filter { $0.harness == h }.map(\.message))
        }
    }

    static func title(_ a: AgentAccount) -> String {
        a.email ?? a.displayName ?? "Unknown account"
    }

    /// Plan · organization (unless it just repeats the email).
    static func detail(_ a: AgentAccount) -> String? {
        var parts: [String] = []
        if let plan = a.planLabel { parts.append(plan) }
        if let org = a.organization, !(a.email.map { org.hasPrefix($0) } ?? false) { parts.append(org) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The window closest to its limit.
    static func topWindow(_ a: AgentAccount) -> AgentUsageWindow? {
        a.usageWindows.max { $0.usedFraction < $1.usedFraction }
    }

    static func color(_ fraction: Float) -> UIColor {
        switch usageLevel(usedFraction: fraction) {
        case .normal: Palette.accent
        case .warning: Palette.warning
        case .critical: Palette.danger
        }
    }

    static func percent(_ fraction: Float) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "Resets in 2h 13m" today, "Resets Mon 9:00 AM" this week, else the date.
    static func resetText(_ ms: Int64?, now: Date = Date()) -> String? {
        guard let ms else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let left = at.timeIntervalSince(now)
        if left <= 60 { return "Resets now" }
        if left < 24 * 3600 {
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated
            f.allowedUnits = left < 3600 ? [.minute] : [.hour, .minute]
            f.maximumUnitCount = 2
            return "Resets in " + (f.string(from: left) ?? "")
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(left < 7 * 86400 ? "EEEjmm" : "MMMd")
        return "Resets " + f.string(from: at)
    }

    /// "Updated just now" / "Updated 4 min ago" for the newest probe.
    static func updatedText(_ snapshot: AgentAccountsSnapshot, now: Date = Date()) -> String? {
        guard let ms = snapshot.accounts.compactMap(\.usageFetchedAtMs).max() else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if now.timeIntervalSince(at) < 60 { return "Usage updated just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Usage updated " + f.localizedString(for: at, relativeTo: now)
    }

    /// Why an account shows no meters.
    static func missingUsage(_ a: AgentAccount) -> String? {
        if let e = a.usageError { return e }
        if a.usageWindows.isEmpty { return a.apiKey ? "API keys have no plan usage" : "Usage unavailable" }
        return nil
    }
}

/// One usage window: label and percent over a capsule bar, reset time below.
final class UsageMeterView: UIView {
    private let label = UILabel()
    private let value = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let reset = UILabel()
    private var fraction: CGFloat = 0

    init() {
        super.init(frame: .zero)
        label.font = Fonts.ui(.sansMedium, 13)
        label.textColor = Palette.secondary
        value.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.textAlignment = .right
        reset.font = Fonts.ui(.sans, 12)
        reset.textColor = Palette.tertiary
        track.backgroundColor = Palette.controlFill
        track.layer.cornerRadius = 3
        track.clipsToBounds = true
        fill.layer.cornerRadius = 3
        track.addSubview(fill)
        for v in [label, value, track, reset] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            track.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.heightAnchor.constraint(equalToConstant: 6),
            reset.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 5),
            reset.leadingAnchor.constraint(equalTo: leadingAnchor),
            reset.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ w: AgentUsageWindow) {
        label.text = w.label
        value.text = ProviderUsage.percent(w.usedFraction)
        let color = ProviderUsage.color(w.usedFraction)
        value.textColor = usageLevel(usedFraction: w.usedFraction) == .normal ? Palette.text : color
        fill.backgroundColor = color
        fraction = CGFloat(max(0.015, min(1, w.usedFraction)))
        reset.text = ProviderUsage.resetText(w.resetsAtMs)
        reset.isHidden = reset.text == nil
        accessibilityLabel = [w.label, ProviderUsage.percent(w.usedFraction) + " used", reset.text].compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * fraction, height: track.bounds.height)
    }
}

/// Compact trailing meter for summary rows: a short bar and the percent.
final class MiniUsageView: UIView {
    private let bar = UIView()
    private let fill = UIView()
    private let value = UILabel()
    private var fraction: CGFloat = 0

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 92, height: 20))
        bar.backgroundColor = Palette.controlFill
        bar.layer.cornerRadius = 2.5
        bar.clipsToBounds = true
        bar.addSubview(fill)
        value.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.textAlignment = .right
        addSubview(bar)
        addSubview(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 92, height: 20) }

    func configure(_ w: AgentUsageWindow) {
        let color = ProviderUsage.color(w.usedFraction)
        fraction = CGFloat(max(0.03, min(1, w.usedFraction)))
        fill.backgroundColor = color
        value.text = ProviderUsage.percent(w.usedFraction)
        value.textColor = usageLevel(usedFraction: w.usedFraction) == .normal ? Palette.secondary : color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        value.frame = CGRect(x: bounds.width - 40, y: 0, width: 40, height: bounds.height)
        bar.frame = CGRect(x: 0, y: (bounds.height - 5) / 2, width: bounds.width - 46, height: 5)
        fill.frame = CGRect(x: 0, y: 0, width: bar.bounds.width * fraction, height: bar.bounds.height)
    }
}
