//
//  ToolbarLayoutEditor.swift
//  rootshell
//
//  Native UIKit editor for the keyboard toolbar layout. Hosts an inset-grouped
//  UICollectionView with one section per row (pinned groups, Main Row, and each
//  Drawer row) that supports dragging keys *across* section boundaries, which
//  SwiftUI's List `.onMove` cannot do.
//
//  Controls:
//    - A grip on every row reorders it, across sections.
//    - Long-press lift drag via drag-and-drop, which shares its hold with the
//      context menu the way Files and Photos do (hold = menu, move = drag).
//    - Swipe to hide (built-in) or remove from the toolbar (custom).
//    - Context menu: edit, move within or between rows, Key Color, hide or remove.
//    - A header's + adds keys to its row, and a tap on the header collapses it.
//    - Select mode picks several keys for the host's bottom bar.
//
//  Every change goes to the host as a named edit on the layout, so the host
//  can ask before changing a shared layout and can undo it. The list is then
//  redrawn from the layout. An empty row holds a placeholder item and a
//  collapsed row a summary item, so each still takes a drop.
//

import SwiftUI
import UIKit

// MARK: - Shared pieces

extension KeyboardToolbarManager.ToolbarSection {
    var symbolName: String {
        switch self {
        case .pinnedLeading, .pinnedTrailing: return "pin"
        case .mainRow: return "tray.and.arrow.up"
        case .drawer: return "tray.and.arrow.down"
        }
    }
}

/// How a key reads in the settings lists: its name and a 28pt badge.
enum ToolbarKeyChip {
    static func label(for slot: KeySlot, manager: KeyboardToolbarManager) -> String {
        switch slot {
        case .builtIn(let keyID): return keyID.displayName
        case .custom(let uuid): return manager.customKey(for: uuid)?.label ?? String(localized: "Unknown")
        }
    }

    /// The key's symbol, or its first characters, in its toolbar color on a chip.
    static func image(for slot: KeySlot, manager: KeyboardToolbarManager, tint: UIColor,
                      background: UIColor) -> UIImage {
        let symbolName: String?
        let text: String
        switch slot {
        case .builtIn(let keyID):
            symbolName = keyID.iconName
            text = keyID.keyValue
        case .custom(let uuid):
            let key = manager.customKey(for: uuid)
            symbolName = key?.iconName
            text = String((key?.label ?? "").prefix(2))
        }
        let foreground = manager.glyphColor(for: slot) ?? tint
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { _ in
            background.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            if let symbolName,
               let symbol = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
               )?.withTintColor(foreground, renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2,
                                        y: (size.height - symbol.size.height) / 2))
            } else {
                let attributed = NSAttributedString(string: text, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: foreground,
                ])
                let textSize = attributed.size()
                attributed.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                            y: (size.height - textSize.height) / 2))
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// What the editor asks of the screen that hosts it.
struct ToolbarLayoutEditorActions {
    /// Runs a named edit on the layout it should change, and says whether it
    /// ran now. The host may ask first, and records undo. `keys` are the keys it moves.
    var edit: (_ name: String, _ keys: [KeySlot], _ change: @escaping (ToolbarContext) -> Void) -> Bool
    /// Runs a named change that belongs to no one layout, such as a key's color, and records undo.
    var record: (_ name: String, _ change: () -> Void) -> Void
    var addKey: (KeyboardToolbarManager.ToolbarSection) -> Void
    var editCustomKey: (UUID) -> Void
}

// MARK: - SwiftUI bridge

struct ToolbarLayoutEditor: UIViewControllerRepresentable {
    var manager: KeyboardToolbarManager
    /// Whose layout is being edited.
    var toolbar: ToolbarContext
    var themeColors: SheetThemeColors?
    var capacity: Int
    /// Main-row keys the previewed surface sends to the drawer.
    var overflowing: Set<KeySlot> = []
    /// The toolbar being viewed sits in a remote screen's bar, which leaves some keys out.
    var marksHostBarKeys = false
    var isSelecting = false
    @Binding var selection: Set<KeySlot>
    @Binding var collapsed: Set<KeyboardToolbarManager.ToolbarSection>
    var reveal: ToolbarKeyPulse?
    /// Changes when an edit was called off, so the list matches the layout again.
    var refreshToken = 0
    var actions: ToolbarLayoutEditorActions
    @Binding var contentHeight: CGFloat

    func makeUIViewController(context: Context) -> ToolbarLayoutEditorController {
        let controller = ToolbarLayoutEditorController(manager: manager, context: toolbar, actions: actions)
        controller.onContentHeightChange = { height in
            // Guard against a layout feedback loop: only push real changes.
            if abs(contentHeight - height) > 0.5 {
                contentHeight = height
            }
        }
        controller.onSelectionChange = { selection = $0 }
        controller.onCollapsedChange = { collapsed = $0 }
        controller.revealedToken = reveal?.token
        return controller
    }

    func updateUIViewController(_ controller: ToolbarLayoutEditorController, context: Context) {
        // Each setter redraws what it changes; the snapshot picks up the rest.
        controller.actions = actions
        controller.themeColors = themeColors
        controller.capacity = capacity
        controller.overflowing = overflowing
        controller.marksHostBarKeys = marksHostBarKeys
        controller.collapsed = collapsed
        controller.setSelecting(isSelecting)
        controller.applySnapshot(animated: true)
        controller.select(selection)
        controller.reveal(reveal)
    }
}

// MARK: - Section header

/// A row's header: a tap collapses the row, and + adds keys to it.
private final class ToolbarSectionHeaderView: UICollectionViewListCell {
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?
    private let countLabel = UILabel()
    let addButton = UIButton(type: .system)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let trailing = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        addButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .primaryActionTriggered)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        trailing.addArrangedSubview(countLabel)
        trailing.addArrangedSubview(addButton)
        trailing.spacing = 10
        trailing.alignment = .center
        accessibilityTraits.insert(.button)
    }

    /// The count beside + changes width with its text, and an accessory keeps
    /// the width it was given.
    func setCount(_ text: String, color: UIColor, font: UIFont) {
        countLabel.text = text
        countLabel.textColor = color
        countLabel.font = font
        let width = trailing.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        accessories = [
            .customView(configuration: .init(customView: chevron, placement: .leading(displayed: .always))),
            .customView(configuration: .init(customView: trailing, placement: .trailing(displayed: .always),
                                             reservedLayoutWidth: .custom(width))),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        // The chevron points along the reading direction while the row is closed.
        let quarter: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .pi / 2 : -.pi / 2
        let transform = collapsed ? CGAffineTransform(rotationAngle: quarter) : .identity
        accessibilityValue = collapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        guard chevron.transform != transform else { return }
        UIView.animate(withDuration: animated ? 0.2 : 0) { self.chevron.transform = transform }
    }

    @objc private func toggle() { onToggle?() }
}

// MARK: - Controller

@MainActor
final class ToolbarLayoutEditorController: UIViewController {
    typealias Section = KeyboardToolbarManager.ToolbarSection

    fileprivate nonisolated enum Item: Hashable, Sendable {
        case key(KeySlot)
        /// Stands in an empty row, so a drop has somewhere to land.
        case placeholder(Section)
        /// A collapsed row's keys on one line.
        case summary(Section)

        var slot: KeySlot? {
            if case .key(let slot) = self { return slot }
            return nil
        }
    }

    private let manager: KeyboardToolbarManager
    private let context: ToolbarContext
    private var layout: ToolbarLayoutConfig { manager.layout(for: context) }
    var actions: ToolbarLayoutEditorActions

    var themeColors: SheetThemeColors? {
        didSet {
            guard isViewLoaded, themeColors != oldValue else { return }
            applyTheme()
            reconfigureAllItems()
        }
    }
    /// Main-row capacity for the "X / Y" badge, measured by the preview.
    var capacity: Int = 1
    var overflowing: Set<KeySlot> = []
    var marksHostBarKeys = false
    var collapsed: Set<Section> = []
    /// The last reveal acted on.
    var revealedToken: Int?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var onSelectionChange: ((Set<KeySlot>) -> Void)?
    var onCollapsedChange: ((Set<Section>) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var lastReportedHeight: CGFloat = 0
    /// What each row was last drawn from, so only rows whose content changed are redrawn.
    private var drawn: [Item: String] = [:]
    private var refreshScheduled = false
    /// The key the open color picker colors.
    private var colorPickerSlot: KeySlot?

    init(manager: KeyboardToolbarManager, context: ToolbarContext, actions: ToolbarLayoutEditorActions) {
        self.manager = manager
        self.context = context
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        // Undo, sync and the other settings screens all change the layout from outside.
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh),
                                               name: KeyboardToolbarManager.layoutDidChangeNotification, object: nil)
        applyTheme()
        applySnapshot(animated: false)
        // Key badges are drawn images, which keep the appearance they were drawn in.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ToolbarLayoutEditorController, _: UITraitCollection) in
            self.reconfigureAllItems()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportContentHeight()
    }

    // MARK: Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.backgroundColor = .clear
        // Grouped lists add a large block of padding above section headers; that
        // is what left an empty band above "Main Row". Zero it so the first
        // header sits just below the nav bar like the original SwiftUI list.
        config.headerTopPadding = 0
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }
        // The editor already sits inside the SwiftUI section's horizontal margins,
        // so zero the list's own leading/trailing insets. Otherwise insetGrouped
        // double-insets and the cards end up dramatically narrower than the other
        // (native SwiftUI) sections.
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsets.leading = 0
            section.contentInsets.trailing = 0
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.allowsMultipleSelectionDuringEditing = true
        // The editor self-sizes to its full content and is hosted inside the
        // outer SwiftUI List, which does the scrolling. Disabling the collection
        // view's own scrolling keeps it a flat part of the page (no nested
        // scroll view). Drag-and-drop still auto-scrolls the enclosing List.
        collectionView.isScrollEnabled = false
        collectionView.alwaysBounceVertical = false
        // Hosted inside SwiftUI, the collection view otherwise inherits a top
        // safe-area content inset that pushes its content (the "Main Row" header)
        // down, leaving an empty band below the nav bar. Ignore it.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<ToolbarSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureHeader(view, at: indexPath.section, animated: false)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath.section)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            } else {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }

        // The grip (interactive movement).
        dataSource.reorderingHandlers.canReorderItem = { $0.slot != nil }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.commitReorder(transaction)
        }
    }

    // MARK: Snapshot

    /// The keys a row lists: not hidden, and still defined.
    private func keys(in section: Section) -> [KeySlot] {
        let hiddenKeys = layout.hiddenKeys
        return manager.slots(in: section, of: context).filter { slot in
            switch slot {
            case .builtIn(let keyID): return !hiddenKeys.contains(keyID)
            case .custom(let uuid): return manager.customKey(for: uuid) != nil
            }
        }
    }

    /// Redraws the list from the layout.
    func applySnapshot(animated: Bool) {
        guard isViewLoaded else { return }
        let current = dataSource.snapshot()
        let previous = Set(current.itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var listed = Set<KeySlot>()
        for section in manager.sections(in: context) {
            snapshot.appendSections([section])
            // A key listed twice would trap the data source.
            let slots = keys(in: section).filter { listed.insert($0).inserted }
            if slots.isEmpty {
                snapshot.appendItems([.placeholder(section)], toSection: section)
            } else if collapsed.contains(section) {
                snapshot.appendItems([.summary(section)], toSection: section)
            } else {
                snapshot.appendItems(slots.map(Item.key), toSection: section)
            }
        }
        // The diff sees identifiers only, so rows whose content changed are redrawn.
        let stale = snapshot.itemIdentifiers.filter { previous.contains($0) && drawn[$0] != signature(for: $0) }
        // Applying the same rows again would close an open swipe for nothing.
        let unchanged = stale.isEmpty && snapshot.sectionIdentifiers == current.sectionIdentifiers
            && snapshot.sectionIdentifiers.allSatisfy {
                snapshot.itemIdentifiers(inSection: $0) == current.itemIdentifiers(inSection: $0)
            }
        if !unchanged {
            if !stale.isEmpty { snapshot.reconfigureItems(stale) }
            dataSource.apply(snapshot, animatingDifferences: animated)
        }
        reconfigureSupplementaries(animated: animated)
        reportContentHeight()
    }

    /// One redraw for however many changes land in this turn of the run loop.
    @objc private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.applySnapshot(animated: true)
        }
    }

    /// Forces every cell to re-run its registration, for changes the content does not show.
    private func reconfigureAllItems() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        reconfigureSupplementaries(animated: false)
    }

    private func section(at index: Int) -> Section {
        dataSource.sectionIdentifier(for: index) ?? .mainRow
    }

    // MARK: Edits

    /// Sends one edit to the host. The list follows the layout, whether the
    /// edit ran, was put off, or changed nothing.
    @discardableResult
    private func edit(_ name: String, keys: [KeySlot],
                      _ change: @escaping (KeyboardToolbarManager, ToolbarContext) -> Void) -> Bool {
        let manager = self.manager
        let ran = actions.edit(name, keys) { change(manager, $0) }
        scheduleRefresh()
        return ran
    }

    private func remove(_ slot: KeySlot) {
        let name = slot.keyID != nil ? String(localized: "Hide Key") : String(localized: "Remove Key")
        edit(name, keys: []) { manager, context in manager.removeKeys([slot], in: context) }
    }

    private func place(_ slot: KeySlot, in section: Section, before anchor: KeySlot?) -> Bool {
        edit(String(localized: "Move Key"), keys: [slot]) { manager, context in
            manager.placeKeys([slot], in: section, before: anchor, in: context)
        }
    }

    /// The grip dropped a row: find where it landed and move its key there.
    private func commitReorder(_ transaction: NSDiffableDataSourceTransaction<Section, Item>) {
        let initial = transaction.initialSnapshot
        let final = transaction.finalSnapshot
        // The difference is over the flat list of rows, which a move across a
        // section boundary can leave in the same order.
        var moved = final.itemIdentifiers.first {
            initial.sectionIdentifier(containingItem: $0) != final.sectionIdentifier(containingItem: $0)
        }
        if moved == nil {
            for case .insert(_, let item, _) in transaction.difference { moved = item }
        }
        guard let moved, let slot = moved.slot, let section = final.sectionIdentifier(containingItem: moved) else {
            scheduleRefresh()
            return
        }
        let following = final.itemIdentifiers(inSection: section).drop { $0 != moved }.dropFirst()
        _ = place(slot, in: section, before: following.lazy.compactMap(\.slot).first)
    }

    // MARK: Selecting

    func setSelecting(_ selecting: Bool) {
        guard isViewLoaded, collectionView.isEditing != selecting else { return }
        collectionView.isEditing = selecting
        // A hold drags a row; while selecting, a touch only picks rows.
        collectionView.dragInteractionEnabled = !selecting
    }

    /// Makes the selected rows match the host's selection.
    func select(_ slots: Set<KeySlot>) {
        guard isViewLoaded else { return }
        let wanted = Set(slots.compactMap { dataSource.indexPath(for: .key($0)) })
        let current = Set(collectionView.indexPathsForSelectedItems ?? [])
        for indexPath in current.subtracting(wanted) { collectionView.deselectItem(at: indexPath, animated: false) }
        guard collectionView.isEditing else { return }
        for indexPath in wanted.subtracting(current) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func reportSelection() {
        let selected = collectionView.indexPathsForSelectedItems ?? []
        onSelectionChange?(Set(selected.compactMap { dataSource.itemIdentifier(for: $0)?.slot }))
    }

    // MARK: Collapsing

    private func setCollapsed(_ isCollapsed: Bool, _ section: Section) {
        guard collapsed.contains(section) != isCollapsed else { return }
        if isCollapsed { collapsed.insert(section) } else { collapsed.remove(section) }
        onCollapsedChange?(collapsed)
        applySnapshot(animated: true)
        if collectionView.isEditing { reportSelection() }
    }

    // MARK: Revealing

    /// Scrolls the enclosing list to a key's row and flashes it, opening its row first.
    func reveal(_ pulse: ToolbarKeyPulse?) {
        guard let pulse, pulse.token != revealedToken else { return }
        revealedToken = pulse.token
        // Off the SwiftUI update this is called from, which may not change state.
        Task { @MainActor [weak self] in
            guard let self, let section = self.manager.section(holding: pulse.slot, in: self.context) else { return }
            if self.collapsed.contains(section) {
                self.setCollapsed(false, section)
                // The list around the editor takes a moment to grow to its new height.
                try? await Task.sleep(for: .milliseconds(350))
                // A newer reveal has already scrolled somewhere else.
                guard self.revealedToken == pulse.token else { return }
            }
            self.scrollToAndFlash(.key(pulse.slot))
        }
    }

    private func scrollToAndFlash(_ item: Item) {
        guard let indexPath = dataSource.indexPath(for: item) else { return }
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        var ancestor = collectionView.superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        if let scrollView = ancestor as? UIScrollView {
            // Room above and below, so the row lands clear of the bars and near the middle.
            let margin = scrollView.bounds.height * 0.25
            scrollView.scrollRectToVisible(collectionView.convert(frame.insetBy(dx: 0, dy: -margin), to: scrollView),
                                           animated: true)
        }
        collectionView.flashKeyHighlight(over: frame, color: tintColor)
    }

    // MARK: Swipe actions

    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let slot = dataSource.itemIdentifier(for: indexPath)?.slot else { return nil }
        let title = slot.keyID != nil ? String(localized: "Hide") : String(localized: "Remove")
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, completion in
            self?.remove(slot)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    // MARK: Supplementary configuration

    /// Keys on the main row, pinned groups included.
    private var mainRowKeyCount: Int {
        keys(in: .pinnedLeading).count + keys(in: .mainRow).count + keys(in: .pinnedTrailing).count
    }

    private func configureHeader(_ view: ToolbarSectionHeaderView, at index: Int, animated: Bool) {
        let section = self.section(at: index)
        let title = section.title(drawerRows: layout.drawerRows.count)
        var content = view.defaultContentConfiguration()
        content.text = title
        view.contentConfiguration = content
        view.backgroundConfiguration = .clear()

        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        if section == .mainRow {
            // The row's capacity is shared with the pinned groups at its ends.
            view.setCount("\(mainRowKeyCount) / \(capacity)",
                          color: overflowing.isEmpty ? .systemGreen : .systemOrange,
                          font: .systemFont(ofSize: footnote.pointSize, weight: .medium))
        } else {
            view.setCount(String(localized: "\(keys(in: section).count) keys"), color: .secondaryLabel, font: footnote)
        }
        view.addButton.accessibilityLabel = String(localized: "Add Keys to \(title)")
        view.setCollapsed(collapsed.contains(section), animated: animated)
        view.onToggle = { [weak self] in
            guard let self else { return }
            self.setCollapsed(!self.collapsed.contains(section), section)
        }
        view.onAdd = { [weak self] in self?.actions.addKey(section) }
    }

    private func configureFooter(_ view: UICollectionViewListCell, at index: Int) {
        var content = view.defaultContentConfiguration()
        switch section(at: index) {
        case .drawer:
            content.text = String(localized: "Scrolls horizontally on the keyboard.")
        case .pinnedLeading:
            content.text = String(localized: "Stays at the left end of the main row when it is full.")
        case .pinnedTrailing:
            content.text = String(localized: "Stays at the right end of the main row when it is full.")
        case .mainRow:
            let overflow = overflowing.count
            if overflow > 0 {
                content.text = String(localized: "\(overflow) key\(overflow == 1 ? "" : "s") will overflow to the drawer.")
                content.textProperties.color = .systemOrange
            } else if layout.mainRowScrolls, mainRowKeyCount > capacity {
                content.text = String(localized: "More keys than fit at once. The row scrolls to reach the rest.")
            } else {
                content.text = String(localized: "These keys fill the main toolbar row. Drag keys between Main Row and Drawer.")
            }
        }
        view.contentConfiguration = content
        view.backgroundConfiguration = .clear()
    }

    private func reconfigureSupplementaries(animated: Bool) {
        let header = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: header) {
            if let view = collectionView.supplementaryView(forElementKind: header, at: indexPath) as? ToolbarSectionHeaderView {
                configureHeader(view, at: indexPath.section, animated: animated)
            }
        }
        let footer = UICollectionView.elementKindSectionFooter
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: footer) {
            if let view = collectionView.supplementaryView(forElementKind: footer, at: indexPath) as? UICollectionViewListCell {
                configureFooter(view, at: indexPath.section)
            }
        }
    }

    // MARK: Cell content

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.cell()
        switch item {
        case .key(let slot):
            content.text = ToolbarKeyChip.label(for: slot, manager: manager)
            // The badge is a drawn image, so its colors are settled for this appearance here.
            content.image = ToolbarKeyChip.image(for: slot, manager: manager,
                                                 tint: tintColor.resolvedColor(with: traitCollection),
                                                 background: chipBackgroundColor.resolvedColor(with: traitCollection))
            content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.secondaryText = note(for: slot)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            content.prefersSideBySideTextAndSecondaryText = slot.customID != nil
            var accessories: [UICellAccessory] = [.multiselect(displayed: .whenEditing)]
            if overflowing.contains(slot) {
                content.textProperties.color = .secondaryLabel
                accessories.append(.label(text: String(localized: "Overflows"), options: .init(
                    tintColor: .systemOrange, font: .preferredFont(forTextStyle: .footnote))))
            }
            accessories.append(.reorder(displayed: .whenNotEditing, options: .init(showsVerticalSeparator: false)))
            cell.accessories = accessories
        case .placeholder:
            content.text = String(localized: "Drag keys here, or tap + to add some.")
            content.textProperties.color = .secondaryLabel
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            cell.accessories = []
        case .summary(let section):
            content.text = summary(of: section)
            content.textProperties.color = .secondaryLabel
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.numberOfLines = 2
            cell.accessories = []
        }
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = rowBackgroundColor
        cell.backgroundConfiguration = background
        drawn[item] = signature(for: item)
    }

    /// Everything a row's content is drawn from.
    private func signature(for item: Item) -> String {
        switch item {
        case .key(let slot):
            return [ToolbarKeyChip.label(for: slot, manager: manager), note(for: slot) ?? "",
                    slot.customID.flatMap { manager.customKey(for: $0)?.iconName } ?? "",
                    manager.glyphColorHex(for: slot) ?? "", overflowing.contains(slot) ? "overflows" : ""]
                .joined(separator: "\u{1f}")
        case .placeholder: return ""
        case .summary(let section): return summary(of: section)
        }
    }

    /// The small print beside a key's name.
    private func note(for slot: KeySlot) -> String? {
        if marksHostBarKeys, slot == .builtIn(.dismiss) {
            // The bar has a keyboard button of its own.
            return String(localized: "Not shown in the remote screen's toolbar")
        }
        return slot.customID.flatMap { manager.customKey(for: $0)?.sequenceSummary }
    }

    private func summary(of section: Section) -> String {
        keys(in: section).map { slot in
            if let keyID = slot.keyID, keyID.category == .symbol { return keyID.keyValue }
            return ToolbarKeyChip.label(for: slot, manager: manager)
        }.joined(separator: "  ")
    }

    // MARK: Key colors

    /// Quick picks for a key's own color; Other opens the full picker.
    private static let presetKeyColors: [(name: String, hex: String)] = [
        (String(localized: "Red"), "FF3B30"),
        (String(localized: "Orange"), "FF9500"),
        (String(localized: "Yellow"), "FFCC00"),
        (String(localized: "Green"), "34C759"),
        (String(localized: "Teal"), "30B0C7"),
        (String(localized: "Blue"), "0A84FF"),
        (String(localized: "Purple"), "AF52DE"),
        (String(localized: "Pink"), "FF2D55"),
    ]

    private func colorMenu(for slot: KeySlot) -> UIMenu {
        let current = manager.ownGlyphColorHex(for: slot)
        func swatch(_ color: UIColor?) -> UIImage? {
            color.flatMap { UIImage(systemName: "circle.fill")?.withTintColor($0, renderingMode: .alwaysOriginal) }
        }
        var items: [UIMenuElement] = Self.presetKeyColors.map { preset in
            UIAction(title: preset.name, image: swatch(UIColor(hex: preset.hex)),
                     state: current == preset.hex ? .on : .off) { [weak self] _ in
                self?.setColor(preset.hex, for: slot)
            }
        }
        let isOther = current.map { hex in !Self.presetKeyColors.contains { $0.hex == hex } } ?? false
        items.append(UIAction(title: String(localized: "Other…"),
                              image: isOther ? swatch(current.flatMap { UIColor(hex: $0) }) : UIImage(systemName: "eyedropper"),
                              state: isOther ? .on : .off) { [weak self] _ in
            self?.presentColorPicker(for: slot)
        })
        if current != nil {
            items.append(UIAction(title: String(localized: "Use Toolbar Color"),
                                  image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.setColor(nil, for: slot)
            })
        }
        return UIMenu(title: String(localized: "Key Color"), image: UIImage(systemName: "paintpalette"), children: items)
    }

    private func setColor(_ hex: String?, for slot: KeySlot) {
        actions.record(String(localized: "Change Key Color")) { manager.setOwnGlyphColor(hex, for: slot) }
    }

    private func presentColorPicker(for slot: KeySlot) {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = manager.glyphColor(for: slot) ?? tintColor
        picker.delegate = self
        colorPickerSlot = slot
        present(picker, animated: true)
    }

    // MARK: Theme

    func applyTheme() {
        guard isViewLoaded else { return }
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.tintColor = tintColor
    }

    private var rowBackgroundColor: UIColor {
        if let themeColors { return UIColor(themeColors.rowBackground) }
        return .secondarySystemGroupedBackground
    }

    private var chipBackgroundColor: UIColor {
        if let themeColors { return UIColor(themeColors.rowBackground) }
        return .tertiarySystemGroupedBackground
    }

    private var tintColor: UIColor {
        if let accent = themeColors?.accentColor { return UIColor(accent) }
        return view.window?.tintColor ?? .tintColor
    }

    // MARK: Height reporting

    private func reportContentHeight() {
        collectionView.layoutIfNeeded()
        let height = collectionView.collectionViewLayout.collectionViewContentSize.height
        guard height > 0, abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange?(height)
    }

    /// A touch on a row's grip is a reorder, not a hold for the menu or a lift.
    private func isOverGrip(_ point: CGPoint, at indexPath: IndexPath) -> Bool {
        guard !collectionView.isEditing, let cell = collectionView.cellForItem(at: indexPath) else { return false }
        let x = collectionView.convert(point, to: cell).x
        let grip: CGFloat = 56
        return cell.effectiveUserInterfaceLayoutDirection == .rightToLeft ? x < grip : x > cell.bounds.width - grip
    }
}

// MARK: - Delegate / drag / drop

extension ToolbarLayoutEditorController: UICollectionViewDelegate {
    /// While selecting, keys. Otherwise the rows a tap does something for.
    private func isTappable(_ indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .key(let slot): return collectionView.isEditing || slot.customID != nil
        case .summary: return !collectionView.isEditing
        case .placeholder, nil: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        isTappable(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        isTappable(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !collectionView.isEditing else { reportSelection(); return }
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .summary(let section): setCollapsed(false, section)
        case .key(.custom(let uuid)): actions.editCustomKey(uuid)
        default: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { reportSelection() }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing, !isOverGrip(point, at: indexPath),
              let slot = dataSource.itemIdentifier(for: indexPath)?.slot else { return nil }
        let source = section(at: indexPath.section)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            func add(_ title: String, _ image: String, attributes: UIMenuElement.Attributes = [],
                     _ handler: @escaping (ToolbarLayoutEditorController) -> Void) {
                actions.append(UIAction(title: title, image: UIImage(systemName: image), attributes: attributes) {
                    [weak self] _ in
                    if let self { handler(self) }
                })
            }
            if let uuid = slot.customID {
                add(String(localized: "Edit Key"), "pencil") { $0.actions.editCustomKey(uuid) }
            }
            // Within its own row first, then to another row.
            let row = self.keys(in: source)
            if row.first != slot {
                add(String(localized: "Move to Start of Row"), "arrow.up.to.line") {
                    _ = $0.place(slot, in: source, before: row.first)
                }
            }
            if row.last != slot {
                add(String(localized: "Move to End of Row"), "arrow.down.to.line") {
                    _ = $0.place(slot, in: source, before: nil)
                }
            }
            let drawerRows = self.layout.drawerRows.count
            for target in self.manager.sections(in: self.context) where target != source {
                // A key joins the end of the main row and the front of a drawer.
                let anchor: KeySlot? = if case .drawer = target { self.keys(in: target).first } else { nil }
                add(String(localized: "Move to \(target.title(drawerRows: drawerRows))"), target.symbolName) {
                    _ = $0.place(slot, in: target, before: anchor)
                }
            }
            actions.append(self.colorMenu(for: slot))
            if slot.keyID != nil {
                add(String(localized: "Hide"), "eye.slash", attributes: .destructive) { $0.remove(slot) }
            } else {
                add(String(localized: "Remove from Toolbar"), "minus.circle", attributes: .destructive) {
                    $0.remove(slot)
                }
            }
            return UIMenu(children: actions)
        }
    }
}

extension ToolbarLayoutEditorController: UIColorPickerViewControllerDelegate {
    // A drag in the picker settles before the toolbars rebuild.
    func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously, let slot = colorPickerSlot else { return }
        setColor(color.hexString, for: slot)
    }

    func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
        colorPickerSlot = nil
    }
}

extension ToolbarLayoutEditorController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.slot != nil,
              !isOverGrip(session.location(in: collectionView), at: indexPath) else { return [] }
        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = item
        return [dragItem]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragSessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        true
    }
}

extension ToolbarLayoutEditorController: UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        canHandle session: UIDropSession
    ) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard coordinator.proposal.operation == .move,
              let dropped = coordinator.items.first,
              let moved = dropped.dragItem.localObject as? Item, let slot = moved.slot else { return }
        // A drag inside the list arrives as a reorder, through the data
        // source. This is what is left: a drop UIKit hands over itself. One
        // that lands on no row leaves the key where it was.
        let snapshot = dataSource.snapshot()
        guard let destination = coordinator.destinationIndexPath,
              snapshot.sectionIdentifiers.indices.contains(destination.section) else { return }
        let section = snapshot.sectionIdentifiers[destination.section]
        // The proposed index is measured with the dragged row still in place,
        // so the row now at it is the one to land ahead of.
        let anchor = snapshot.itemIdentifiers(inSection: section).dropFirst(destination.item)
            .lazy.filter { $0 != moved }.compactMap(\.slot).first
        guard place(slot, in: section, before: anchor) else { return }
        applySnapshot(animated: true)
        // Into a collapsed row there is no row to land on.
        if let indexPath = dataSource.indexPath(for: moved) {
            coordinator.drop(dropped.dragItem, toItemAt: indexPath)
        }
    }
}
