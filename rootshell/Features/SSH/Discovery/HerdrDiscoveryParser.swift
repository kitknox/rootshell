//
//  HerdrDiscoveryParser.swift
//  rootshell
//
//  Data models and parser for herdr session detection on SSH hosts and the
//  local machine. herdr is an agent multiplexer; `herdr session list --json`
//  enumerates sessions without needing a running server, and a best-effort
//  `herdr agent list` per running session enriches rows with agent status.
//

import Foundation
import os

// MARK: - Data Models

struct HerdrAgentInfo: Equatable, Sendable {
    let terminalID: String
    /// Best available display name: name > title > display_agent > agent.
    let displayName: String?
    /// Open status string from herdr (working/blocked/idle/...); kept raw so
    /// newer herdr statuses pass through without a decode failure.
    let status: String?
}

struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    /// "default" for the unnamed default session.
    let name: String
    let isDefault: Bool
    /// Whether the session's server socket is alive.
    let isRunning: Bool
    /// nil when agent info was unavailable (dead server, old herdr, or the
    /// minimal retry shape that skips agent probes).
    var agents: [HerdrAgentInfo]?
    /// ANSI capture of the session's focused pane for preview rendering.
    var capturedContent: String?
    /// Whether the host's herdr offers control streams; nil when the probe
    /// did not run (minimal retry).
    var supportsControlStream: Bool?

    var id: String { name }

    /// Summary detail shown in the picker row, e.g. "2 agents".
    var detailText: String {
        if let agents, !agents.isEmpty {
            return agents.count == 1 ? "1 agent" : "\(agents.count) agents"
        }
        return isDefault ? "default" : ""
    }

    /// Secondary line, e.g. "claude working · codex idle".
    var agentSubtitle: String? {
        guard let agents, !agents.isEmpty else { return nil }
        let parts = agents.compactMap { agent -> String? in
            guard let name = agent.displayName, !name.isEmpty else { return nil }
            if let status = agent.status, !status.isEmpty {
                return "\(name) \(status)"
            }
            return name
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Parser

enum HerdrDiscoveryParser {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "HerdrDiscoveryParser"
    )

    private struct SessionsEnvelope: Decodable {
        let sessions: [SessionEntry]
    }

    private struct SessionEntry: Decodable {
        let name: String
        let isDefault: Bool?
        let running: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case isDefault = "default"
            case running
        }
    }

    private struct AgentListReply: Decodable {
        let result: AgentListResult?
    }

    private struct AgentListResult: Decodable {
        let agents: [AgentEntry]?
    }

    private struct AgentEntry: Decodable {
        let terminalId: String?
        let name: String?
        let agent: String?
        let title: String?
        let displayAgent: String?
        let agentStatus: String?

        enum CodingKeys: String, CodingKey {
            case terminalId = "terminal_id"
            case name
            case agent
            case title
            case displayAgent = "display_agent"
            case agentStatus = "agent_status"
        }
    }

    static func parse(output: String) -> [HerdrSessionInfo] {
        let parts = output.components(separatedBy: "::SESSIONS::")
        guard parts.count >= 2 else { return [] }

        // Split off the optional agents/captures sections (absent in the
        // minimal retry). The command emits SESSIONS, then AGENTS, then
        // CAPTURES, so captures are carved off the agents remainder.
        let agentsSplit = parts[1].components(separatedBy: "::AGENTS::")
        let sessionsBlock = agentsSplit[0]
        let agentsRemainder = agentsSplit.count >= 2 ? agentsSplit[1] : ""
        let capturesSplit = agentsRemainder.components(separatedBy: "::CAPTURES::")
        let agentsBlock = capturesSplit[0]
        let capturesBlock = capturesSplit.count >= 2 ? capturesSplit[1] : ""

        guard let envelope: SessionsEnvelope = decodeFirstJSONLine(in: sessionsBlock) else {
            return []
        }

        let agentsBySession = parseAgents(block: agentsBlock)
        let capturesBySession = parseCaptures(block: capturesBlock)
        let supportsControlStream: Bool? = sessionsBlock.contains("::CONTROL:1::")
            ? true
            : (sessionsBlock.contains("::CONTROL:0::") ? false : nil)

        var sessions: [HerdrSessionInfo] = []
        for entry in envelope.sessions {
            let isDefault = entry.isDefault ?? false
            let isRunning = entry.running ?? false
            // The default session is always reported, even on hosts where
            // herdr is merely installed. A stopped default is not a real
            // user workspace, so drop it to keep the picker quiet there.
            if isDefault && !isRunning { continue }
            sessions.append(HerdrSessionInfo(
                name: entry.name,
                isDefault: isDefault,
                isRunning: isRunning,
                agents: agentsBySession[entry.name],
                capturedContent: capturesBySession[entry.name],
                supportsControlStream: supportsControlStream
            ))
        }

        let count = sessions.count
        logger.info("Parsed \(count) herdr sessions")
        return sessions
    }

    /// Parses `::CAPTURE:<session>::` chunks of raw ANSI pane content, the
    /// same chunk shape the tmux/zellij parsers use.
    private static func parseCaptures(block: String) -> [String: String] {
        guard !block.isEmpty else { return [:] }
        var capturesBySession: [String: String] = [:]
        for chunk in block.components(separatedBy: "::CAPTURE:") {
            guard let markerEnd = chunk.range(of: "::\n") ?? chunk.range(of: "::\r\n") else { continue }
            let sessionName = String(chunk[chunk.startIndex..<markerEnd.lowerBound])
            guard !sessionName.isEmpty else { continue }
            let content = String(chunk[markerEnd.upperBound...])
            let trimmed = content.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if !trimmed.isEmpty {
                capturesBySession[sessionName] = trimmed
            }
        }
        return capturesBySession
    }

    /// Parses `::AGENT:<session>::` chunks. Agent data is best-effort: any
    /// missing or undecodable chunk leaves that session's agents nil rather
    /// than failing the parse.
    private static func parseAgents(block: String) -> [String: [HerdrAgentInfo]] {
        guard !block.isEmpty else { return [:] }
        var agentsBySession: [String: [HerdrAgentInfo]] = [:]
        for chunk in block.components(separatedBy: "::AGENT:") {
            guard let markerEnd = chunk.range(of: "::\n") ?? chunk.range(of: "::\r\n") else { continue }
            let sessionName = String(chunk[chunk.startIndex..<markerEnd.lowerBound])
            guard !sessionName.isEmpty else { continue }
            let remainder = String(chunk[markerEnd.upperBound...])
            guard let reply: AgentListReply = decodeFirstJSONLine(in: remainder),
                  let entries = reply.result?.agents else { continue }
            agentsBySession[sessionName] = entries.map { entry in
                HerdrAgentInfo(
                    terminalID: entry.terminalId ?? "",
                    displayName: firstNonEmpty(entry.name, entry.title, entry.displayAgent, entry.agent),
                    status: entry.agentStatus
                )
            }
        }
        return agentsBySession
    }

    /// Finds the first line that looks like a JSON object and decodes it.
    private static func decodeFirstJSONLine<T: Decodable>(in block: String) -> T? {
        for line in block.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }
}
