//
//  IPLookupOverlay.swift
//  rootshell
//
//  IP Lookup HUD. Passthrough like the clipboard manager's first press: the
//  terminal keeps the keyboard until the field is tapped.
//

import SwiftUI

struct IPLookupHUD: View {
    @Binding var isPresented: Bool
    let model: IPLookupModel

    var body: some View {
        GeometryReader { geometry in
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                // With the field focused the terminal is out of the responder
                // chain, so the host answers the toggle_ip_lookup chord.
                forwardsIPLookupToggle: true,
                onDismiss: { isPresented = false }
            ) {
                IPLookupOverlay(model: model, isPresented: $isPresented,
                                width: min(340, max(240, geometry.size.width - 24)))
            }
        }
    }
}

struct IPLookupOverlay: View {
    @Bindable var model: IPLookupModel
    @Binding var isPresented: Bool
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    let width: CGFloat

    /// Fixed so async results never resize the hosted panel (see ClipboardManagerOverlay).
    private static let resultsHeight: CGFloat = 196

    var body: some View {
        VStack(spacing: 0) {
            header
            field
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.resultsHeight)
            Divider()
            footer
        }
        .frame(width: width)
        .floatingHUDPanelBackground()
        .onChange(of: model.query) { _, _ in model.clearInputError() }
    }

    // MARK: Chrome

    @ViewBuilder
    private var header: some View {
        if edgeSidebarTitleContext != nil {
            EdgeSidebarHeader(
                title: String(localized: "IP Lookup", comment: "IP Lookup HUD title"),
                systemImage: "globe",
                status: providerLabel,
                onClose: { isPresented = false }
            ) {
                Button { model.discoverPublicAddresses() } label: {
                    Image(systemName: "globe").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Show My Public IP", comment: "IP Lookup button"))
                .help(Text("Show My Public IP", comment: "IP Lookup button"))
                .edgeSidebarHeaderActionTarget()
            }
        } else {
            standaloneHeader
        }
    }

    private var standaloneHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("IP Lookup", comment: "IP Lookup HUD title").font(.headline)
                Text(providerLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.discoverPublicAddresses() } label: {
                Image(systemName: "globe").font(.title3)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Show My Public IP", comment: "IP Lookup button"))
            .help(Text("Show My Public IP", comment: "IP Lookup button"))
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Close IP Lookup", comment: "IP Lookup close button"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var providerLabel: String {
        let provider = GeoResolver.shared.providerType
        return provider == .disabled
            ? String(localized: "Geo lookups are off", comment: "IP Lookup subtitle when the geo provider is disabled")
            : provider.displayName
    }

    private var field: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            SidebarSearchField(
                text: $model.query,
                placeholder: String(localized: "Look up an IP address", comment: "IP Lookup field placeholder"),
                fontSize: 15,
                canFocus: isPresented,
                // Tap to focus only: opening must leave the keyboard with the terminal.
                focusRequestID: 0,
                capturesNavigationKeys: false,
                onMoveUpBegan: {},
                onMoveUpEnded: {},
                onMoveDownBegan: {},
                onMoveDownEnded: {},
                onEscape: { isPresented = false },
                onSubmit: { model.submit() },
                onFocusChange: { _ in }
            )
            .frame(height: 22)
            .accessibilityLabel(Text("IP address", comment: "IP Lookup field accessibility label"))
        }
        .padding(8)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        Group {
            if let error = model.inputError {
                Text(error).foregroundStyle(.red)
            } else {
                Text(footerHint).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footerHint: String {
        guard let chord = KeybindManager.shared.sequence(for: .toggle_ip_lookup)?.symbolDescription else {
            return String(localized: "↵ Look up   Empty ↵ My IP   Esc Close", comment: "IP Lookup footer hint")
        }
        return String(localized: "↵ Look up   Empty ↵ My IP   \(chord) Close", comment: "IP Lookup footer hint; the argument is the shortcut")
    }

    // MARK: Rows

    private func rowView(_ row: IPLookupModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(for: row.origin))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let address = row.address {
                HStack(spacing: 6) {
                    Text(address)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.copy(row) } label: {
                        Image(systemName: model.copiedOrigin == row.origin ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Copy Address", comment: "IP Lookup copy button"))
                }
            }
            status(row)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func status(_ row: IPLookupModel.Row) -> some View {
        switch row.status {
        case .discovering:
            progress(String(localized: "Discovering…", comment: "IP Lookup: STUN discovery in progress"))
        case .resolving:
            progress(String(localized: "Looking up…", comment: "IP Lookup: geo lookup in progress"))
        case .resolved:
            if let geo = row.geo {
                geoLines(geo)
            } else {
                Text(GeoResolver.shared.providerType == .disabled
                     ? String(localized: "Choose a geo provider in Settings", comment: "IP Lookup: geo provider disabled")
                     : String(localized: "No geo data for this address", comment: "IP Lookup: provider returned nothing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func geoLines(_ geo: GeoInfo) -> some View {
        let domain = geo.asDomain.flatMap { $0.isEmpty ? nil : $0 }
        if let name = geo.asName.flatMap({ $0.isEmpty ? nil : $0 }) ?? domain {
            HStack(spacing: 6) {
                if let domain {
                    FaviconImage(domain: domain, size: 14)
                }
                Text(name).lineLimit(1)
            }
            .font(.callout)
        }
        let network = [geo.asNumber, geo.network].filter { !$0.isEmpty }.joined(separator: " · ")
        if !network.isEmpty {
            Text(network)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if let place = placeLine(geo) {
            Text(place)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func placeLine(_ geo: GeoInfo) -> String? {
        let country = geo.countryName.flatMap { $0.isEmpty ? nil : $0 } ?? geo.countryCode
        let parts = [geo.cityName ?? "", country].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let place = parts.joined(separator: ", ")
        guard let flag = GeoInfo.emojiFlag(for: geo.countryCode) else { return place }
        return "\(flag) \(place)"
    }

    private func title(for origin: IPLookupModel.Row.Origin) -> String {
        switch origin {
        case .clipboard: String(localized: "From Clipboard", comment: "IP Lookup row title")
        case .entered: String(localized: "Lookup", comment: "IP Lookup row title for a typed address")
        case .publicIPv4: String(localized: "Public IPv4", comment: "IP Lookup row title")
        case .publicIPv6: String(localized: "Public IPv6", comment: "IP Lookup row title")
        }
    }
}
