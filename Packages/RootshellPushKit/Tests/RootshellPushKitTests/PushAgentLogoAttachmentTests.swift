import Foundation
import Testing
@testable import RootshellPushKit

@Suite("Push agent logo mapping")
struct PushAgentLogoAttachmentTests {
    @Test("Known hook agents resolve to bundled PNGs", arguments: [
        (agent: "claude-code", assetName: "ClaudeLogo"),
        (agent: "codex", assetName: "CodexLogo"),
        (agent: "pi", assetName: "PiLogo"),
        (agent: "omp", assetName: "OMPLogo"),
    ])
    func knownAgent(agent: String, assetName: String) throws {
        #expect(PushAgentLogoAttachment.assetName(for: agent) == assetName)
        let url = try #require(PushAgentLogoAttachment.resourceURL(for: agent))
        let data = try Data(contentsOf: url)
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test("Unknown and absent agents do not resolve to an asset", arguments: [
        nil,
        "",
        "cursor",
        "claude",
    ] as [String?])
    func unknownAgent(agent: String?) {
        #expect(PushAgentLogoAttachment.assetName(for: agent) == nil)
        #expect(PushAgentLogoAttachment.resourceURL(for: agent) == nil)
    }
}
