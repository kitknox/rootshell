//
//  EdgeSidebarAssignment.swift
//  rootshell
//
//  Which sidebar page sits on which screen edge. A page is on exactly one
//  edge. A stored value that names a page twice, omits a page, or contains
//  an unknown token is the stock assignment.
//

import Foundation

nonisolated enum EdgeSidebarPage: String, CaseIterable, Sendable {
    case tabSwitcher
    case fileManager

    var title: String {
        switch self {
        case .tabSwitcher: String(localized: "Tabs", comment: "Sidebar page name")
        case .fileManager: String(localized: "Files", comment: "Sidebar page name")
        }
    }

    var systemImage: String {
        switch self {
        case .tabSwitcher: "rectangle.stack"
        case .fileManager: "folder"
        }
    }
}

nonisolated enum EdgeSidebarSide: String, CaseIterable, Sendable {
    case leading
    case trailing

    var title: String {
        switch self {
        case .leading: String(localized: "Left", comment: "Sidebar edge")
        case .trailing: String(localized: "Right", comment: "Sidebar edge")
        }
    }

    var opposite: EdgeSidebarSide {
        switch self {
        case .leading: .trailing
        case .trailing: .leading
        }
    }
}

nonisolated struct EdgeSidebarAssignment: Equatable, Sendable {
    var sides: [EdgeSidebarPage: EdgeSidebarSide]

    static let stock = EdgeSidebarAssignment(sides: [
        .tabSwitcher: .leading,
        .fileManager: .trailing,
    ])

    func side(of page: EdgeSidebarPage) -> EdgeSidebarSide {
        sides[page] ?? Self.stock.sides[page] ?? .leading
    }

    /// Stable order: tab switcher, then file manager.
    func pages(on side: EdgeSidebarSide) -> [EdgeSidebarPage] {
        EdgeSidebarPage.allCases.filter { self.side(of: $0) == side }
    }

    var sharesOneSide: Bool {
        side(of: .tabSwitcher) == side(of: .fileManager)
    }

    func setting(_ side: EdgeSidebarSide, for page: EdgeSidebarPage) -> EdgeSidebarAssignment {
        var copy = self
        copy.sides[page] = side
        return copy
    }

    /// `page:side` tokens. Invalid input returns `stock`.
    static func decode(_ tokens: [String]) -> EdgeSidebarAssignment {
        var seen: [EdgeSidebarPage: EdgeSidebarSide] = [:]
        for token in tokens {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let page = EdgeSidebarPage(rawValue: parts[0]),
                  let side = EdgeSidebarSide(rawValue: parts[1]),
                  seen[page] == nil else {
                return .stock
            }
            seen[page] = side
        }
        guard seen.count == EdgeSidebarPage.allCases.count else { return .stock }
        return EdgeSidebarAssignment(sides: seen)
    }

    var storedTokens: [String] {
        EdgeSidebarPage.allCases.map { "\($0.rawValue):\(side(of: $0).rawValue)" }
    }
}
