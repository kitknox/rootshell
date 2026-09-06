//
//  TabExposeTrayView.swift
//  rootshell
//
//  One scope's page of the tab exposé: the scope header plus a grid of live
//  tab previews, scrolling vertically when the grid doesn't fit. The exposé
//  view holds one for the active scope and, while a group swipe or ⌘⌥[ ] is
//  in flight, a second for the neighbor scope sliding in beside it.
//

import UIKit

@MainActor
final class TabExposeTrayView: UIScrollView {
    private(set) var tabIDs: [UUID] = []
    private(set) var cells: [TabExposeCellView] = []
    private(set) var layoutResult = TabExposeLayout.Result.empty

    private let header = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private var appearance = TabExposeView.Appearance()
    /// Set while this page shows a multiplexer session's tabs.
    private weak var muxFeed: MultiplexerExposeFeed?

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        // UIKit 26 applies an automatic glass "scroll edge effect" to scroll
        // views it considers under a bar; on Catalyst the window titlebar
        // qualifies and the effect blurs/tints the whole tray. The tray is a
        // live preview grid, never bar-adjacent content: opt out entirely.
        if #available(iOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
            leftEdgeEffect.isHidden = true
            rightEdgeEffect.isHidden = true
        }

        headerIcon.contentMode = .scaleAspectFit
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(headerIcon)
        header.addSubview(headerLabel)
        header.isUserInteractionEnabled = false
        header.accessibilityTraits = .header
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Cells

    /// Rebuild for `tabIDs`, reusing cells by tab id; stale cells are removed.
    /// Returns the cells created by this rebuild.
    @discardableResult
    func rebuildCells(
        tabIDs ids: [UUID],
        scopeTitle: String?,
        scoped: Bool,
        tabsModel: TabsModel,
        muxFeed: MultiplexerExposeFeed? = nil,
        selectedID: UUID?,
        highlightedID: UUID?,
        appearance: TabExposeView.Appearance,
        onSelect: ((UUID) -> Void)? = nil
    ) -> [TabExposeCellView] {
        self.appearance = appearance
        self.muxFeed = muxFeed
        var byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.tabID, $0) })
        var ordered: [TabExposeCellView] = []
        var entering: [TabExposeCellView] = []
        for (index, id) in ids.enumerated() {
            let tab = tabsModel.tab(withID: id)
            let muxTab = tab == nil ? muxFeed?.tab(uuid: id) : nil
            guard tab != nil || muxTab != nil else { continue }
            let cell: TabExposeCellView
            if let existing = byID.removeValue(forKey: id) {
                cell = existing
            } else {
                cell = TabExposeCellView(tabID: id)
                addSubview(cell)
                entering.append(cell)
            }
            if let tab {
                cell.showMirror(of: tab)
            } else if let muxTab {
                cell.showMultiplexerTab(muxTab, feed: muxFeed)
            }
            cell.isCurrent = id == selectedID
            cell.isHighlighted = id == highlightedID
            cell.onActivate = onSelect.map { select in { select(id) } }
            // Captions only re-host when the cell's position changes (hover
            // highlight churn must not rebuild SwiftUI per cell). A
            // multiplexer caption also follows the tab's title.
            let captionKey = muxTab.map { "\($0.title)|\($0.badge ?? "")" }
            if cell.captionIndex != index || cell.captionKey != captionKey {
                cell.captionIndex = index
                cell.captionKey = captionKey
                if let tab {
                    cell.setCaption(appearance.showsCaptions ? appearance.captionProvider?(tab, index) : nil)
                } else if let muxTab {
                    cell.setCaption(appearance.showsCaptions ? appearance.muxCaptionProvider?(muxTab, index) : nil)
                }
            }
            ordered.append(cell)
        }
        for (_, stale) in byID {
            stale.prepareForRemoval()
            stale.removeFromSuperview()
        }
        cells = ordered
        tabIDs = ids

        header.isHidden = !scoped
        if scoped {
            var parts = [scopeTitle, "\(ids.count)"].compactMap { $0 }
            if let muxFeed {
                switch muxFeed.state {
                case .loading:
                    parts = [scopeTitle, String(localized: "Loading…", comment: "Exposé header while the multiplexer session is being read")].compactMap { $0 }
                case .failed:
                    parts.append(String(localized: "Unavailable", comment: "Exposé header when the multiplexer session stopped answering"))
                default:
                    break
                }
            }
            headerLabel.text = parts.joined(separator: " · ")
            header.isAccessibilityElement = true
            header.accessibilityLabel = headerLabel.text
            let symbol = muxFeed != nil ? "rectangle.split.2x1" : (tabsModel.isProjectGroupingActive ? "folder" : "square.grid.2x2")
            headerIcon.image = UIImage(systemName: symbol)
        } else {
            header.isAccessibilityElement = false
        }
        applyAppearance(appearance)
        accessibilityElements = (scoped ? [header] : []) + cells
        return entering
    }

    func removeAllCells() {
        for cell in cells {
            cell.prepareForRemoval()
            cell.removeFromSuperview()
        }
        cells.removeAll()
        tabIDs.removeAll()
    }

    func discard() {
        removeAllCells()
        removeFromSuperview()
    }

    func applyAppearance(_ appearance: TabExposeView.Appearance) {
        self.appearance = appearance
        headerLabel.textColor = appearance.textColor.withAlphaComponent(0.85)
        headerIcon.tintColor = appearance.textColor.withAlphaComponent(0.7)
        for cell in cells {
            cell.previewBackgroundColor = appearance.backgroundColor.withAlphaComponent(appearance.backgroundOpacity)
            cell.accentColor = appearance.accentColor
            cell.currentRingColor = appearance.textColor.withAlphaComponent(0.3)
        }
    }

    // MARK: - Layout

    /// Lay the header and grid out for a tray of `size` (the hero area).
    func layoutGrid(size: CGSize, aspect: CGFloat, metrics: TabExposeLayout.Metrics, cornerRadius: CGFloat, zoom: CGFloat = 1) {
        layoutResult = TabExposeLayout.grid(
            in: CGRect(origin: .zero, size: size),
            count: cells.count,
            aspect: aspect,
            metrics: metrics,
            zoom: zoom
        )
        contentSize = CGSize(width: size.width, height: max(layoutResult.contentHeight, size.height))
        isScrollEnabled = !layoutResult.fits

        header.frame = layoutResult.headerFrame
        let iconSide = max(0, min(16, header.bounds.height))
        headerIcon.frame = CGRect(x: 0, y: (header.bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        headerLabel.frame = CGRect(x: iconSide + 6, y: 0, width: header.bounds.width - iconSide - 6, height: header.bounds.height)

        for (index, cell) in cells.enumerated() where index < layoutResult.frames.count {
            // bounds/center, not frame: highlighted cells carry a scale transform.
            let frame = layoutResult.frames[index]
            cell.bounds = CGRect(origin: .zero, size: frame.size)
            cell.center = CGPoint(x: frame.midX, y: frame.midY)
            cell.layoutContent(previewSize: layoutResult.cellSize, cornerRadius: cornerRadius)
        }
    }

    func setChrome(captionAlpha: CGFloat, ringAlpha: CGFloat) {
        header.alpha = captionAlpha
        for cell in cells {
            cell.captionAlpha = captionAlpha
            cell.ringAlpha = ringAlpha
        }
    }

    // MARK: - Per frame

    /// Refresh the previews of on-screen cells only, and report which
    /// multiplexer panes those cells show. Empty for a page of app tabs, so
    /// the caller can tell the feed that none of its panes are on screen.
    @discardableResult
    func syncVisibleMirrors() -> Set<String> {
        let visible = bounds
        var panes: Set<String> = []
        for cell in cells where cell.frame.intersects(visible) {
            cell.syncPreview()
            panes.formUnion(cell.muxPreview.paneIDs)
        }
        return panes
    }

    // MARK: - Hit testing / scrolling

    func cell(at pointInTray: CGPoint) -> TabExposeCellView? {
        cells.first { $0.frame.contains(pointInTray) }
    }

    func scrollCellIntoView(id: UUID?, animated: Bool) {
        guard isScrollEnabled, let id,
              let cell = cells.first(where: { $0.tabID == id }) else { return }
        scrollRectToVisible(cell.frame.insetBy(dx: 0, dy: -12), animated: animated)
    }
}
