//
//  CaptureRequestList.swift
//  rootshell
//
//  Filterable list of captured requests and connections.
//

#if !CHINA_BUILD

import SwiftUI
import UIKit

struct CaptureRequestList: View {
    @Bindable var model: HTTPCaptureModel
    /// Narrow layouts push the detail with standard navigation links; the wide
    /// split selects a row instead.
    var pushesDetail = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider()
            if let document = model.document {
                CaptureRequestRows(model: model, document: document, pushesDetail: pushesDetail)
            } else {
                emptyState
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "Filter by URL, host, method, or status", comment: "HTTP capture search field"), text: $model.search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 32, minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear Filter", comment: "HTTP capture: clear the search text"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HTTPCaptureModel.Scope.allCases) { scope in
                    chip(scope.title, selected: model.scope == scope) { model.scope = scope }
                }
                Divider().frame(height: 16)
                Menu {
                    Button(String(localized: "Any Type", comment: "HTTP capture filter")) { model.kindFilter = nil }
                    ForEach([CaptureContentKind.json, .html, .javascript, .css, .image, .xml, .plist, .text, .form, .font, .media, .binary], id: \.self) { kind in
                        Button { model.kindFilter = kind } label: { Label(kind.title, systemImage: kind.systemImage) }
                    }
                } label: {
                    chipLabel(model.kindFilter?.title ?? String(localized: "Type", comment: "HTTP capture filter"), selected: model.kindFilter != nil)
                }
                Menu {
                    Button(String(localized: "Any Status", comment: "HTTP capture filter")) { model.statusFilter = nil }
                    ForEach(HTTPCaptureModel.StatusClass.allCases) { status in
                        Button(status.title) { model.statusFilter = status }
                    }
                } label: {
                    chipLabel(model.statusFilter?.title ?? String(localized: "Status", comment: "HTTP capture filter"), selected: model.statusFilter != nil)
                }
                if model.hasFilters {
                    Button { model.clearFilters() } label: {
                        Text(String(localized: "Clear", comment: "HTTP capture: clear filters"))
                            .frame(minHeight: PanelTouch.isTouchPlatform ? 40 : nil)
                            .contentShape(Rectangle())
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            // Touch chips take the row's height as their hit area instead.
            .padding(.vertical, PanelTouch.isTouchPlatform ? 0 : 6)
        }
        .modifier(ScrollEdgeEffectHiddenModifier())
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, selected: selected) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(minHeight: PanelTouch.isTouchPlatform ? 40 : nil)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Capture Yet", comment: "HTTP capture empty state title"), systemImage: "network")
        } description: {
            Text(CaptureController.shared.isRecording
                 ? String(localized: "Waiting for traffic…", comment: "HTTP capture empty state")
                 : String(localized: "Record to capture HTTP and HTTPS traffic through the VPN. If no VPN is connected, Local Capture connects one without a server.", comment: "HTTP capture empty state"))
        } actions: {
            if !CaptureController.shared.isRecording {
                Button(String(localized: "Record", comment: "HTTP capture: start recording")) {
                    Task { await CaptureController.shared.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct CaptureRequestRows: View {
    @Bindable var model: HTTPCaptureModel
    let document: CaptureSessionDocument
    let pushesDetail: Bool

    var body: some View {
        let rows = model.filtered(document.transactions)
        if document.transactions.isEmpty {
            ContentUnavailableView(
                CaptureController.shared.activeSessionID == document.sessionID
                    ? String(localized: "Waiting for Traffic", comment: "HTTP capture: recording with no rows yet")
                    : String(localized: "Empty Session", comment: "HTTP capture: finished session with no rows"),
                systemImage: "antenna.radiowaves.left.and.right"
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: pushesDetail ? nil : selectionBinding) {
                    ForEach(rows) { tx in
                        Group {
                            if pushesDetail {
                                NavigationLink(value: HTTPCaptureModel.Route.transaction(tx.id)) {
                                    CaptureRequestRow(tx: tx)
                                }
                            } else {
                                CaptureRequestRow(tx: tx)
                            }
                        }
                        .tag(tx.id)
                        .contextMenu { CaptureTransactionMenu(model: model, document: document, tx: tx) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .listRowBackground(rowBackground(selected: !pushesDetail && model.selectedTransactionID == tx.id))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .modifier(ScrollEdgeEffectHiddenModifier())
                .overlay(alignment: .bottom) {
                    Text("\(rows.count) of \(document.transactions.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 6)
                        .opacity(model.hasFilters ? 1 : 0)
                }
                .onChange(of: model.selectedTransactionID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// The panel paints the (themed) fill; rows stay clear except the selection.
    private func rowBackground(selected: Bool) -> Color {
        selected ? Color.accentColor.opacity(0.2) : .clear
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selectedTransactionID }, set: { model.selectedTransactionID = $0 })
    }
}

struct CaptureRequestRow: View {
    let tx: CaptureTransaction
    @Setting(Settings.HTTPCapture.lookUpServerLocation) private var lookUpServerLocation

    private var geoIP: String? { lookUpServerLocation ? tx.serverIP : nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tx.method)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    statusBadge
                    Text(tx.displayHost)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let geo = CaptureGeoLookup.shared.geo(for: geoIP), let flag = geo.flag {
                        Text(flag)
                            .font(.caption)
                            .help(geo.countryName ?? geo.countryCode)
                    }
                    if tx.wasRewritten {
                        Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.purple)
                    }
                    if tx.isWebSocket {
                        Image(systemName: "bolt.horizontal").font(.caption2).foregroundStyle(.teal)
                    }
                }
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let duration = tx.durationMs {
                    Text(CaptureFormat.duration(duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(CaptureFormat.bytes(tx.responseBytes)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: CaptureGeoLookup.shared.key(for: geoIP)) { await CaptureGeoLookup.shared.track(geoIP) }
    }

    private var subtitle: String {
        switch tx.kind {
        case .http: tx.path
        case .tunnel: CaptureFormat.tunnelReason(tx.tunnelReason)
        case .rejected: String(localized: "Client rejected the certificate (pinned?)", comment: "HTTP capture row subtitle")
        case .failure: tx.error ?? CaptureFormat.tunnelReason(tx.tunnelReason)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = tx.status {
            Text(String(status))
                .font(.caption2.monospacedDigit().weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(CaptureFormat.statusColor(status).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(CaptureFormat.statusColor(status))
        } else if tx.kind == .http, tx.error != nil {
            Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    private var icon: String {
        switch tx.kind {
        case .http: tx.contentKind.systemImage
        case .tunnel: "lock"
        case .rejected: "lock.trianglebadge.exclamationmark"
        case .failure: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch tx.kind {
        case .http: tx.scheme == "https" ? .green : .blue
        case .tunnel: .secondary
        case .rejected: .orange
        case .failure: .red
        }
    }
}

/// Context-menu actions for one request; also used by the detail view's menu.
struct CaptureTransactionMenu: View {
    let model: HTTPCaptureModel
    let document: CaptureSessionDocument
    let tx: CaptureTransaction

    var body: some View {
        if tx.kind == .http {
            Button {
                UIPasteboard.general.string = tx.url
            } label: { Label(String(localized: "Copy URL", comment: "HTTP capture action"), systemImage: "link") }
            Button {
                Task {
                    let body = await document.body(tx, side: .request)
                    UIPasteboard.general.string = CaptureCURL.command(for: tx, body: body)
                }
            } label: { Label(String(localized: "Copy as cURL", comment: "HTTP capture action"), systemImage: "terminal") }
            Menu {
                ForEach(CaptureTransaction.Side.allCases, id: \.self) { side in
                    Section(side == .request
                            ? String(localized: "Request", comment: "HTTP capture message side")
                            : String(localized: "Response", comment: "HTTP capture message side")) {
                        ForEach(CaptureMessageExport.Part.allCases) { part in
                            Button(part.title) { copy(side: side, part: part) }
                        }
                    }
                }
            } label: { Label(String(localized: "Copy", comment: "HTTP capture copy submenu"), systemImage: "doc.on.doc") }
            Menu {
                ForEach(CaptureTransaction.Side.allCases, id: \.self) { side in
                    Section(side == .request
                            ? String(localized: "Request", comment: "HTTP capture message side")
                            : String(localized: "Response", comment: "HTTP capture message side")) {
                        ForEach(CaptureMessageExport.Part.allCases) { part in
                            Button(part.title) { export(side: side, part: part) }
                        }
                    }
                }
            } label: { Label(String(localized: "Export", comment: "HTTP capture export submenu"), systemImage: "square.and.arrow.up") }
            Divider()
            Button {
                model.sheet = .rewriteRule(CaptureRewriteRule.prefilled(for: tx))
            } label: { Label(String(localized: "Add Rewrite Rule…", comment: "HTTP capture action"), systemImage: "wand.and.stars") }
        }
        let host = tx.kind == .tunnel ? (tx.sni ?? tx.host) : tx.host
        Section {
            HostAddressCopyActions(hostname: host, ipAddress: tx.serverIP)
        }
        if !host.isEmpty {
            if tx.kind == .http && tx.scheme == "https" {
                Button {
                    CaptureController.shared.excludeHost(host)
                } label: { Label(String(localized: "Don't Decrypt \(host)", comment: "HTTP capture action"), systemImage: "lock") }
            } else if tx.kind != .http {
                Button {
                    CaptureController.shared.includeHost(host)
                } label: { Label(String(localized: "Decrypt \(host)", comment: "HTTP capture action"), systemImage: "lock.open") }
            }
        }
    }

    private func copy(side: CaptureTransaction.Side, part: CaptureMessageExport.Part) {
        Task {
            let body = part == .headers ? nil : await document.decodedBody(tx, side: side)?.data
            let data = CaptureMessageExport.data(for: tx, side: side, part: part, body: body)
            if let text = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = text
            } else {
                UIPasteboard.general.setData(data, forPasteboardType: "public.data")
            }
        }
    }

    private func export(side: CaptureTransaction.Side, part: CaptureMessageExport.Part) {
        Task {
            let decoded = part == .headers ? nil : await document.decodedBody(tx, side: side)?.data
            let data = CaptureMessageExport.data(for: tx, side: side, part: part, body: decoded)
            let ext: String
            switch part {
            case .headers, .both: ext = "txt"
            case .body:
                let kind = side == .response ? tx.contentKind : CaptureContentKind(contentType: tx.requestHeaders.first("content-type"))
                ext = kind.fileExtension
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(tx.id)-\(side.rawValue)-\(part.rawValue).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                model.sheet = .share(url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

extension CaptureRewriteRule {
    /// A response-header rule scoped to this request's host and path.
    static func prefilled(for tx: CaptureTransaction) -> CaptureRewriteRule {
        var rule = CaptureRewriteRule()
        let path = tx.components?.path ?? "/"
        rule.name = "\(tx.displayHost)\(path)"
        rule.match = "\(tx.scheme)://\(tx.host)\(path)*"
        rule.phase = .response
        rule.action = .setHeader
        return rule
    }
}

enum CaptureFormat {
    static func bytes(_ n: Int64) -> String {
        n <= 0 ? "–" : ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }

    static func duration(_ ms: Double) -> String {
        ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }

    static func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        case 500...: .red
        default: .secondary
        }
    }

    static func tunnelReason(_ reason: String?) -> String {
        switch reason {
        case "notMatched": String(localized: "Not in decrypted hosts", comment: "HTTP capture tunnel reason")
        case "noSNI": String(localized: "No hostname (SNI)", comment: "HTTP capture tunnel reason")
        case "bypassed": String(localized: "Skipped: client rejected the certificate earlier", comment: "HTTP capture tunnel reason")
        case "noCA": String(localized: "No capture certificate", comment: "HTTP capture tunnel reason")
        case "alpn": String(localized: "Not HTTP (ALPN)", comment: "HTTP capture tunnel reason")
        case "capacity": String(localized: "Too many decrypted connections", comment: "HTTP capture tunnel reason")
        case "notHTTP": String(localized: "Not HTTP", comment: "HTTP capture tunnel reason")
        case "notInspected": String(localized: "Not inspected", comment: "HTTP capture tunnel reason")
        case "upstreamTLS": String(localized: "Server TLS failed; passed through", comment: "HTTP capture tunnel reason")
        case "upstreamDial": String(localized: "Could not connect to the server", comment: "HTTP capture tunnel reason")
        case "clientCertRequired": String(localized: "Server requires a client certificate", comment: "HTTP capture tunnel reason")
        case "mintFailed": String(localized: "Could not create a certificate", comment: "HTTP capture tunnel reason")
        default: reason ?? ""
        }
    }
}

#endif
