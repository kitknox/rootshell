//
//  ToolbarLayoutEditor.swift
//  rootshell
//
//  Native UIKit editor for the keyboard toolbar layout. Hosts an inset-grouped
//  UICollectionView with one section per row (Main Row + each Drawer row) that
//  supports dragging keys *across* section boundaries — something SwiftUI's
//  List `.onMove` cannot do.
//
//  Controls (1:1 with the previous SwiftUI list, plus cross-section drag):
//    - Long-press lift drag (no edit mode) via drag-and-drop. Coordinates with
//      the context menu the same way Files/Photos do (hold = menu, move = drag).
//    - Edit-mode reorder grip (interactive movement) when EditButton is active.
//    - Swipe-to-hide (built-in) / remove-from-toolbar (custom).
//    - Context menu: Move to Drawer N / Move to Main Row, Key Color, Hide/Remove.
//  Both drag paths cross sections and persist through KeyboardToolbarManager.
//
//  Note: the diffable data source is keyed by stable String ids (sections and
//  items) rather than KeySlot directly. Under the project's default MainActor
//  isolation, KeySlot's (associated-value) Hashable conformance is
//  main-actor-isolated and cannot satisfy the data source's Sendable
//  identifier requirement. String is a stdlib (nonisolated) Hashable &
//  Sendable, so it sidesteps that entirely. Sections are "pinned-leading",
//  "main", "pinned-trailing" and "drawer-<index>"; a pinned section exists only
//  while its group is on.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI bridge

struct ToolbarLayoutEditor: UIViewControllerRepresentable {
    var manager: KeyboardToolbarManager
    /// Whose layout is being edited.
    var toolbar: ToolbarContext
    var themeColors: SheetThemeColors?
    var capacity: Int
    /// The toolbar being viewed sits in a remote screen's bar, which leaves some keys out.
    var marksHostBarKeys = false
    @Binding var contentHeight: CGFloat
    @Environment(\.editMode) private var editMode

    func makeUIViewController(context: Context) -> ToolbarLayoutEditorController {
        let controller = ToolbarLayoutEditorController(manager: manager, context: toolbar)
        controller.capacity = capacity
        controller.onContentHeightChange = { height in
            // Guard against a layout feedback loop: only push real changes.
            if abs(contentHeight - height) > 0.5 {
                contentHeight = height
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: ToolbarLayoutEditorController, context: Context) {
        // Theme changes are handled by the controller's themeColors didSet.
        controller.themeColors = themeColors
        controller.capacity = capacity
        controller.marksHostBarKeys = marksHostBarKeys
        controller.setEditing(editMode?.wrappedValue.isEditing ?? false)
        controller.applySnapshot(animated: true)
    }
}

// MARK: - Controller

@MainActor
final class ToolbarLayoutEditorController: UIViewController {
    private let manager: KeyboardToolbarManager
    private let context: ToolbarContext
    private var layout: ToolbarLayoutConfig { manager.layout(for: context) }

    var themeColors: SheetThemeColors? {
        didSet {
            guard isViewLoaded, themeColors != oldValue else { return }
            applyTheme()
            reconfigureAllItems()
        }
    }
    /// Main-row capacity for the "X / Y" badge, computed by the SwiftUI host from
    /// the settings list width so the number matches the previous implementation.
    var capacity: Int = 1 {
        didSet {
            guard isViewLoaded, capacity != oldValue else { return }
            reconfigureSupplementaries()
        }
    }
    var marksHostBarKeys = false {
        didSet {
            guard isViewLoaded, marksHostBarKeys != oldValue else { return }
            reconfigureAllItems()
        }
    }
    var onContentHeightChange: ((CGFloat) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var slotsByID: [String: KeySlot] = [:]
    private var lastReportedHeight: CGFloat = 0
    /// The key the open color picker colors.
    private var colorPickerSlot: KeySlot?
    /// The color each item's badge was drawn in ("" for none), so only badges
    /// whose color changed are redrawn.
    private var badgeColors: [String: String] = [:]

    // MARK: Section identifiers

    private static let leadingSectionID = "pinned-leading"
    private static let mainSectionID = "main"
    private static let trailingSectionID = "pinned-trailing"

    private static func drawerSectionID(_ index: Int) -> String {
        "drawer-\(index)"
    }

    private var drawerSectionIDs: [String] {
        layout.drawerRows.indices.map { Self.drawerSectionID($0) }
    }

    private func drawerIndex(of sectionID: String) -> Int? {
        guard sectionID.hasPrefix("drawer-") else { return nil }
        return Int(sectionID.dropFirst("drawer-".count))
    }

    private func sectionID(at index: Int) -> String {
        let ids = dataSource.snapshot().sectionIdentifiers
        guard ids.indices.contains(index) else { return ids.last ?? Self.mainSectionID }
        return ids[index]
    }

    init(manager: KeyboardToolbarManager, context: ToolbarContext) {
        self.manager = manager
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshChangedBadges),
                                               name: KeyboardToolbarManager.layoutDidChangeNotification, object: nil)
        applyTheme()
        applySnapshot(animated: false)
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
        // so zero the list's own leading/trailing insets — otherwise insetGrouped
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
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let slot = self.slotsByID[id] else { return }
            cell.contentConfiguration = self.contentConfiguration(for: slot)
            self.badgeColors[id] = self.manager.glyphColorHex(for: slot) ?? ""
            var background = UIBackgroundConfiguration.listCell()
            background.backgroundColor = self.rowBackgroundColor
            cell.backgroundConfiguration = background
            // Accessories only appear in edit mode; long-press drag and swipe
            // handle everything else without them. The delete control routes to
            // the same hide/remove path as the swipe action (1:1 with the old
            // SwiftUI .onDelete behaviour in Edit mode).
            cell.accessories = [
                .delete(displayed: .whenEditing, actionHandler: { [weak self] in
                    self?.removeSlot(slot)
                }),
                .reorder(displayed: .whenEditing),
            ]
        }

        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureHeader(view, section: indexPath.section)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, section: indexPath.section)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            } else {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }

        // Edit-mode reorder grip (interactive movement).
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.persist(transaction.finalSnapshot)
        }
    }

    // MARK: Snapshot

    func applySnapshot(animated: Bool) {
        slotsByID.removeAll(keepingCapacity: true)
        let layout = self.layout

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        if let leading = layout.pinnedLeading {
            snapshot.appendSections([Self.leadingSectionID])
            snapshot.appendItems(validSlots(leading).map { register($0) }, toSection: Self.leadingSectionID)
        }
        snapshot.appendSections([Self.mainSectionID])
        snapshot.appendItems(validSlots(layout.mainRow).map { register($0) }, toSection: Self.mainSectionID)
        if let trailing = layout.pinnedTrailing {
            snapshot.appendSections([Self.trailingSectionID])
            snapshot.appendItems(validSlots(trailing).map { register($0) }, toSection: Self.trailingSectionID)
        }
        snapshot.appendSections(drawerSectionIDs)
        for (index, row) in layout.drawerRows.enumerated() {
            let rowIDs = validSlots(row).map { register($0) }
            snapshot.appendItems(rowIDs, toSection: Self.drawerSectionID(index))
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
        // Headers/footers are not part of the diff; refresh their text.
        reconfigureSupplementaries()
        reportContentHeight()
    }

    /// Forces every visible cell to re-run its registration so theme changes
    /// (which the diff doesn't see, since the items are unchanged) take effect.
    private func reconfigureAllItems() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        reconfigureSupplementaries()
    }

    /// Key colors change from other screens and from sync, which leave the
    /// item identifiers, and so the snapshot diff, unchanged.
    @objc private func refreshChangedBadges() {
        var snapshot = dataSource.snapshot()
        let changed = snapshot.itemIdentifiers.filter { id in
            guard let slot = slotsByID[id], let drawn = badgeColors[id] else { return false }
            return (manager.glyphColorHex(for: slot) ?? "") != drawn
        }
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func register(_ slot: KeySlot) -> String {
        let id = slotID(slot)
        slotsByID[id] = slot
        return id
    }

    private func slotID(_ slot: KeySlot) -> String {
        switch slot {
        case .builtIn(let keyID): return "builtin.\(keyID.rawValue)"
        case .custom(let uuid): return "custom.\(uuid.uuidString)"
        }
    }

    private func slots(from ids: [String]) -> [KeySlot] {
        ids.compactMap { slotsByID[$0] }
    }

    private func persist(_ snapshot: NSDiffableDataSourceSnapshot<String, String>) {
        let drawerRows = snapshot.sectionIdentifiers
            .filter { drawerIndex(of: $0) != nil }
            .map { slots(from: snapshot.itemIdentifiers(inSection: $0)) }
        func pinned(_ sectionID: String) -> [KeySlot]? {
            snapshot.sectionIdentifiers.contains(sectionID)
                ? slots(from: snapshot.itemIdentifiers(inSection: sectionID)) : nil
        }
        manager.setLayout(
            pinnedLeading: pinned(Self.leadingSectionID),
            mainRow: slots(from: snapshot.itemIdentifiers(inSection: Self.mainSectionID)),
            pinnedTrailing: pinned(Self.trailingSectionID),
            drawerRows: drawerRows,
            in: context
        )
    }

    private func validSlots(_ slots: [KeySlot]) -> [KeySlot] {
        let hiddenKeys = layout.hiddenKeys
        return slots.filter { slot in
            switch slot {
            case .builtIn(let keyID): return !hiddenKeys.contains(keyID)
            case .custom(let uuid): return manager.customKey(for: uuid) != nil
            }
        }
    }

    private func toolbarSection(for sectionID: String) -> KeyboardToolbarManager.ToolbarSection {
        switch sectionID {
        case Self.leadingSectionID: return .pinnedLeading
        case Self.trailingSectionID: return .pinnedTrailing
        default: return drawerIndex(of: sectionID).map(KeyboardToolbarManager.ToolbarSection.drawer) ?? .mainRow
        }
    }

    /// Keys on the main row, pinned groups included.
    private var mainRowKeyCount: Int {
        let layout = self.layout
        return validSlots((layout.pinnedLeading ?? []) + layout.mainRow + (layout.pinnedTrailing ?? [])).count
    }

    private func keyCount(in section: KeyboardToolbarManager.ToolbarSection) -> Int {
        let layout = self.layout
        switch section {
        case .pinnedLeading: return validSlots(layout.pinnedLeading ?? []).count
        case .pinnedTrailing: return validSlots(layout.pinnedTrailing ?? []).count
        case .mainRow: return validSlots(layout.mainRow).count
        case .drawer(let index):
            return layout.drawerRows.indices.contains(index) ? validSlots(layout.drawerRows[index]).count : 0
        }
    }

    // MARK: Editing

    func setEditing(_ editing: Bool) {
        guard collectionView.isEditing != editing else { return }
        collectionView.isEditing = editing
        // In edit mode the reorder grip handles moves; disable the lift drag so
        // the two mechanisms don't compete for the long-press gesture.
        collectionView.dragInteractionEnabled = !editing
    }

    // MARK: Swipe actions (1:1 with the old .onDelete behaviour)

    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), slotsByID[id] != nil else { return nil }
        // Matches the previous SwiftUI `.onDelete` swipe, which showed "Delete".
        let action = UIContextualAction(style: .destructive, title: String(localized: "Delete")) {
            [weak self] _, _, completion in
            guard let self, let slot = self.slotsByID[id] else { completion(false); return }
            self.removeSlot(slot)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func removeSlot(_ slot: KeySlot) {
        switch slot {
        case .builtIn(let keyID): manager.hideKey(keyID, in: context)
        case .custom(let uuid): manager.removeCustomKeyFromLayout(id: uuid, in: context)
        }
        applySnapshot(animated: true)
    }

    // MARK: Supplementary configuration

    /// Header title for a drawer section: plain "Drawer" with one row (matching
    /// the original UI), numbered "Drawer N" once more rows exist.
    private func drawerSectionTitle(_ index: Int) -> String {
        layout.drawerRows.count == 1
            ? String(localized: "Drawer")
            : String(localized: "Drawer \(index + 1)")
    }

    private func sectionTitle(_ section: KeyboardToolbarManager.ToolbarSection) -> String {
        switch section {
        case .pinnedLeading: return String(localized: "Pinned Left")
        case .mainRow: return String(localized: "Main Row")
        case .pinnedTrailing: return String(localized: "Pinned Right")
        case .drawer(let index): return drawerSectionTitle(index)
        }
    }

    private func configureHeader(_ view: UICollectionViewListCell, section index: Int) {
        var content = view.defaultContentConfiguration()
        let countLabel = UILabel()
        countLabel.textAlignment = .right

        let section = toolbarSection(for: sectionID(at: index))
        content.text = sectionTitle(section)
        if section == .mainRow {
            // The row's capacity is shared with the pinned groups at its ends.
            let mainCount = mainRowKeyCount
            countLabel.text = "\(mainCount) / \(capacity)"
            // A scrolling row holds any number of keys.
            countLabel.textColor = mainCount > capacity && !layout.mainRowScrolls ? .systemOrange : .systemGreen
            countLabel.font = .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .medium
            )
        } else {
            countLabel.text = String(localized: "\(keyCount(in: section)) keys")
            countLabel.textColor = .secondaryLabel
            countLabel.font = .preferredFont(forTextStyle: .footnote)
        }

        view.contentConfiguration = content
        view.backgroundConfiguration = .clear()
        view.accessories = [
            .customView(configuration: .init(customView: countLabel, placement: .trailing(displayed: .always)))
        ]
    }

    private func configureFooter(_ view: UICollectionViewListCell, section index: Int) {
        var content = view.defaultContentConfiguration()
        let section = toolbarSection(for: sectionID(at: index))
        switch section {
        case .drawer:
            if keyCount(in: section) == 0 {
                content.text = String(localized: "Drag keys here to move them into the drawer.")
            } else {
                content.text = String(localized: "Scrolls horizontally on the keyboard.")
            }
        case .pinnedLeading:
            content.text = keyCount(in: section) == 0
                ? String(localized: "Drag keys here to keep them at the left end of the main row.")
                : String(localized: "Stays at the left end of the main row when it is full.")
        case .pinnedTrailing:
            content.text = keyCount(in: section) == 0
                ? String(localized: "Drag keys here to keep them at the right end of the main row.")
                : String(localized: "Stays at the right end of the main row when it is full.")
        case .mainRow:
            let overflow = max(0, mainRowKeyCount - capacity)
            if overflow > 0, layout.mainRowScrolls {
                content.text = String(localized: "More keys than fit at once. The row scrolls to reach the rest.")
            } else if overflow > 0 {
                content.text = String(localized: "\(overflow) key\(overflow == 1 ? "" : "s") will overflow to the drawer.")
                content.textProperties.color = .systemOrange
            } else {
                content.text = String(localized: "These keys fill the main toolbar row. Drag keys between Main Row and Drawer.")
            }
        }
        view.contentConfiguration = content
        view.backgroundConfiguration = .clear()
    }

    private func reconfigureSupplementaries() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            if let cell = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath) as? UICollectionViewListCell {
                configureHeader(cell, section: indexPath.section)
            }
        }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionFooter) {
            if let cell = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: indexPath) as? UICollectionViewListCell {
                configureFooter(cell, section: indexPath.section)
            }
        }
    }

    // MARK: Cell content

    private func contentConfiguration(for slot: KeySlot) -> UIContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = label(for: slot)
        content.image = badgeImage(for: slot)
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        if marksHostBarKeys, slot == .builtIn(.dismiss) {
            // The bar has a keyboard button of its own.
            content.secondaryText = String(localized: "Not shown in the remote screen's toolbar")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        }
        if case .custom(let uuid) = slot, let key = manager.customKey(for: uuid) {
            content.secondaryText = key.sequenceSummary
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        }
        return content
    }

    private func label(for slot: KeySlot) -> String {
        switch slot {
        case .builtIn(let keyID):
            return keyID.displayName
        case .custom(let uuid):
            return manager.customKey(for: uuid)?.label ?? String(localized: "Unknown")
        }
    }

    /// The badge takes the key's toolbar color, so colors read in the list too.
    private func badgeImage(for slot: KeySlot) -> UIImage? {
        let foreground = manager.glyphColor(for: slot) ?? tintColor
        switch slot {
        case .builtIn(let keyID):
            return chipImage(symbolName: keyID.iconName, text: keyID.iconName == nil ? keyID.keyValue : nil,
                             foreground: foreground)
        case .custom(let uuid):
            guard let key = manager.customKey(for: uuid) else { return nil }
            return chipImage(symbolName: key.iconName, text: key.iconName == nil ? String(key.label.prefix(2)) : nil,
                             foreground: foreground)
        }
    }

    /// Renders a 28pt rounded chip containing either a small SF Symbol or short
    /// monospaced text, tinted, on the subtle chip background — matching the
    /// SwiftUI `keyBadge` look so every key reads as a compact badge.
    private func chipImage(symbolName: String?, text: String?, foreground: UIColor) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)
        let chipBackground = chipBackgroundColor
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            chipBackground.setFill()
            path.fill()

            if let symbolName,
               let symbol = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
               )?.withTintColor(foreground, renderingMode: .alwaysOriginal) {
                let imageSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - imageSize.width) / 2,
                    y: (size.height - imageSize.height) / 2
                )
                symbol.draw(at: origin)
            } else if let text {
                let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: foreground,
                ]
                let attributed = NSAttributedString(string: text, attributes: attributes)
                let textSize = attributed.size()
                let textRect = CGRect(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                attributed.draw(in: textRect)
            }
        }.withRenderingMode(.alwaysOriginal)
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
                self?.manager.setOwnGlyphColor(preset.hex, for: slot)
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
                self?.manager.setOwnGlyphColor(nil, for: slot)
            })
        }
        return UIMenu(title: String(localized: "Key Color"), image: UIImage(systemName: "paintpalette"), children: items)
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
}

// MARK: - Delegate / drag / drop

extension ToolbarLayoutEditorController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let slot = slotsByID[id] else { return nil }
        let source = toolbarSection(for: sectionID(at: indexPath.section))
        let position = indexPath.item
        let rowCount = dataSource.snapshot().numberOfItems(inSection: sectionID(at: indexPath.section))
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            let layout = self.layout
            func reposition(toStart: Bool, title: String, image: String) {
                actions.append(UIAction(title: title, image: UIImage(systemName: image)) { [weak self] _ in
                    guard let self else { return }
                    self.manager.moveKey(slot, toStart: toStart, in: self.context)
                    self.applySnapshot(animated: true)
                })
            }
            // Within its own row first, then to another row.
            if position > 0 {
                reposition(toStart: true, title: String(localized: "Move to Top"), image: "arrow.up.to.line")
            }
            if position < rowCount - 1 {
                reposition(toStart: false, title: String(localized: "Move to Bottom"), image: "arrow.down.to.line")
            }
            func move(to target: KeyboardToolbarManager.ToolbarSection, title: String, image: String) {
                guard target != source else { return }
                actions.append(UIAction(title: title, image: UIImage(systemName: image)) { [weak self] _ in
                    guard let self else { return }
                    self.manager.moveKey(slot, to: target, in: self.context)
                    self.applySnapshot(animated: true)
                })
            }

            if layout.pinnedLeading != nil {
                move(to: .pinnedLeading, title: String(localized: "Move to Pinned Left"), image: "pin")
            }
            move(to: .mainRow, title: String(localized: "Move to Main Row"), image: "tray.and.arrow.up")
            if layout.pinnedTrailing != nil {
                move(to: .pinnedTrailing, title: String(localized: "Move to Pinned Right"), image: "pin")
            }
            // One move target per other drawer row; plain "Move to Drawer" when
            // there's a single row (matching the original wording).
            for targetIndex in layout.drawerRows.indices {
                let title = layout.drawerRows.count == 1
                    ? String(localized: "Move to Drawer")
                    : String(localized: "Move to Drawer \(targetIndex + 1)")
                move(to: .drawer(targetIndex), title: title, image: "tray.and.arrow.down")
            }

            actions.append(self.colorMenu(for: slot))

            // Matches the old context menu: Hide is only offered for built-in keys.
            if slot.keyID != nil {
                actions.append(UIAction(
                    title: String(localized: "Hide"),
                    image: UIImage(systemName: "eye.slash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.removeSlot(slot)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

extension ToolbarLayoutEditorController: UIColorPickerViewControllerDelegate {
    // A drag in the picker settles before the toolbars rebuild.
    func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously, let slot = colorPickerSlot else { return }
        manager.setOwnGlyphColor(color.hexString, for: slot)
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
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        return [item]
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
              let item = coordinator.items.first,
              let id = item.dragItem.localObject as? String else { return }

        // Fallback: no destination proposed → append to the last drawer section.
        let sectionIDs = dataSource.snapshot().sectionIdentifiers
        let lastSectionID = sectionIDs.last ?? Self.mainSectionID
        let destinationIndexPath = coordinator.destinationIndexPath
            ?? IndexPath(item: dataSource.snapshot().numberOfItems(inSection: lastSectionID),
                         section: max(0, sectionIDs.count - 1))

        let destinationSection = sectionID(at: destinationIndexPath.section)

        var snapshot = dataSource.snapshot()
        // destinationIndexPath.item is measured against the pre-delete layout.
        // When moving an item *downward within the same section*, removing the
        // source shifts every later index down by one, so the target index in
        // the post-delete list is one less than the proposed index.
        let sourceSection = snapshot.sectionIdentifier(containingItem: id)
        let sourceIndex = sourceSection.flatMap {
            snapshot.itemIdentifiers(inSection: $0).firstIndex(of: id)
        }
        snapshot.deleteItems([id])

        var targetIndex = destinationIndexPath.item
        if sourceSection == destinationSection,
           let sourceIndex,
           sourceIndex < destinationIndexPath.item {
            targetIndex -= 1
        }

        let destinationItems = snapshot.itemIdentifiers(inSection: destinationSection)
        let finalItem = min(max(targetIndex, 0), destinationItems.count)
        if finalItem < destinationItems.count {
            snapshot.insertItems([id], beforeItem: destinationItems[finalItem])
        } else {
            snapshot.appendItems([id], toSection: destinationSection)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
        persist(snapshot)
        reconfigureSupplementaries()

        // Animate the drop onto the slot's final resting index (the proposed
        // destinationIndexPath was measured pre-delete and can be out of range).
        let finalIndexPath = IndexPath(item: finalItem, section: destinationIndexPath.section)
        coordinator.drop(item.dragItem, toItemAt: finalIndexPath)
    }
}
