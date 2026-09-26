import UIKit

/// What a session row shows. Built from the core's front-page snapshot.
struct SessionRowVM: Hashable {
    enum Status: Hashable {
        case idle
        case completed
        case working
        case awaiting
        case errored
    }

    enum PR: Hashable {
        case open, draft, merged, closed
    }

    let id: String
    var title: String
    var projectName: String
    var colorIndex: Int
    var harness: String?
    var branch: String?
    var pr: PR?
    var prNumber: UInt64?
    var status: Status
    var timeLabel: String
    var unseen: Bool
    var pinned: Bool
    var sendFailed: Bool
}

/// Folder row ("Pinned 2 ›", "P0 3 ›").
struct FolderRowVM: Hashable {
    let id: String
    var name: String
    var count: Int
    var symbol: String
}

/// Two-line session row, laid out by hand: fixed height, no Auto Layout
/// solving per cell, no text measurement beyond single-line labels.
///
///   [mark]  Title of the session ··········· Working ▪︎
///           ● project  branch  ⎇ 412
final class SessionCell: UICollectionViewListCell {
    static var height: CGFloat { (62 * TypeScale.factor).rounded() }

    private let unseenDot = UIView()
    private let harness = UIImageView()
    private let title = UILabel()
    private let projectDot = UIView()
    private let meta = UILabel()
    private let time = UILabel()
    private let prIcon = UIImageView()
    private let status = DotGridView(style: .idle)
    private let pin = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
    private var vm: SessionRowVM?
    var indent: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        unseenDot.backgroundColor = Palette.accent
        unseenDot.layer.cornerRadius = 3
        projectDot.layer.cornerRadius = 3.5
        title.textColor = Palette.text
        meta.textColor = Palette.secondary
        time.textAlignment = .right
        harness.contentMode = .scaleAspectFit
        harness.tintColor = Palette.text
        prIcon.contentMode = .scaleAspectFit
        pin.tintColor = Palette.tertiary
        for v in [unseenDot, harness, title, projectDot, meta, time, prIcon, status, pin] { contentView.addSubview(v) }
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = .clear
        backgroundConfiguration = bg
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var bg = UIBackgroundConfiguration.listCell().updated(for: state)
        bg.backgroundColor = state.isHighlighted || state.isSelected ? Palette.controlFill : .clear
        bg.cornerRadius = 16
        bg.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)
        backgroundConfiguration = bg
    }

    /// Fixed height: skip Auto Layout self-sizing entirely.
    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attrs.size.height = Self.height
        return attrs
    }

    func configure(_ vm: SessionRowVM) {
        self.vm = vm
        harness.image = BrandMarks.image(for: vm.harness ?? "claude-code", side: 20)
        unseenDot.isHidden = !vm.unseen
        title.text = vm.title
        title.font = Fonts.ui(vm.unseen ? .sansSemibold : .sansMedium, TypeScale.size(16.5))
        title.textColor = vm.unseen || vm.status != .idle ? Palette.text : Palette.text.withAlphaComponent(0.88)
        projectDot.backgroundColor = Palette.projectDots[vm.colorIndex % Palette.projectDots.count]
        let metaText = NSMutableAttributedString(string: vm.projectName, attributes: [.font: Fonts.ui(.sans, TypeScale.size(13.5)), .foregroundColor: Palette.secondary])
        if let n = vm.prNumber {
            metaText.append(NSAttributedString(string: "  #\(n)", attributes: [.font: Fonts.ui(.sans, TypeScale.size(13.5)), .foregroundColor: Palette.tertiary]))
        } else if let b = vm.branch, !b.isEmpty {
            metaText.append(NSAttributedString(string: "  " + b, attributes: [.font: Fonts.ui(.mono, TypeScale.size(12)), .foregroundColor: Palette.tertiary]))
        }
        meta.attributedText = metaText
        if let pr = vm.pr {
            prIcon.isHidden = false
            prIcon.image = UIImage(systemName: pr == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            prIcon.tintColor = switch pr {
            case .open: Palette.success
            case .draft: Palette.secondary
            case .merged: UIColor(hex: 0x8250DF)
            case .closed: Palette.danger
            }
        } else {
            prIcon.isHidden = true
        }
        pin.isHidden = !vm.pinned
        // Desktop status words: Working / Input / Failed; otherwise the time.
        let word: (String, UIColor, DotGridView.Style?)? = switch vm.status {
        case .working: ("Working", Palette.accent, .working)
        case .awaiting: ("Input", Palette.warning, .awaiting)
        case .errored: ("Failed", Palette.danger, .errored)
        case .idle, .completed: vm.sendFailed ? ("Not sent", Palette.danger, nil) : nil
        }
        if let (text, color, style) = word {
            time.text = text
            time.textColor = color
            time.font = Fonts.ui(.sansMedium, TypeScale.size(13))
            status.isHidden = style == nil
            if let style { status.style = style }
        } else {
            time.text = vm.timeLabel
            time.textColor = Palette.tertiary
            time.font = Fonts.ui(.sans, TypeScale.size(13))
            status.isHidden = true
        }
        accessibilityLabel = [vm.title, vm.projectName, word?.0].compactMap { $0 }.joined(separator: ", ")
        accessibilityIdentifier = "session-\(vm.id)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        let left: CGFloat = 20 + indent
        let right: CGFloat = 20
        let k = TypeScale.factor
        let titleY = (10 * k).rounded()
        let titleH = (22 * k).rounded()
        let metaY = (35 * k).rounded()
        let metaH = (18 * k).rounded()
        unseenDot.frame = CGRect(x: left - 11, y: titleY + titleH / 2 - 3, width: 6, height: 6)
        harness.frame = CGRect(x: left, y: titleY + titleH / 2 - 10, width: 20, height: 20)
        let textX = left + 20 + 14
        let tw = ceil(time.sizeThatFits(CGSize(width: 140, height: 40)).width)
        time.frame = CGRect(x: b.width - right - tw, y: titleY, width: tw, height: titleH)
        var trailing = time.frame.minX - 10
        if !status.isHidden {
            status.frame = CGRect(x: time.frame.minX - 6 - 11, y: titleY + titleH / 2 - 5.5, width: 11, height: 11)
            trailing = status.frame.minX - 10
        }
        title.frame = CGRect(x: textX, y: titleY, width: max(0, trailing - textX), height: titleH)
        projectDot.frame = CGRect(x: textX, y: metaY + metaH / 2 - 3.5, width: 7, height: 7)
        var x = textX + 7 + 7
        if !pin.isHidden {
            pin.frame = CGRect(x: x, y: metaY + metaH / 2 - 6.5, width: 11, height: 13)
            x += 15
        }
        let metaW = min(ceil(meta.sizeThatFits(CGSize(width: b.width, height: 40)).width), b.width - right - x - 22)
        meta.frame = CGRect(x: x, y: metaY, width: max(0, metaW), height: metaH)
        prIcon.frame = CGRect(x: meta.frame.maxX + 6, y: metaY + metaH / 2 - 7.5, width: 14, height: 15)
    }
}

/// Folder row: icon, name, count, chevron.
final class FolderCell: UICollectionViewListCell {
    static var height: CGFloat { (46 * TypeScale.factor).rounded() }

    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attrs.size.height = Self.height
        return attrs
    }

    func configure(_ vm: FolderRowVM) {
        var c = UIListContentConfiguration.cell()
        c.image = UIImage(systemName: vm.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        c.imageProperties.tintColor = Palette.secondary
        c.imageToTextPadding = 18
        let text = NSMutableAttributedString(string: vm.name, attributes: [.font: Fonts.ui(.sansMedium, TypeScale.size(17)), .foregroundColor: Palette.secondary])
        text.append(NSAttributedString(string: "  \(vm.count)", attributes: [.font: Fonts.ui(.sans, TypeScale.size(17)), .foregroundColor: Palette.tertiary]))
        c.attributedText = text
        c.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        contentConfiguration = c
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = .clear
        backgroundConfiguration = bg
        accessories = [.disclosureIndicator(options: .init(tintColor: Palette.tertiary))]
        accessibilityIdentifier = "folder-\(vm.id)"
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var bg = UIBackgroundConfiguration.listCell().updated(for: state)
        bg.backgroundColor = state.isHighlighted || state.isSelected ? Palette.controlFill : .clear
        bg.cornerRadius = 16
        bg.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)
        backgroundConfiguration = bg
    }
}

/// Foldable section header (desktop sidebar style): name, count, a live
/// glyph when something inside is working, and a disclosure chevron.
final class SectionHeaderCell: UICollectionViewListCell {
    struct State: Equatable {
        let id: String
        var title: String
        var count: Int
        var collapsed: Bool
        var live: DotGridView.Style?
    }

    static var height: CGFloat { (40 * TypeScale.factor).rounded() }
    private let title = UILabel()
    private let count = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    private let live = DotGridView(style: .working)
    private var shownCollapsed: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.textColor = Palette.secondary
        count.textColor = Palette.tertiary
        chevron.tintColor = Palette.tertiary
        chevron.contentMode = .center
        for v in [title, count, chevron, live] as [UIView] { contentView.addSubview(v) }
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attrs.size.height = Self.height
        return attrs
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var bg = UIBackgroundConfiguration.listCell().updated(for: state)
        bg.backgroundColor = state.isHighlighted ? Palette.controlFill : .clear
        bg.cornerRadius = 12
        bg.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        backgroundConfiguration = bg
    }

    func configure(_ s: State) {
        title.font = Fonts.ui(.sansSemibold, TypeScale.size(13.5))
        count.font = Fonts.ui(.sansMedium, TypeScale.size(13.5))
        title.text = s.title
        count.text = "\(s.count)"
        live.isHidden = s.live == nil
        if let style = s.live { live.style = style }
        let rotate = { self.chevron.transform = s.collapsed ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity }
        if shownCollapsed != nil, shownCollapsed != s.collapsed, window != nil {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: rotate)
        } else {
            rotate()
        }
        shownCollapsed = s.collapsed
        accessibilityIdentifier = "section-\(s.id)"
        accessibilityLabel = "\(s.title), \(s.count)"
        accessibilityValue = s.collapsed ? "Collapsed" : "Expanded"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        let h: CGFloat = 20
        let y = b.height - h - 6
        let tw = ceil(title.sizeThatFits(b.size).width)
        title.frame = CGRect(x: 20, y: y, width: min(tw, b.width - 120), height: h)
        let cw = ceil(count.sizeThatFits(b.size).width)
        count.frame = CGRect(x: title.frame.maxX + 7, y: y, width: cw, height: h)
        live.frame = CGRect(x: count.frame.maxX + 8, y: y + h / 2 - 5, width: 10, height: 10)
        chevron.frame = CGRect(x: b.width - 20 - 16, y: y, width: 16, height: h)
    }
}
