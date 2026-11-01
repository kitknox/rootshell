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
    case httpCapture
    case aiAgent
    case clipboardManager
    case connections
    case themePicker
    case quickSettings
    case openInFolder
    case ipLookup
    case dictation

    static var availableCases: [Self] {
        allCases.filter { page in
            switch page {
            case .httpCapture:
                #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
                true
                #else
                false
                #endif
            case .aiAgent:
                #if !CHINA_BUILD
                true
                #else
                false
                #endif
            case .dictation:
                #if canImport(FluidAudio) && !CHINA_BUILD
                true
                #else
                false
                #endif
            default: true
            }
        }
    }

    var title: String {
        switch self {
        case .tabSwitcher: String(localized: "Tab Switcher", comment: "Sidebar page name")
        case .fileManager: String(localized: "File Manager", comment: "Sidebar page name")
        case .httpCapture: String(localized: "HTTP Capture", comment: "Sidebar page name")
        case .aiAgent: String(localized: "AI Agent")
        case .clipboardManager: String(localized: "Clipboard")
        case .connections: String(localized: "Connections")
        case .themePicker: String(localized: "Themes")
        case .quickSettings: String(localized: "Quick Settings")
        case .openInFolder: String(localized: "Open in Folder")
        case .ipLookup: String(localized: "IP Lookup")
        case .dictation: String(localized: "Dictation")
        }
    }

    var systemImage: String {
        switch self {
        case .tabSwitcher: "rectangle.stack"
        case .fileManager: "folder"
        case .httpCapture: "network.badge.shield.half.filled"
        case .aiAgent: "sparkles"
        case .clipboardManager: "clipboard"
        case .connections: "network"
        case .themePicker: "paintpalette"
        case .quickSettings: "slider.horizontal.3"
        case .openInFolder: "folder.badge.plus"
        case .ipLookup: "globe"
        case .dictation: "mic"
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

    static let stock = EdgeSidebarAssignment(sides: Dictionary(uniqueKeysWithValues:
        EdgeSidebarPage.allCases.map { ($0, $0 == .tabSwitcher ? .leading : .trailing) }
    ))

    func side(of page: EdgeSidebarPage) -> EdgeSidebarSide {
        sides[page] ?? Self.stock.sides[page] ?? .leading
    }

    /// Uses the tool catalog's stable order.
    func pages(on side: EdgeSidebarSide) -> [EdgeSidebarPage] {
        EdgeSidebarPage.availableCases.filter { self.side(of: $0) == side }
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
