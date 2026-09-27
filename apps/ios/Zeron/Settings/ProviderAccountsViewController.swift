import UIKit

/// Accounts & Usage for one computer: every agent CLI login saved there,
/// grouped per provider, with the plan usage windows spelled out (meter,
/// percent, reset time — no hover on a phone to hide them behind). Tapping a
/// login makes it the one in use (Wi-Fi-picker style); remove is in the
/// context menu; pull to refresh re-probes usage. Logins are added on the
/// computer itself (their OAuth redirects land on its loopback).
final class ProviderAccountsViewController: UIViewController, UICollectionViewDelegate {
    private let app: AppModel
    private var deviceId: String?
    /// Opened for one provider (from a session): scroll to it.
    private let focusHarness: String?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>!
    private var snapshot: AgentAccountsSnapshot?
    private var state: LoadState = .loading
    private var switching: String?
    private var didFocus = false

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum Item: Hashable {
        case account(String)
        case message(String)
    }

    init(app: AppModel, deviceId: String?, focusHarness: String? = nil) {
        self.app = app
        self.deviceId = deviceId ?? app.primaryHostId
        self.focusHarness = focusHarness
        super.init(nibName: nil, bundle: nil)
        title = "Accounts & Usage"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var deviceName: String {
        deviceId.map { app.deviceName($0) } ?? "your computer"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingSwipe(path) }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "provider-accounts"
        view.addSubview(collectionView)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            self?.load(force: true) { refresh?.endRefreshing() }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        let accountCell = UICollectionView.CellRegistration<ProviderAccountCell, String> { [weak self] cell, _, id in
            guard let self, let a = self.account(id) else { return }
            cell.configure(a, switching: self.switching == id)
        }
        let messageCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            var c = UIListContentConfiguration.cell()
            c.text = text
            c.textProperties.font = Fonts.ui(.sans, 15)
            c.textProperties.color = Palette.secondary
            c.textProperties.alignment = .center
            cell.contentConfiguration = c
            var bg = UIBackgroundConfiguration.listCell()
            bg.backgroundColor = Palette.elevated
            cell.backgroundConfiguration = bg
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, path in
            guard let self, let harness = self.dataSource.sectionIdentifier(for: path.section) else { return }
            var c = UIListContentConfiguration.groupedHeader()
            if harness.hasPrefix("_") {
                c.text = nil
            } else {
                c.text = HarnessNames.label(harness)
                c.textProperties.font = Fonts.ui(.sansSemibold, 15)
                c.textProperties.color = Palette.text
                c.image = BrandMarks.image(for: harness, side: 16)
                c.imageToTextPadding = 8
            }
            view.contentConfiguration = c
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, path in
            guard let self, let harness = self.dataSource.sectionIdentifier(for: path.section) else { return }
            var c = UIListContentConfiguration.groupedFooter()
            c.text = self.footerText(for: harness)
            c.textProperties.color = harness.hasPrefix("_") ? Palette.tertiary : Palette.warning
            view.contentConfiguration = c
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, path, item in
            switch item {
            case let .account(id): cv.dequeueConfiguredReusableCell(using: accountCell, for: path, item: id)
            case let .message(text): cv.dequeueConfiguredReusableCell(using: messageCell, for: path, item: text)
            }
        }
        dataSource.supplementaryViewProvider = { cv, kind, path in
            kind == UICollectionView.elementKindSectionHeader
                ? cv.dequeueConfiguredReusableSupplementary(using: header, for: path)
                : cv.dequeueConfiguredReusableSupplementary(using: footer, for: path)
        }

        updateDeviceMenu()
        if let deviceId, let cached = app.providerAccounts[deviceId] {
            snapshot = cached
            state = .loaded
        }
        render()
        // Fast list first (the host's last probe), then fresh usage.
        load(force: false) { [weak self] in self?.load(force: true) }
    }

    // MARK: Data

    private func account(_ id: String) -> AgentAccount? {
        snapshot?.accounts.first { $0.id == id }
    }

    private func load(force: Bool, then done: (() -> Void)? = nil) {
        guard let deviceId else {
            state = .failed("No computer to ask yet. Open Zeron on a computer to add one.")
            render()
            done?()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let s = try await self.app.loadProviderAccounts(on: deviceId, force: force)
                guard deviceId == self.deviceId else { done?(); return }
                self.snapshot = s
                self.state = .loaded
            } catch {
                guard deviceId == self.deviceId else { done?(); return }
                // Keep what's on screen; say why only when there's nothing.
                if self.snapshot == nil { self.state = .failed(Self.describe(error, device: self.deviceName)) }
            }
            self.render()
            done?()
        }
    }

    static func describe(_ error: Error, device: String) -> String {
        switch error as? CoreError {
        case .HostUnavailable?: "\(device) is offline. Accounts show up when it's back."
        case .Unsupported?: "\(device) needs a newer Zeron to show accounts here."
        default: "Couldn't load accounts from \(device)."
        }
    }

    private func render() {
        var s = NSDiffableDataSourceSnapshot<String, Item>()
        switch state {
        case .loading where snapshot == nil:
            s.appendSections(["_status"])
            s.appendItems([.message("Loading accounts…")])
        case let .failed(message) where snapshot == nil:
            s.appendSections(["_status"])
            s.appendItems([.message(message)])
        default:
            let groups = snapshot.map(ProviderUsage.groups) ?? []
            if groups.isEmpty {
                s.appendSections(["_status"])
                s.appendItems([.message("No provider accounts on \(deviceName) yet.")])
            }
            for g in groups {
                s.appendSections([g.harness])
                s.appendItems(g.accounts.map { .account($0.id) })
            }
        }
        s.appendSections(["_about"])
        s.reconfigureItems(s.itemIdentifiers)
        dataSource.apply(s, animatingDifferences: false)
        focusIfNeeded()
    }

    private func footerText(for section: String) -> String? {
        if section == "_about" {
            let updated = snapshot.flatMap { ProviderUsage.updatedText($0) }
            return [updated.map { $0 + "." }, "Switching changes the login \(deviceName) uses for new sessions. To add an account, sign in from Zeron on \(deviceName)."]
                .compactMap { $0 }.joined(separator: "\n")
        }
        guard !section.hasPrefix("_"), let snapshot else { return nil }
        let warnings = snapshot.warnings.filter { $0.harness == section }.map(\.message)
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    /// Scroll so the focused provider's header sits at the top (the first
    /// section already does).
    private func focusIfNeeded() {
        guard !didFocus, let focusHarness, let section = dataSource.snapshot().indexOfSection(focusHarness) else { return }
        didFocus = true
        guard section > 0 else { return }
        collectionView.layoutIfNeeded()
        guard let header = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) else { return }
        let inset = collectionView.adjustedContentInset
        let maxY = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.contentOffset.y = min(maxY, header.frame.minY - inset.top)
    }

    // MARK: Device picker

    private func updateDeviceMenu() {
        let hosts = app.hostOptions
        guard hosts.count > 1 else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        let menu = UIMenu(title: "Computer", children: hosts.map { h in
            UIAction(title: h.name, subtitle: h.online ? "Online" : "Offline", image: UIImage(systemName: "desktopcomputer"), state: h.id == deviceId ? .on : .off) { [weak self] _ in
                self?.show(device: h.id)
            }
        })
        let item = UIBarButtonItem(title: deviceName, image: nil, primaryAction: nil, menu: menu)
        item.accessibilityIdentifier = "accounts-device"
        navigationItem.rightBarButtonItem = item
    }

    private func show(device id: String) {
        guard id != deviceId else { return }
        deviceId = id
        snapshot = app.providerAccounts[id]
        state = snapshot == nil ? .loading : .loaded
        updateDeviceMenu()
        render()
        load(force: false) { [weak self] in self?.load(force: true) }
    }

    // MARK: Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: true)
        guard case let .account(id)? = dataSource.itemIdentifier(for: path), let a = account(id) else { return }
        if a.active { return }
        guard a.switchable else {
            let alert = UIAlertController(title: "Can't switch to this login", message: "Zeron couldn't read its credentials on \(deviceName). Sign in to it again there.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        activate(a)
    }

    private func activate(_ a: AgentAccount) {
        guard let deviceId, switching == nil else { return }
        let previous = snapshot
        // Optimistic: the check moves now; the host's reply confirms it.
        if var next = snapshot {
            for i in next.accounts.indices where next.accounts[i].harness == a.harness && next.accounts[i].provider == a.provider {
                next.accounts[i].active = next.accounts[i].id == a.id
            }
            snapshot = next
        }
        switching = a.id
        UISelectionFeedbackGenerator().selectionChanged()
        render()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.snapshot = try await self.app.activateProviderAccount(a, on: deviceId)
                self.switching = nil
                self.render()
                Toast.show("\(HarnessNames.label(a.harness)) now uses \(ProviderUsage.title(a))", in: self.view.window)
            } catch {
                self.snapshot = previous
                self.switching = nil
                self.render()
                self.alert("Couldn't switch accounts", error)
            }
        }
    }

    private func forget(_ a: AgentAccount, from source: UIView?) {
        guard let deviceId else { return }
        let message = a.active
            ? "\(HarnessNames.label(a.harness)) on \(deviceName) will be signed out until you pick another login."
            : "Its saved login is removed from \(deviceName)."
        let sheet = UIAlertController(title: "Remove \(ProviderUsage.title(a))?", message: message, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Remove Account", style: .destructive) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.snapshot = try await self.app.forgetProviderAccount(a, on: deviceId)
                    self.render()
                } catch {
                    self.alert("Couldn't remove the account", error)
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    private func alert(_ title: String, _ error: Error) {
        let alert = UIAlertController(title: title, message: Self.describe(error, device: deviceName), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard case let .account(id)? = dataSource.itemIdentifier(for: path), let a = account(id), a.switchable else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, view, done in
            self?.forget(a, from: view)
            done(true)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, case let .account(id)? = dataSource.itemIdentifier(for: path), let a = account(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var items: [UIMenuElement] = []
            if !a.active, a.switchable {
                items.append(UIAction(title: "Use This Account", image: UIImage(systemName: "checkmark.circle")) { _ in self?.activate(a) })
            }
            if let email = a.email {
                items.append(UIAction(title: "Copy Email", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = email })
            }
            if a.switchable {
                items.append(UIAction(title: "Remove Account…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self?.forget(a, from: self?.collectionView.cellForItem(at: path))
                })
            }
            return UIMenu(children: items)
        }
    }
}

/// One login: avatar (ringed when in use), email, plan · "In use", then a
/// meter per usage window (or why there's none).
final class ProviderAccountCell: UICollectionViewListCell {
    private let avatar = UILabel()
    private let ring = UIView()
    private let title = UILabel()
    private let meta = UILabel()
    private let meters = UIStackView()
    private let note = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.font = Fonts.ui(.sansSemibold, 15)
        avatar.textAlignment = .center
        avatar.textColor = Palette.text
        avatar.backgroundColor = Palette.controlFill
        avatar.layer.cornerRadius = 17
        avatar.clipsToBounds = true
        ring.layer.cornerRadius = 20
        ring.layer.borderWidth = 2
        ring.layer.borderColor = Palette.accent.cgColor
        ring.isUserInteractionEnabled = false
        title.font = Fonts.ui(.sansMedium, 16)
        title.textColor = Palette.text
        title.lineBreakMode = .byTruncatingMiddle
        meta.font = Fonts.ui(.sans, 13)
        meta.textColor = Palette.secondary
        meters.axis = .vertical
        meters.spacing = 12
        note.font = Fonts.ui(.sans, 13)
        note.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, meta])
        text.axis = .vertical
        text.spacing = 2
        check.tintColor = Palette.accent
        check.setContentHuggingPriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [ring, text, spinner, check])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 12
        let body = UIStackView(arrangedSubviews: [top, meters, note])
        body.axis = .vertical
        body.spacing = 12
        body.setCustomSpacing(14, after: top)
        body.translatesAutoresizingMaskIntoConstraints = false
        ring.addSubview(avatar)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 40),
            ring.heightAnchor.constraint(equalToConstant: 40),
            avatar.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),
            body.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 2),
            body.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -2),
            body.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProviderAccountCell, _) in
            self.ring.layer.borderColor = Palette.accent.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ a: AgentAccount, switching: Bool) {
        let name = ProviderUsage.title(a)
        avatar.text = a.apiKey ? "⌘" : String(name.prefix(1)).uppercased()
        ring.layer.borderColor = a.active ? Palette.accent.cgColor : UIColor.clear.cgColor
        title.text = name
        let line = NSMutableAttributedString()
        if let detail = ProviderUsage.detail(a) {
            line.append(NSAttributedString(string: detail, attributes: [.foregroundColor: Palette.secondary]))
        }
        if a.active {
            if line.length > 0 { line.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: Palette.tertiary])) }
            line.append(NSAttributedString(string: "In use", attributes: [.foregroundColor: Palette.accent, .font: Fonts.ui(.sansMedium, 13)]))
        } else if !a.switchable {
            if line.length > 0 { line.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: Palette.tertiary])) }
            line.append(NSAttributedString(string: "Credentials unavailable", attributes: [.foregroundColor: Palette.tertiary]))
        }
        meta.attributedText = line
        meta.isHidden = line.length == 0

        meters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in a.usageWindows {
            let m = UsageMeterView()
            m.configure(w)
            meters.addArrangedSubview(m)
        }
        meters.isHidden = a.usageWindows.isEmpty
        let missing = a.usageWindows.isEmpty ? ProviderUsage.missingUsage(a) : a.usageError
        note.text = missing
        note.textColor = a.usageError != nil && !a.apiKey ? Palette.warning : Palette.tertiary
        note.isHidden = missing == nil

        if switching { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !switching
        // In the title row (not mid-cell beside the meters).
        check.isHidden = !a.active || switching
        check.tintColor = Palette.accent
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = Palette.elevated
        backgroundConfiguration = bg
        accessibilityIdentifier = "account-\(a.id)"
        accessibilityLabel = [name, ProviderUsage.detail(a), a.active ? "In use" : nil].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = a.active ? [.button, .selected] : .button
        accessibilityValue = a.active ? "In use" : nil
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var bg = UIBackgroundConfiguration.listCell().updated(for: state)
        bg.backgroundColor = state.isHighlighted ? Palette.controlFill : Palette.elevated
        backgroundConfiguration = bg
    }
}
