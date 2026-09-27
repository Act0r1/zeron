import UIKit

/// What a new session will be created with.
struct NewSessionDraft: Equatable {
    var projectId: String?
    /// Projectless sessions run on an explicit host.
    var hostId: String?
    var branch: String?
    var worktree = false
    var harness = "claude-code"
    var model: String?
    var effort: String?
}

/// Options the pickers offer (from the core's workspace + host catalogs).
struct ProjectOption: Equatable {
    let id: String
    let name: String
    let device: String
    /// Display name of `device` (never show the id).
    let deviceName: String
    let online: Bool
    let git: Bool
    let colorIndex: Int
}

struct HostOption: Equatable {
    let id: String
    let name: String
    let online: Bool
}

struct ModelChoice: Equatable {
    let harness: String
    let harnessLabel: String
    let id: String
    let label: String
    let efforts: [String]
}

/// "Ask anything" → a composer-first canvas. Context is set with native menus
/// (project, branch/worktree, model, effort) that load lazily; the composer is
/// focused immediately so the common case is: tap, type, send.
final class NewSessionViewController: UIViewController, UIGestureRecognizerDelegate {
    private let app: AppModel
    private let onCreated: (String) -> Void
    private let composer = ComposerBar()
    private let hero = UILabel()
    private let mark = UIImageView()
    private var draft: NewSessionDraft
    private var models: [ModelChoice] = []

    /// Embedded in the iPad split's main column (no sheet chrome).
    private let embedded: Bool

    init(app: AppModel, prompt: String?, embedded: Bool = false, onCreated: @escaping (String) -> Void) {
        self.app = app
        self.embedded = embedded
        self.onCreated = onCreated
        self.draft = app.lastDraft
        super.init(nibName: nil, bundle: nil)
        composer.text = prompt ?? ""
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Tapping the canvas puts the keyboard away (the card stays open here).
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        view.addGestureRecognizer(dismissTap)
        view.backgroundColor = Palette.background
        title = embedded ? nil : "New Session"
        if !embedded {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }

        mark.image = BrandMarks.image(for: draft.harness, side: 34)
        mark.tintColor = Palette.text
        mark.contentMode = .center
        hero.text = "What are we building?"
        hero.numberOfLines = 2
        hero.font = Fonts.ui(.sansSemibold, 22)
        hero.textColor = Palette.text
        hero.textAlignment = .center
        let heroStack = UIStackView(arrangedSubviews: [mark, hero])
        heroStack.axis = .vertical
        heroStack.spacing = 14
        heroStack.alignment = .center
        heroStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heroStack)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.placeholder = "Describe the task"
        composer.chipsAlwaysVisible = true
        composer.attachMenu = { [weak self] in
            guard let self else { return UIMenu() }
            return AttachmentPicker.menu(host: self, limit: 8 - self.composer.images.count) { [weak self] in self?.composer.addImages($0) }
        }
        composer.onChipTap = { _, _ in }
        composer.mentionSearch = { [weak self] q in
            guard let self, let p = self.project else { return [] }
            return await self.app.searchFiles(deviceId: p.device, spaceId: p.id, query: q)
        }
        composer.onSend = { [weak self] text, images, _ in self?.create(text: text, images: images) }
        view.addSubview(composer)
        heroStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24).isActive = true
        if embedded {
            // iPad draft (t3): the composer sits mid-column at the message
            // width (768pt), the headline 32pt above it; the keyboard pushes
            // it up.
            let centered = composer.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: 40)
            centered.priority = .defaultHigh
            let fill = composer.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -40)
            fill.priority = .defaultHigh
            hero.font = Fonts.ui(.sansSemibold, 28)
            NSLayoutConstraint.activate([
                composer.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
                composer.widthAnchor.constraint(lessThanOrEqualToConstant: 768),
                fill,
                centered,
                composer.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
                heroStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                heroStack.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -32),
            ])
        } else {
            NSLayoutConstraint.activate([
                heroStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                heroStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -60),
                composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            ])
        }
        if draft.projectId == nil, draft.hostId == nil { draft.projectId = app.projectOptions.first?.id }
        if draft.projectId == nil, draft.hostId == nil {
            // No projects yet: run on the first reachable host.
            draft.hostId = app.hostOptions.first(where: \.online)?.id ?? app.hostOptions.first?.id
        }
        refreshChips()
        Task { [weak self] in
            guard let self else { return }
            self.models = await self.app.models(for: self.deviceId)
            self.refreshChips()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The sheet focuses at once; the iPad draft waits for a tap (its
        // on-screen keyboard would cover half the column).
        if !embedded { composer.becomeFirstResponder() }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view.map { !$0.isDescendant(of: composer) } ?? true
    }

    private var project: ProjectOption? { app.projectOptions.first { $0.id == draft.projectId } }
    private var deviceId: String { project?.device ?? draft.hostId ?? "" }

    private func refreshChips() {
        var chips: [ComposerChip] = []
        if let p = project {
            chips.append(ComposerChip(id: "project", title: p.name, symbol: nil, icon: ProjectTile.image(name: p.name, colorIndex: p.colorIndex)))
            if p.git {
                chips.append(ComposerChip(id: "branch", title: draft.worktree ? "New worktree" : (draft.branch ?? "Current branch"), symbol: draft.worktree ? "square.split.bottomrightquarter" : nil, icon: draft.worktree ? nil : BranchIcon.sized()))
            }
        } else {
            let host = app.hostOptions.first { $0.id == draft.hostId }
            chips.append(ComposerChip(id: "project", title: "No project", symbol: "tray"))
            chips.append(ComposerChip(id: "host", title: host?.name ?? "Choose host", symbol: "desktopcomputer"))
        }
        let model = models.first { $0.harness == draft.harness && $0.id == draft.model } ?? models.first { $0.harness == draft.harness }
        chips.append(ComposerChip(id: "model", title: model?.label ?? HarnessNames.label(draft.harness), symbol: nil, icon: BrandMarks.image(for: draft.harness, side: 13)))
        if let efforts = model?.efforts, !efforts.isEmpty {
            chips.append(ComposerChip(id: "effort", title: (draft.effort ?? efforts[efforts.count / 2]).capitalized, symbol: "gauge.with.dots.needle.67percent"))
        }
        composer.chips = chips
        composer.chipMenus = [
            "project": { [weak self] in self?.projectMenu() },
            "host": { [weak self] in self?.hostMenu() },
            "branch": { [weak self] in self?.branchMenu() },
            "model": { [weak self] in self?.modelMenu() },
            "effort": { [weak self] in self?.effortMenu() },
        ]
        mark.image = BrandMarks.image(for: draft.harness, side: 34)
        // t3's draft headline names the project.
        hero.text = project.map { "What should we build in \($0.name)?" } ?? "What are we building?"
    }

    private func projectMenu() -> UIMenu {
        let byDevice = Dictionary(grouping: app.projectOptions, by: \.device)
        var sections: [UIMenuElement] = byDevice.keys.sorted { (byDevice[$0]?.first?.deviceName ?? "") < (byDevice[$1]?.first?.deviceName ?? "") }.map { device in
            let items = byDevice[device]!
            let name = items.first?.deviceName ?? "Host"
            return UIMenu(title: name + (items.first?.online == false ? " · offline" : ""), options: .displayInline, children: items.map { p in
                UIAction(title: p.name, image: UIImage(systemName: p.git ? "folder.badge.gearshape" : "folder"), state: p.id == draft.projectId ? .on : .off) { [weak self] _ in
                    self?.draft.projectId = p.id
                    self?.draft.hostId = nil
                    self?.draft.branch = nil
                    self?.refreshChips()
                }
            })
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "No Project…", image: UIImage(systemName: "tray"), state: draft.projectId == nil ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.draft.projectId = nil
                self.draft.hostId = self.draft.hostId ?? self.app.hostOptions.first(where: \.online)?.id ?? self.app.hostOptions.first?.id
                self.refreshChips()
            },
            UIAction(title: "New Project…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                guard let self else { return }
                let vc = NewProjectViewController(app: self.app)
                vc.onCreated = { [weak self] id in
                    self?.draft.projectId = id
                    self?.draft.hostId = nil
                    self?.draft.branch = nil
                    self?.refreshChips()
                }
                self.present(UINavigationController(rootViewController: vc), animated: true)
            },
        ]))
        return UIMenu(title: "Project", children: sections)
    }

    private func hostMenu() -> UIMenu {
        UIMenu(title: "Run on", children: app.hostOptions.map { h in
            UIAction(title: h.name, subtitle: h.online ? "Online" : "Offline", image: UIImage(systemName: "desktopcomputer"), state: h.id == draft.hostId ? .on : .off) { [weak self] _ in
                self?.draft.hostId = h.id
                self?.refreshChips()
            }
        })
    }

    private func branchMenu() -> UIMenu {
        UIMenu(title: "Checkout", children: [
            UIAction(title: "New worktree", subtitle: "Isolated branch for this session", image: UIImage(systemName: "square.split.bottomrightquarter"), state: draft.worktree ? .on : .off) { [weak self] _ in
                self?.draft.worktree.toggle()
                self?.refreshChips()
            },
            UIMenu(title: "Branch", options: .displayInline, children: [UIDeferredMenuElement { [weak self] done in
                guard let self, let p = self.project else { return done([]) }
                Task { @MainActor in
                    let refs = await self.app.refs(projectId: p.id)
                    done(refs.map { ref in
                        UIAction(title: ref, state: ref == (self.draft.branch ?? refs.first) ? .on : .off) { [weak self] _ in
                            self?.draft.branch = ref
                            self?.refreshChips()
                        }
                    })
                }
            }]),
        ])
    }

    private func modelMenu() -> UIMenu {
        let byHarness = Dictionary(grouping: models, by: \.harness)
        return UIMenu(title: "Model", children: byHarness.keys.sorted().map { h in
            UIMenu(title: byHarness[h]!.first!.harnessLabel, image: BrandMarks.image(for: h, side: 16), options: .displayInline, children: byHarness[h]!.map { m in
                UIAction(title: m.label, state: m.harness == draft.harness && m.id == draft.model ? .on : .off) { [weak self] _ in
                    self?.draft.harness = m.harness
                    self?.draft.model = m.id
                    self?.draft.effort = nil
                    self?.refreshChips()
                }
            })
        })
    }

    private func effortMenu() -> UIMenu {
        let model = models.first { $0.harness == draft.harness && $0.id == draft.model } ?? models.first { $0.harness == draft.harness }
        return UIMenu(title: "Reasoning effort", children: (model?.efforts ?? []).map { e in
            UIAction(title: e.capitalized, state: e == draft.effort ? .on : .off) { [weak self] _ in
                self?.draft.effort = e
                self?.refreshChips()
            }
        })
    }

    private func create(text: String, images: [StagedImage]) {
        app.lastDraft = draft
        guard let chatId = app.createSession(draft: draft, text: text, images: images) else {
            let alert = UIAlertController(title: "Couldn't start the session", message: "Choose a project or a host that can run it.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        onCreated(chatId)
    }
}

enum HarnessNames {
    /// The core's harness catalog label (same table as desktop).
    static func label(_ id: String) -> String { harnessLabel(harness: id) }
}
