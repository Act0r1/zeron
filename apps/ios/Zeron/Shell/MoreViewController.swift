import UIKit

/// Settings: who you are, your agent accounts and their plan usage (on the
/// computer sessions start on), your computers, appearance, archive, sign
/// out. Choices that are one of a few (theme, wallpaper) open in place as
/// menus instead of spreading over a section of rows each.
final class MoreViewController: UIViewController, UICollectionViewDelegate {
    private let app: AppModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var accountsState: AccountsState = .idle

    enum Section: String, Hashable {
        case profile, providers, computers, appearance, sessions, about, signOut
    }

    enum AccountsState: Equatable {
        case idle, loading
        case failed(String)
    }

    struct Row: Hashable {
        let id: String
        var title: String
        var subtitle: String?
        var symbol: String?
        var harness: String?
        var value: String?
        var tint: UIColor = Palette.secondary
        var accessory: Accessory = .disclosure
        var destructive = false
        var centered = false
        var enabled = true

        enum Accessory: Hashable {
            case disclosure
            case none
            case dot(Bool)
            case usage(AgentUsageWindow)
            case menu
        }
    }

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        navigationItem.largeTitleDisplayMode = .always
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "settings"
        view.addSubview(collectionView)

        let profile = UICollectionView.CellRegistration<ProfileCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(name: self.app.accountName, detail: self.app.accountDetail)
        }
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, path in
            var c = UIListContentConfiguration.groupedHeader()
            c.text = self?.dataSource.sectionIdentifier(for: path.section).flatMap { self?.headerText($0) }
            view.contentConfiguration = c
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, path in
            var c = UIListContentConfiguration.groupedFooter()
            c.text = self?.dataSource.sectionIdentifier(for: path.section).flatMap { self?.footerText($0) }
            view.contentConfiguration = c
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, path, row in
            row.id == "profile"
                ? cv.dequeueConfiguredReusableCell(using: profile, for: path, item: row)
                : cv.dequeueConfiguredReusableCell(using: cell, for: path, item: row)
        }
        dataSource.supplementaryViewProvider = { cv, kind, path in
            kind == UICollectionView.elementKindSectionHeader
                ? cv.dequeueConfiguredReusableSupplementary(using: header, for: path)
                : cv.dequeueConfiguredReusableSupplementary(using: footer, for: path)
        }
        reload()
        wallpaperObserver = NotificationCenter.default.addObserver(forName: WallpaperStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        // Devices go on/offline, the org name backfills, accounts refresh.
        appToken = app.observe { [weak self] in self?.reload() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if dataSource != nil { reload() }
        refreshAccounts()
    }

    private var wallpaperObserver: NSObjectProtocol?
    private var appToken: AnyObject?

    // MARK: Provider accounts summary

    private var accountsHost: String? { app.primaryHostId }

    /// The host's list at once (its last probe), then fresh usage when
    /// ours is older than a few minutes.
    private func refreshAccounts() {
        guard let host = accountsHost, accountsState != .loading else { return }
        let stale = app.providerAccountsAt[host].map { Date().timeIntervalSince($0) > 300 } ?? true
        guard stale || app.providerAccounts[host] == nil else { return }
        accountsState = .loading
        reload()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.app.loadProviderAccounts(on: host, force: false)
                self.accountsState = .idle
                self.reload()
                _ = try await self.app.loadProviderAccounts(on: host, force: true)
            } catch {
                self.accountsState = .failed(ProviderAccountsViewController.describe(error, device: self.app.deviceName(host)))
            }
            if self.accountsState == .loading { self.accountsState = .idle }
            self.reload()
        }
    }

    private func providerRows() -> [Row] {
        guard let host = accountsHost else {
            return [Row(id: "providers:none", title: "No computer yet", subtitle: "Open Zeron on a computer to run sessions and see its accounts here.", symbol: "desktopcomputer", accessory: .none, enabled: false)]
        }
        guard let snapshot = app.providerAccounts[host] else {
            if case let .failed(message) = accountsState {
                return [Row(id: "providers:error", title: "Accounts unavailable", subtitle: message, symbol: "exclamationmark.triangle", accessory: .none, enabled: false)]
            }
            return [Row(id: "providers:loading", title: "Loading accounts…", symbol: "person.2", accessory: .none, enabled: false)]
        }
        let groups = ProviderUsage.groups(snapshot).filter { !$0.accounts.isEmpty }
        guard !groups.isEmpty else {
            return [Row(id: "providers:empty", title: "No provider accounts", subtitle: "Sign in to an agent from Zeron on \(app.deviceName(host)).", symbol: "person.2", accessory: .none, enabled: false)]
        }
        return groups.map { g in
            let active = g.accounts.first(where: \.active)
            let top = active.flatMap(ProviderUsage.topWindow)
            var subtitle = active.map(ProviderUsage.title) ?? "Not signed in"
            if g.accounts.count > 1 { subtitle += " · \(g.accounts.count) accounts" }
            if let active, top == nil, !active.apiKey { subtitle += " · Usage unavailable" }
            return Row(id: "provider:\(g.harness)", title: HarnessNames.label(g.harness), subtitle: subtitle, harness: g.harness,
                       accessory: top.map { .usage($0) } ?? .disclosure)
        }
    }

    // MARK: Rows

    private func reload() {
        var s = NSDiffableDataSourceSnapshot<Section, Row>()
        s.appendSections([.profile])
        s.appendItems([Row(id: "profile", title: app.accountName, subtitle: app.accountDetail, accessory: .none)])

        s.appendSections([.providers])
        s.appendItems(providerRows())

        s.appendSections([.computers])
        let devices = app.executionDevices.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        if devices.isEmpty {
            s.appendItems([Row(id: "computers:none", title: "No computers yet", subtitle: "Sessions run on a computer with Zeron open.", symbol: "desktopcomputer", accessory: .none, enabled: false)])
        } else {
            s.appendItems(devices.map { d in
                Row(id: "device:\(d.id)", title: d.name, subtitle: Self.deviceDetail(d), symbol: Self.platformSymbol(d.platform),
                    tint: d.online ? Palette.text : Palette.tertiary, accessory: .dot(d.online))
            })
        }

        s.appendSections([.appearance])
        let style = UserDefaults.standard.integer(forKey: "appearance")
        s.appendItems([
            Row(id: "theme", title: "Theme", symbol: "circle.lefthalf.filled", value: ["System", "Light", "Dark"][max(0, min(2, style))], accessory: .menu),
            Row(id: "wallpaper", title: "Chat Wallpaper", subtitle: WallpaperStore.isSet ? WallpaperStore.label(WallpaperStore.effect) : "Behind new chats and the sessions list",
                symbol: "photo", value: WallpaperStore.isSet ? (WallpaperStore.name ?? "Photo") : "None", accessory: .menu),
        ])

        s.appendSections([.sessions])
        s.appendItems([Row(id: "archived", title: "Archived Sessions", symbol: "archivebox", value: app.archived.isEmpty ? nil : "\(app.archived.count)")])

        s.appendSections([.about])
        s.appendItems([Row(id: "version", title: "Version", symbol: "info.circle", value: Self.version, accessory: .none, enabled: false)])

        s.appendSections([.signOut])
        s.appendItems([Row(id: "signout", title: "Sign Out", accessory: .none, destructive: true, centered: true)])
        s.reconfigureItems(s.itemIdentifiers)
        dataSource.apply(s, animatingDifferences: false)
    }

    private func headerText(_ section: Section) -> String? {
        switch section {
        case .providers: "Provider Accounts"
        case .computers: "Computers"
        case .appearance: "Appearance"
        case .sessions: "Sessions"
        default: nil
        }
    }

    private func footerText(_ section: Section) -> String? {
        guard section == .providers, let host = accountsHost, let snapshot = app.providerAccounts[host], !snapshot.accounts.isEmpty else { return nil }
        let loading = accountsState == .loading ? "Updating usage…" : ProviderUsage.updatedText(snapshot)
        return ["Plan usage on \(app.deviceName(host)).", loading.map { $0 + "." }].compactMap { $0 }.joined(separator: " ")
    }

    static func platformSymbol(_ platform: String) -> String {
        switch platform {
        case "macos": "laptopcomputer"
        case "linux": "server.rack"
        case "windows": "pc"
        default: "desktopcomputer"
        }
    }

    static func deviceDetail(_ d: DeviceView) -> String {
        var parts: [String] = []
        if d.online {
            parts.append("Online")
        } else if let seen = d.lastSeenMs {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            parts.append("Last seen " + f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seen) / 1000), relativeTo: Date()))
        } else {
            parts.append("Offline")
        }
        if d.sessionCount > 0 { parts.append("\(d.sessionCount) session\(d.sessionCount == 1 ? "" : "s")") }
        if let v = d.version { parts.append("v\(v)") }
        return parts.joined(separator: " · ")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    private func configure(_ cell: UICollectionViewListCell, _ row: Row) {
        var c = row.value != nil && row.subtitle == nil ? UIListContentConfiguration.valueCell() : UIListContentConfiguration.subtitleCell()
        c.text = row.title
        c.textProperties.font = Fonts.ui(.sansMedium, 16)
        c.textProperties.color = row.destructive ? Palette.danger : Palette.text
        if row.centered { c.textProperties.alignment = .center }
        if row.value != nil && row.subtitle == nil {
            c.secondaryText = row.value
            c.secondaryTextProperties.font = Fonts.ui(.sans, 15)
        } else {
            c.secondaryText = row.subtitle
            c.secondaryTextProperties.font = Fonts.ui(.sans, 13)
            c.secondaryTextProperties.numberOfLines = 2
        }
        c.secondaryTextProperties.color = Palette.secondary
        if let harness = row.harness {
            c.image = BrandMarks.image(for: harness, side: 22)
            c.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        } else if let symbol = row.symbol {
            c.image = UIImage(systemName: symbol)
            c.imageProperties.tintColor = row.tint
            c.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        }
        cell.contentConfiguration = c
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = Palette.elevated
        cell.backgroundConfiguration = bg
        switch row.accessory {
        case .disclosure:
            cell.accessories = [.disclosureIndicator()]
        case .none:
            cell.accessories = []
        case let .dot(online):
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            dot.backgroundColor = online ? Palette.success : Palette.tertiary
            dot.layer.cornerRadius = 4
            cell.accessories = [.customView(configuration: .init(customView: dot, placement: .trailing()))]
        case let .usage(window):
            let meter = MiniUsageView()
            meter.configure(window)
            cell.accessories = [
                .customView(configuration: .init(customView: meter, placement: .trailing(), reservedLayoutWidth: .custom(92))),
                .disclosureIndicator(),
            ]
        case .menu:
            // The value shows the current choice; the row opens its menu.
            cell.accessories = [.popUpMenu(menu(for: row.id) ?? UIMenu(), displayed: .always)]
        }
        cell.accessibilityIdentifier = "settings-\(row.id)"
    }

    // MARK: Menus

    private func menu(for id: String) -> UIMenu? {
        switch id {
        case "theme":
            let style = UserDefaults.standard.integer(forKey: "appearance")
            return UIMenu(title: "Theme", children: [("System", "circle.lefthalf.filled"), ("Light", "sun.max"), ("Dark", "moon")].enumerated().map { i, item in
                UIAction(title: item.0, image: UIImage(systemName: item.1), state: i == style ? .on : .off) { [weak self] _ in
                    UserDefaults.standard.set(i, forKey: "appearance")
                    self?.view.window?.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: i) ?? .unspecified
                    self?.reload()
                }
            })
        case "wallpaper":
            var items: [UIMenuElement] = [
                UIAction(title: WallpaperStore.isSet ? "Choose Another Photo…" : "Choose Photo…", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                    guard let self else { return }
                    WallpaperPicker.present(from: self)
                },
            ]
            if WallpaperStore.isSet {
                items.append(UIMenu(title: "Effect", image: UIImage(systemName: "wand.and.stars"), children: WallpaperStore.allEffects.map { e in
                    UIAction(title: WallpaperStore.label(e), subtitle: WallpaperStore.detail(e), state: e == WallpaperStore.effect ? .on : .off) { _ in
                        WallpaperStore.effect = e
                    }
                }))
                items.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "Remove Wallpaper", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in WallpaperStore.remove() },
                ]))
            }
            return UIMenu(title: "Chat Wallpaper", children: items)
        default:
            return nil
        }
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt path: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: path) else { return false }
        return row.enabled && row.id != "profile" && !row.id.hasPrefix("device:")
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: true)
        guard let row = dataSource.itemIdentifier(for: path) else { return }
        switch row.id {
        case let id where id.hasPrefix("provider:"):
            let harness = String(id.dropFirst("provider:".count))
            navigationController?.pushViewController(ProviderAccountsViewController(app: app, deviceId: accountsHost, focusHarness: harness), animated: true)
        case "archived":
            navigationController?.pushViewController(FolderViewController(app: app, folder: FolderRowVM(id: "archived", name: "Archived", count: 0, symbol: "archivebox")), animated: true)
        case "signout":
            let alert = UIAlertController(title: "Sign out?", message: "This device forgets this account's local data.", preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in self?.app.signOut() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.popoverPresentationController?.sourceView = collectionView.cellForItem(at: path)
            present(alert, animated: true)
        default:
            break
        }
    }
}

/// The signed-in person: initials avatar, name, email · organization.
final class ProfileCell: UICollectionViewListCell {
    private let avatar = UILabel()
    private let name = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.font = Fonts.ui(.sansSemibold, 22)
        avatar.textAlignment = .center
        avatar.textColor = Palette.accent
        avatar.backgroundColor = Palette.accentSoft
        avatar.layer.cornerRadius = 28
        avatar.clipsToBounds = true
        name.font = Fonts.ui(.sansSemibold, 20)
        name.textColor = Palette.text
        detail.font = Fonts.ui(.sans, 14)
        detail.textColor = Palette.secondary
        detail.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 56),
            avatar.heightAnchor.constraint(equalToConstant: 56),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = Palette.elevated
        backgroundConfiguration = bg
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name text: String, detail sub: String) {
        name.text = text
        detail.text = sub
        let words = text.split(separator: " ").prefix(2)
        avatar.text = words.compactMap { $0.first.map(String.init) }.joined().uppercased().nonEmpty ?? "Z"
        accessibilityIdentifier = "settings-profile"
        isAccessibilityElement = true
        accessibilityLabel = [text, sub].joined(separator: ", ")
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = Palette.elevated
        backgroundConfiguration = bg
    }
}
