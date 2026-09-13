// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

@MainActor
protocol MuxPreviewFrameSource: AnyObject {
    var ghosttyApp: Ghostty.App? { get }
    var type: MultiplexerType? { get }
    var confirmsPreviewParserGrid: Bool { get }
    func frame(for paneID: String) -> MuxPaneFrame?
}

extension MuxPreviewFrameSource {
    var confirmsPreviewParserGrid: Bool { false }
}
