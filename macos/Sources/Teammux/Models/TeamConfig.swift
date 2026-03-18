import SwiftUI

// MARK: - GitHubStatus

/// Represents the current GitHub connection state, shown in the Team Builder
/// and workspace status areas.
enum GitHubStatus: Equatable, Sendable {
    case detecting
    case connected(String)   // associated value is "owner/repo"
    case disconnected
    case error(String)

    /// Semantic color for the status dot.
    var color: Color {
        switch self {
        case .detecting:    return .secondary
        case .connected:    return .green
        case .disconnected: return .yellow
        case .error:        return .red
        }
    }

    /// Human-readable label for the status row.
    var label: String {
        switch self {
        case .detecting:          return "Detecting..."
        case .connected(let repo): return "Connected — \(repo)"
        case .disconnected:       return "Not connected"
        case .error(let msg):     return "Error: \(msg)"
        }
    }
}

// MARK: - TeamLeadConfig

/// Configuration for the Team Lead agent, sourced from
/// `[team_lead]` in `.teammux/config.toml`.
struct TeamLeadConfig: Equatable {
    var agent: AgentType
    var model: String

    static var `default`: TeamLeadConfig {
        TeamLeadConfig(agent: .claudeCode, model: "claude-opus-4-6")
    }
}

// MARK: - WorkerConfig

/// Configuration for a single worker slot in the Team Builder.
/// Corresponds to one `[[workers]]` entry in `.teammux/config.toml`.
struct WorkerConfig: Identifiable, Equatable {
    let id: String
    var name: String
    var agent: AgentType
    var model: String
    var roleId: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        agent: AgentType,
        model: String,
        roleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.agent = agent
        self.model = model
        self.roleId = roleId
    }

    static var `default`: WorkerConfig {
        WorkerConfig(
            name: "Teammate",
            agent: .claudeCode,
            model: "claude-sonnet-4-6"
        )
    }
}

// MARK: - TeamConfig

/// Full team composition. Built in the Team Builder setup screen,
/// serialised to `.teammux/config.toml` on initiation.
struct TeamConfig: Equatable {
    var teamLead: TeamLeadConfig
    var workers: [WorkerConfig]
    var githubRepo: String?

    static var `default`: TeamConfig {
        TeamConfig(
            teamLead: .default,
            workers: [
                WorkerConfig(name: "Teammate 1", agent: .claudeCode, model: "claude-sonnet-4-6"),
                WorkerConfig(name: "Teammate 2", agent: .claudeCode, model: "claude-sonnet-4-6"),
            ],
            githubRepo: nil
        )
    }

    /// Serialise the config to TOML matching the spec format in
    /// `TEAMMUX_V01_SPEC.md` Section 5.
    func toTOML(projectName: String) -> String {
        var lines: [String] = []

        // [project]
        lines.append("[project]")
        lines.append("name = \"\(escapeTOML(projectName))\"")
        if let repo = githubRepo, !repo.isEmpty {
            lines.append("github_repo = \"\(escapeTOML(repo))\"")
        }
        lines.append("")

        // [team_lead]
        lines.append("[team_lead]")
        lines.append("agent = \"\(agentTOMLKey(teamLead.agent))\"")
        lines.append("model = \"\(escapeTOML(teamLead.model))\"")
        lines.append("permissions = \"full\"")
        lines.append("")

        // [[workers]]
        for worker in workers {
            lines.append("[[workers]]")
            lines.append("id = \"\(escapeTOML(worker.id))\"")
            lines.append("name = \"\(escapeTOML(worker.name))\"")
            lines.append("agent = \"\(agentTOMLKey(worker.agent))\"")
            lines.append("model = \"\(escapeTOML(worker.model))\"")
            lines.append("permissions = \"full\"")
            if let roleId = worker.roleId, !roleId.isEmpty {
                lines.append("role = \"\(escapeTOML(roleId))\"")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Private helpers

    /// Map AgentType to the TOML config key.
    private func agentTOMLKey(_ agent: AgentType) -> String {
        switch agent {
        case .claudeCode:       return "claude-code"
        case .codexCli:         return "codex-cli"
        case .custom(let name): return escapeTOML(name)
        }
    }

    /// Escape characters that are meaningful in TOML string values.
    private func escapeTOML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Validate the config and return a list of errors. Empty means valid.
    func validate() -> [String] {
        var errors: [String] = []
        if teamLead.model.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Team Lead model is required")
        }
        for worker in workers {
            if worker.name.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("Worker name is required")
            }
            if worker.model.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("Worker model is required for \(worker.name)")
            }
        }
        return errors
    }
}
