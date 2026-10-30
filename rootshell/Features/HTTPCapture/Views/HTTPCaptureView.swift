//
//  HTTPCaptureView.swift
//  rootshell
//
//  HTTP capture panel content, shared by the sidebar, the HUD overlay, and
//  the iPhone sheet. Wide layouts show the request list and detail side by
//  side; narrow ones push the detail.
//

#if !CHINA_BUILD

import SwiftUI

struct HTTPCaptureView: View {
    enum Style {
        case sidebar
        case overlay
        case full
        case sheet

        var presentation: PanelPresentation? {
            switch self {
            case .sidebar: .sidebar
            case .overlay: .overlay
            case .full: .full
            case .sheet: nil
            }
        }
    }

    @Bindable var model: HTTPCaptureModel
    let style: Style
    let onClose: () -> Void
    /// Switches between presentations; nil where only one presentation exists.
    let onSwitchPresentation: ((PanelPresentation) -> Void)?

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    private var controller: CaptureController { .shared }
    private var ca: CaptureCAManager { .shared }

    private static let splitMinWidth: CGFloat = 760

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                CaptureStatusBanners(model: model)
                if geometry.size.width >= Self.splitMinWidth {
                    HStack(spacing: 0) {
                        CaptureRequestList(model: model)
                            .frame(width: max(320, geometry.size.width * 0.42))
                        Divider()
                        detailColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    NavigationStack(path: $model.path) {
                        CaptureRequestList(model: model, pushesDetail: true)
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationDestination(for: HTTPCaptureModel.Route.self) { route in
                                switch route {
                                case .transaction(let id):
                                    if let document = model.document {
                                        CaptureTransactionDetail(model: model, document: document, transactionID: id)
                                    }
                                }
                            }
                    }
                }
            }
        }
        .background(style == .sheet ? sheetThemeColors?.background.ignoresSafeArea() : nil)
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet).themedSubSheet(sheetThemeColors)
        }
        .alert(String(localized: "HTTP Capture", comment: "HTTP capture error alert title"), isPresented: errorBinding) {
            Button(String(localized: "OK", comment: "OK button")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: controller.activeSessionID) { _, id in
            if let id { model.open(sessionID: id) }
        }
        .onChange(of: controller.lastError) { _, error in
            if let error { model.errorMessage = error }
        }
        .onAppear {
            ca.refreshTrust()
            model.setVisible(true)
        }
        .onDisappear { model.setVisible(false) }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let document = model.document, let id = model.selectedTransactionID {
            CaptureTransactionDetail(model: model, document: document, transactionID: id)
        } else {
            ContentUnavailableView(
                String(localized: "No Request Selected", comment: "HTTP capture empty detail title"),
                systemImage: "network",
                description: Text("Select a request to see its headers, body, and timing.")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if edgeSidebarTitleContext != nil {
            EdgeSidebarHeader(
                title: String(localized: "HTTP Capture"),
                systemImage: "network.badge.shield.half.filled",
                onClose: onClose
            ) {
                HStack(spacing: 4) {
                    if model.document != nil || controller.isStarting || controller.isRecording {
                        recordButton(includesClear: false).labelStyle(.iconOnly)
                            .edgeSidebarHeaderActionTarget()
                    }
                    CaptureMoreMenu(model: model, includesSessions: true, presentation: style.presentation, onSwitchPresentation: onSwitchPresentation)
                        .equatable()
                        .edgeSidebarHeaderActionTarget()
                }
            }
        } else {
            standaloneHeader
        }
    }

    private var standaloneHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(Color.accentColor)
            CaptureSessionMenu(model: model, title: currentSessionTitle)
                .equatable()
            Spacer(minLength: 4)
            recordButton()
            CaptureMoreMenu(model: model)
                .equatable()
            if let onSwitchPresentation, let current = style.presentation {
                PanelPresentationMenu(current: current, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .help(String(localized: "Close (esc)", comment: "HTTP capture close button tooltip"))
            .accessibilityLabel(String(localized: "Close HTTP Capture", comment: "HTTP capture close button"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentSessionTitle: String {
        if let id = model.sessionID, let meta = CaptureSessionStore.shared.meta(id) {
            return meta.name
        }
        return String(localized: "HTTP Capture", comment: "HTTP capture panel title")
    }

    @ViewBuilder
    private func recordButton(includesClear: Bool = true) -> some View {
        if controller.isStarting {
            ProgressView().controlSize(.small)
        } else if controller.isRecording {
            if includesClear {
                CaptureClearButton().labelStyle(.iconOnly)
            }
            Button {
                Task { await controller.stop() }
            } label: {
                Label(String(localized: "Stop", comment: "HTTP capture: stop recording"), systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .disabled(controller.isStopping)
            .help(String(localized: "Stop recording", comment: "HTTP capture stop tooltip"))
        } else {
            Button {
                Task { await controller.start() }
            } label: {
                Label(String(localized: "Record", comment: "HTTP capture: start recording"), systemImage: "record.circle")
            }
            .help(String(localized: "Start a new capture session", comment: "HTTP capture record tooltip"))
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: HTTPCaptureModel.Sheet) -> some View {
        switch sheet {
        case .sessions:
            NavigationStack { CaptureSessionsView(model: model) }
        case .settings:
            NavigationStack { CaptureSettingsView() }
        case .trustGuide:
            NavigationStack { CATrustGuideView(showsDone: true) }
        case .share(let url):
            CaptureShareSheet(items: [url])
        case .rewriteRule(let rule):
            NavigationStack {
                RewriteRuleEditor(rule: rule) { saved in
                    var rules = CaptureController.rewriteRules()
                    if let index = rules.firstIndex(where: { $0.id == saved.id }) {
                        rules[index] = saved
                    } else {
                        rules.append(saved)
                    }
                    CaptureController.shared.saveRewriteRules(rules)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Own scope for `engineStatus`: the VPN status JSON changes on every poll
/// while traffic flows, and reading it in the panel redraws the whole panel.
private struct CaptureStatusBanners: View {
    let model: HTTPCaptureModel

    private var controller: CaptureController { .shared }
    private var ca: CaptureCAManager { .shared }

    var body: some View {
        if ca.trust == .untrusted || ca.trust == .missing {
            banner(
                icon: "exclamationmark.shield",
                text: String(localized: "Trust the capture certificate to decrypt HTTPS.", comment: "HTTP capture banner"),
                action: String(localized: "Set Up", comment: "HTTP capture banner button")
            ) { model.sheet = .trustGuide }
        } else if controller.isRecording, let reason = controller.engineStatus?.stopReason {
            banner(
                icon: "exclamationmark.triangle",
                text: Self.stopReasonText(reason),
                action: String(localized: "Stop", comment: "HTTP capture banner button")
            ) { Task { await controller.stop() } }
        }
    }

    private static func stopReasonText(_ reason: String) -> String {
        switch reason {
        case "sizeLimit": String(localized: "Recording paused: the session reached its size limit.", comment: "HTTP capture stop reason")
        case "writeError": String(localized: "Recording paused: the capture could not be written to disk.", comment: "HTTP capture stop reason")
        default: String(localized: "Recording paused.", comment: "HTTP capture stop reason")
        }
    }

    private func banner(icon: String, text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: perform).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

/// Equatable owner for the session picker. The header redraws on every VPN
/// status tick while recording, which would rebuild an open menu.
private struct CaptureSessionMenu: View, Equatable {
    let model: HTTPCaptureModel
    let title: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.title == rhs.title
    }

    var body: some View {
        Menu {
            CaptureSessionMenuItems(model: model)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .accessibilityLabel(String(localized: "Capture Session", comment: "HTTP capture session picker"))
    }
}

private struct CaptureSessionMenuItems: View {
    let model: HTTPCaptureModel

    var body: some View {
        ForEach(CaptureSessionStore.shared.sessions.prefix(15)) { meta in
            Button {
                model.open(sessionID: meta.id)
            } label: {
                if meta.isRecording {
                    Label(meta.name, systemImage: "record.circle")
                } else {
                    Text(meta.name)
                }
            }
        }
        Divider()
        Button {
            model.sheet = .sessions
        } label: {
            Label(String(localized: "All Sessions…", comment: "HTTP capture: open session list"), systemImage: "list.bullet")
        }
    }
}

private struct CaptureClearButton: View {
    var body: some View {
        Button {
            Task { await CaptureController.shared.clearActiveSession() }
        } label: {
            Label(String(localized: "Clear", comment: "HTTP capture: clear the recording session"), systemImage: "trash")
        }
        .disabled(CaptureController.shared.isStopping)
        .help(String(localized: "Clear the captured requests and keep recording", comment: "HTTP capture clear tooltip"))
    }
}

/// Equatable owner for the overflow menu, same contract as the session picker.
private struct CaptureMoreMenu: View, Equatable {
    let model: HTTPCaptureModel
    var includesSessions = false
    var presentation: PanelPresentation? = nil
    var onSwitchPresentation: ((PanelPresentation) -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.includesSessions == rhs.includesSessions && lhs.presentation == rhs.presentation
    }

    var body: some View {
        Menu {
            if includesSessions {
                if CaptureController.shared.isRecording {
                    CaptureClearButton()
                    Divider()
                }
                Menu {
                    CaptureSessionMenuItems(model: model)
                } label: {
                    Label(String(localized: "Capture Session", comment: "HTTP capture session picker"), systemImage: "clock.arrow.circlepath")
                }
                Divider()
            }
            CaptureMoreMenuItems(model: model)
            if let presentation, let onSwitchPresentation {
                Divider()
                PanelPresentationMenu(current: presentation, onSwitch: onSwitchPresentation, showsTitle: true)
                    .equatable()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(String(localized: "More", comment: "HTTP capture overflow menu"))
    }
}

private struct CaptureMoreMenuItems: View {
    let model: HTTPCaptureModel

    var body: some View {
        if let meta = model.sessionID.flatMap(CaptureSessionStore.shared.meta) {
            CaptureSessionExportMenu(meta: meta, model: model)
            Divider()
        }
        Button {
            Task { await CaptureController.shared.resetConnections() }
        } label: {
            Label(String(localized: "Reset Connections", comment: "HTTP capture: close existing connections"), systemImage: "arrow.clockwise")
        }
        .disabled(!VPNManager.shared.isTunnelUp)
        Button {
            model.sheet = .trustGuide
        } label: {
            Label(String(localized: "Certificate…", comment: "HTTP capture: CA certificate"), systemImage: "checkmark.seal")
        }
        Button {
            model.sheet = .settings
        } label: {
            Label(String(localized: "Capture Settings…", comment: "HTTP capture: settings"), systemImage: "gearshape")
        }
    }
}

/// UIActivityViewController for exported files.
struct CaptureShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Session-level exports, shared by the panel header and the session list.
struct CaptureSessionExportMenu: View {
    let meta: CaptureSessionMeta
    let model: HTTPCaptureModel
    @State private var isWorking = false

    var body: some View {
        Menu {
            Button(String(localized: "HAR", comment: "HTTP capture export format")) { export(.har(sanitize: false)) }
            Button(String(localized: "HAR without Cookies and Auth", comment: "HTTP capture export format")) { export(.har(sanitize: true)) }
            if meta.recordedPackets {
                Button(String(localized: "pcapng (Wireshark)", comment: "HTTP capture export format")) { export(.pcapng) }
            }
            Button(String(localized: "Session Archive (.zip)", comment: "HTTP capture export format")) { export(.archive) }
        } label: {
            Label(String(localized: "Export Session", comment: "HTTP capture export menu"), systemImage: "square.and.arrow.up")
        }
        .disabled(isWorking)
    }

    enum Format {
        case har(sanitize: Bool)
        case pcapng
        case archive
    }

    private func export(_ format: Format) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let url = try await CaptureSessionExporter.export(meta: meta, format: format)
                model.sheet = .share(url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Builds session export files off the main actor.
@MainActor
enum CaptureSessionExporter {
    static func export(meta: CaptureSessionMeta, format: CaptureSessionExportMenu.Format) async throws -> URL {
        if CaptureSessionStore.isMirrored, meta.id != CaptureController.shared.activeSessionID {
            await CaptureSessionStore.shared.mirrorFully(session: meta.id)
        }
        guard let dir = CaptureSessionStore.directory(for: meta.id) else { throw CocoaError(.fileNoSuchFile) }
        let base = CaptureExportNaming.safe(meta.name)
        switch format {
        case .har(let sanitize):
            let document = CaptureSessionDocument(sessionID: meta.id)
            await document.refresh()
            var bodies: [String: CaptureHAR.Body] = [:]
            for tx in document.transactions where tx.kind == .http {
                bodies[tx.id] = CaptureHAR.Body(
                    request: await document.body(tx, side: .request),
                    response: await document.body(tx, side: .response)
                )
            }
            let transactions = document.transactions
            let data = try await Task.detached(priority: .userInitiated) {
                try CaptureHAR.build(meta: meta, transactions: transactions, bodies: bodies, sanitize: sanitize)
            }.value
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).har")
            try data.write(to: url, options: .atomic)
            return url
        case .pcapng:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).pcapng")
            try await Task.detached(priority: .userInitiated) {
                try CapturePcapng.assemble(sessionDirectory: dir, to: url)
            }.value
            return url
        case .archive:
            return try await Task.detached(priority: .userInitiated) {
                try CaptureArchive.zip(sessionDirectory: dir, name: base)
            }.value
        }
    }
}

#endif
