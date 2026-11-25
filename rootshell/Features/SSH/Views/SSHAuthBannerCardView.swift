//
//  SSHAuthBannerCardView.swift
//  rootshell
//
//  Nonmodal card showing SSH_MSG_USERAUTH_BANNER text live during SSH
//  authentication (issue #290), with explicit open/copy actions for
//  server-provided http(s) URLs. Server content renders as selectable plain
//  text only — never interpreted, never auto-opened.
//

import SwiftUI
import UIKit

/// The auth-banner card shown over a terminal pane during SSH authentication.
/// Collapsible to a pill and closable in either form; a banner arriving after
/// a dismissal brings the card back, so nothing is lost permanently.
struct SSHAuthBannerCardView: View {
    let state: SSHAuthBannerCardState
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onDismiss: () -> Void
    let onOpenURL: (URL) -> Void
    let onCopyURL: (URL) -> Void

    private var transitionAnimation: Animation {
        UIAccessibility.isReduceMotionEnabled
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.38, dampingFraction: 0.8)
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedPill
            } else {
                expandedCard
            }
        }
        .animation(transitionAnimation, value: isCollapsed)
    }

    // MARK: - Collapsed pill

    /// Two buttons rather than a row-wide one: a collapsed pill has to be
    /// closable in a single tap, or dismissing means expanding first.
    private var collapsedPill: some View {
        HStack(spacing: 6) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Server message", comment: "Collapsed SSH auth banner pill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    if state.items.count > 1 {
                        Text(verbatim: "\(state.items.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(
                "Server message during SSH authentication. Tap to expand.",
                comment: "Accessibility label for collapsed SSH auth banner pill"
            ))

            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .bannerBackground()
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            "Dismiss server message",
            comment: "Accessibility label for SSH auth banner dismiss button"
        ))
    }

    // MARK: - Expanded card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Server message", comment: "SSH auth banner card title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: state.hostLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onToggleCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(
                    "Collapse server message",
                    comment: "Accessibility label for SSH auth banner collapse button"
                ))

                dismissButton
            }

            SSHAuthBannerContentView(
                state: state,
                onOpenURL: onOpenURL,
                onCopyURL: onCopyURL
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .bannerBackground()
    }
}

/// Banner text plus per-URL action rows. Shared between the pane card and the
/// keyboard-interactive prompt sheet (which covers the pane on iPhone exactly
/// when OTP-style banners matter most).
struct SSHAuthBannerContentView: View {
    let state: SSHAuthBannerCardState
    let onOpenURL: (URL) -> Void
    let onCopyURL: (URL) -> Void

    /// Items paired with their URLs, deduplicated across the card in
    /// first-appearance order. URLs stay attached to the item that carried
    /// them so a jump host's URL renders under the jump host's attribution,
    /// never the target's.
    private var renderedItems: [(item: SSHAuthBannerItem, urls: [URL])] {
        var seen = Set<String>()
        return state.items.map { item in
            (item, item.urls.filter { seen.insert($0.absoluteString).inserted })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderedItems, id: \.item.id) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    if let source = entry.item.sourceLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .semibold))
                            Text("From jump host \(source)", comment: "SSH auth banner jump-host attribution")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    SelectableBannerText(text: entry.item.text)
                    ForEach(entry.urls, id: \.absoluteString) { url in
                        SSHAuthBannerURLRow(url: url, onOpenURL: onOpenURL, onCopyURL: onCopyURL)
                    }
                }
            }
        }
    }
}

/// A server-provided URL with explicit Open and Copy actions. Shared with the
/// keyboard-interactive sheet for URLs carried in prompt text.
struct SSHAuthBannerURLRow: View {
    let url: URL
    let onOpenURL: (URL) -> Void
    let onCopyURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button {
                    onOpenURL(url)
                } label: {
                    Label {
                        Text("Open in Browser", comment: "SSH auth banner URL action")
                    } icon: {
                        Image(systemName: "safari")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(
                    "Open \(url.host ?? url.absoluteString) in browser",
                    comment: "Accessibility label for SSH auth banner open-URL button"
                ))

                Button {
                    onCopyURL(url)
                } label: {
                    Label {
                        Text("Copy Link", comment: "SSH auth banner URL action")
                    } icon: {
                        Image(systemName: "link")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(
                    "Copy link to \(url.host ?? url.absoluteString)",
                    comment: "Accessibility label for SSH auth banner copy-URL button"
                ))
            }
        }
    }
}

/// Minimal selectable-text wrapper. SwiftUI's `.textSelection(.enabled)`
/// doesn't support click-and-drag selection on Mac Catalyst, so banner text
/// goes through a UITextView. Deliberately local (not the AIAgent
/// `SelectableTextView`, which is excluded from the China build) and
/// deliberately inert: not editable, no data detectors, so server-controlled
/// text can never become a tappable link — URLs get explicit buttons instead.
private struct SelectableBannerText: UIViewRepresentable {
    let text: String

    /// Cap before the text scrolls internally; the pane host also caps the
    /// whole card at 60% of pane height.
    private static let maxHeight: CGFloat = 200

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextView, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 396
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: min(fitting.height, Self.maxHeight))
    }
}
