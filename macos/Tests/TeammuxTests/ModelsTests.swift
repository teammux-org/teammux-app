import Testing
import SwiftUI
@testable import Ghostty

// MARK: - WorkerStatus Tests

@Suite
struct WorkerStatusTests {

    @Test func workerStatusColors() {
        #expect(WorkerStatus.idle.color == .secondary)
        #expect(WorkerStatus.working.color == .orange)
        #expect(WorkerStatus.complete.color == .green)
        #expect(WorkerStatus.blocked.color == .yellow)
        #expect(WorkerStatus.error.color == .red)
    }

    @Test func workerStatusLabels() {
        #expect(WorkerStatus.idle.label == "Idle")
        #expect(WorkerStatus.working.label == "Working")
        #expect(WorkerStatus.complete.label == "Complete")
        #expect(WorkerStatus.blocked.label == "Blocked")
        #expect(WorkerStatus.error.label == "Error")
    }

    @Test func workerStatusFromCValue() {
        #expect(WorkerStatus(fromCValue: 0) == .idle)
        #expect(WorkerStatus(fromCValue: 1) == .working)
        #expect(WorkerStatus(fromCValue: 2) == .complete)
        #expect(WorkerStatus(fromCValue: 3) == .blocked)
        #expect(WorkerStatus(fromCValue: 4) == .error)
    }

    @Test func workerStatusFromCValueUnknown() {
        // Unknown values should fall back to .idle
        #expect(WorkerStatus(fromCValue: 5) == .idle)
        #expect(WorkerStatus(fromCValue: -1) == .idle)
        #expect(WorkerStatus(fromCValue: 99) == .idle)
        #expect(WorkerStatus(fromCValue: Int32.max) == .idle)
    }
}

// MARK: - AgentType Tests

@Suite
struct AgentTypeTests {

    @Test func agentTypeDisplayNames() {
        #expect(AgentType.claudeCode.displayName == "Claude Code")
        #expect(AgentType.codexCli.displayName == "Codex CLI")
        #expect(AgentType.custom("foo").displayName == "foo")
    }

    @Test func agentTypeCustomEmptyDisplayName() {
        // Empty custom name should fall back to "Custom Agent"
        #expect(AgentType.custom("").displayName == "Custom Agent")
    }

    @Test func agentTypeResolvedBinary() {
        #expect(AgentType.claudeCode.resolvedBinary() == "claude")
        #expect(AgentType.codexCli.resolvedBinary() == "codex")
        #expect(AgentType.custom("x").resolvedBinary() == "x")
    }

    @Test func agentTypeCValue() {
        #expect(AgentType.claudeCode.cValue == 0)
        #expect(AgentType.codexCli.cValue == 1)
        #expect(AgentType.custom("anything").cValue == 99)
    }

    @Test func agentTypeFromCValue() {
        #expect(AgentType(fromCValue: 0) == .claudeCode)
        #expect(AgentType(fromCValue: 1) == .codexCli)
        // Any other value maps to .custom with empty binary name
        #expect(AgentType(fromCValue: 99) == .custom(""))
        #expect(AgentType(fromCValue: 42) == .custom(""))
    }

    @Test func agentTypeFromCValueWithBinaryName() {
        let agent = AgentType(fromCValue: 99, binaryName: "my-agent")
        #expect(agent == .custom("my-agent"))
        #expect(agent.displayName == "my-agent")
        #expect(agent.resolvedBinary() == "my-agent")
    }

    @Test func agentTypeEquality() {
        // Same types are equal
        #expect(AgentType.claudeCode == AgentType.claudeCode)
        #expect(AgentType.codexCli == AgentType.codexCli)
        #expect(AgentType.custom("foo") == AgentType.custom("foo"))

        // Different types are not equal
        #expect(AgentType.claudeCode != AgentType.codexCli)
        #expect(AgentType.claudeCode != AgentType.custom("claude"))
        #expect(AgentType.custom("foo") != AgentType.custom("bar"))
    }
}

// MARK: - WorkerInfo Tests

@Suite
struct WorkerInfoTests {

    private func makeWorker(
        id: UInt32,
        name: String = "Worker",
        status: WorkerStatus = .idle
    ) -> WorkerInfo {
        WorkerInfo(
            id: id,
            name: name,
            taskDescription: "Some task",
            branchName: "feat/task",
            worktreePath: "/tmp/worktree",
            status: status,
            agentType: .claudeCode,
            agentBinary: "claude",
            model: "claude-sonnet-4-6",
            spawnedAt: Date()
        )
    }

    @Test func workerInfoEqualityByAllFields() {
        let w1 = WorkerInfo(id: 1, name: "A", taskDescription: "t", branchName: "b",
                           worktreePath: "/p", status: .idle, agentType: .claudeCode,
                           agentBinary: "claude", model: "claude-sonnet-4-6",
                           spawnedAt: Date(timeIntervalSince1970: 0))
        let w2 = WorkerInfo(id: 1, name: "B", taskDescription: "t2", branchName: "b2",
                           worktreePath: "/p2", status: .working, agentType: .codexCli,
                           agentBinary: "codex", model: "gpt-4",
                           spawnedAt: Date(timeIntervalSince1970: 100))
        // Now that we use synthesized Equatable, different fields = not equal
        #expect(w1 != w2)
    }

    @Test func workerInfoEqualityIdenticalFields() {
        let date = Date(timeIntervalSince1970: 1000)
        let w1 = WorkerInfo(id: 1, name: "A", taskDescription: "t", branchName: "b",
                           worktreePath: "/p", status: .idle, agentType: .claudeCode,
                           agentBinary: "claude", model: "claude-sonnet-4-6",
                           spawnedAt: date)
        let w2 = WorkerInfo(id: 1, name: "A", taskDescription: "t", branchName: "b",
                           worktreePath: "/p", status: .idle, agentType: .claudeCode,
                           agentBinary: "claude", model: "claude-sonnet-4-6",
                           spawnedAt: date)
        #expect(w1 == w2)
    }

    @Test func workerInfoInequalityByDifferentId() {
        // Different ID means not equal, even if other fields are the same
        let w1 = makeWorker(id: 1, name: "Alice")
        let w2 = makeWorker(id: 2, name: "Alice")
        #expect(w1 != w2)
    }
}

// MARK: - MessageType Tests

@Suite
struct MessageTypeTests {

    @Test func messageTypeColors() {
        #expect(MessageType.task.color == .blue)
        #expect(MessageType.instruction.color == .purple)
        #expect(MessageType.context.color == .secondary)
        #expect(MessageType.completion.color == .green)
        #expect(MessageType.error.color == .red)
        #expect(MessageType.broadcast.color == .yellow)
    }

    @Test func messageTypeLabels() {
        #expect(MessageType.task.label == "Task")
        #expect(MessageType.instruction.label == "Instruction")
        #expect(MessageType.context.label == "Context")
        #expect(MessageType.completion.label == "Completion")
        #expect(MessageType.error.label == "Error")
        #expect(MessageType.broadcast.label == "Broadcast")
    }

    @Test func messageTypeFromCValue() {
        #expect(MessageType(fromCValue: 0) == .task)
        #expect(MessageType(fromCValue: 1) == .instruction)
        #expect(MessageType(fromCValue: 2) == .context)
        #expect(MessageType(fromCValue: 5) == .completion)
        #expect(MessageType(fromCValue: 6) == .error)
        #expect(MessageType(fromCValue: 7) == .broadcast)
    }

    @Test func messageTypeFromCValueUnknown() {
        // Unknown values should fall back to .task
        // Values 3 and 4 (statusReq/statusRpt) were removed — verify they fall through
        #expect(MessageType(fromCValue: 3) == .task)
        #expect(MessageType(fromCValue: 4) == .task)
        #expect(MessageType(fromCValue: 9) == .task)
        #expect(MessageType(fromCValue: -1) == .task)
        #expect(MessageType(fromCValue: 100) == .task)
        #expect(MessageType(fromCValue: Int32.max) == .task)
    }

    @Test func messageTypeCValue() {
        for messageType in MessageType.allCases {
            #expect(messageType.cValue == Int32(messageType.rawValue))
        }
    }
}

// MARK: - TeamMessage Tests

@Suite
struct TeamMessageTests {

    private func makeMessage(payload: String = "test") -> TeamMessage {
        TeamMessage(
            from: 0,
            to: 1,
            type: .task,
            payload: payload,
            timestamp: Date(),
            seq: 1
        )
    }

    @Test func teamMessageUniqueId() {
        // Two messages with identical content still get different UUIDs
        let m1 = makeMessage(payload: "same content")
        let m2 = makeMessage(payload: "same content")
        #expect(m1.id != m2.id)
    }

    @Test func teamMessageEquality() {
        // Equality is by UUID, so two messages with different UUIDs are not equal
        let m1 = makeMessage()
        let m2 = makeMessage()
        #expect(m1 != m2)

        // A message is equal to itself
        #expect(m1 == m1)
    }

    @Test func teamMessageWithGitCommit() {
        let msg = TeamMessage(
            from: 0,
            to: 1,
            type: .completion,
            payload: "done",
            timestamp: Date(),
            seq: 42,
            gitCommit: "abc123"
        )
        #expect(msg.gitCommit == "abc123")
        #expect(msg.seq == 42)
    }

    @Test func teamMessageWithoutGitCommit() {
        let msg = makeMessage()
        #expect(msg.gitCommit == nil)
    }
}

// MARK: - GitHubPR Tests

@Suite
struct GitHubPRTests {

    @Test func gitHubPRIdentityByNumber() {
        let pr = GitHubPR(
            number: 42,
            url: "https://github.com/org/repo/pull/42",
            title: "Add feature",
            state: .open,
            diffUrl: "https://github.com/org/repo/pull/42.diff",
            workerId: 1
        )
        #expect(pr.id == 42)
        #expect(pr.number == 42)
    }

    @Test func gitHubPRFieldAccess() {
        let pr = GitHubPR(
            number: 100,
            url: "https://github.com/org/repo/pull/100",
            title: "Fix bug",
            state: .closed,
            diffUrl: "https://github.com/org/repo/pull/100.diff",
            workerId: 3
        )
        #expect(pr.url == "https://github.com/org/repo/pull/100")
        #expect(pr.title == "Fix bug")
        #expect(pr.state == .closed)
        #expect(pr.diffUrl == "https://github.com/org/repo/pull/100.diff")
        #expect(pr.workerId == 3)
    }
}

// MARK: - DiffFile Tests

@Suite
struct DiffFileTests {

    @Test func diffFileUniqueId() {
        let d1 = DiffFile(
            filePath: "src/main.swift",
            status: .modified,
            additions: 10,
            deletions: 5,
            patch: "@@ -1,5 +1,10 @@"
        )
        let d2 = DiffFile(
            filePath: "src/main.swift",
            status: .modified,
            additions: 10,
            deletions: 5,
            patch: "@@ -1,5 +1,10 @@"
        )
        // Each DiffFile gets its own UUID
        #expect(d1.id != d2.id)
    }

    @Test func diffFileFieldAccess() {
        let d = DiffFile(
            filePath: "README.md",
            status: .added,
            additions: 3,
            deletions: 1,
            patch: "patch content"
        )
        #expect(d.filePath == "README.md")
        #expect(d.status == .added)
        #expect(d.additions == 3)
        #expect(d.deletions == 1)
        #expect(d.patch == "patch content")
    }

    @Test func diffFileDefaultStatus() {
        // status defaults to .modified when not specified
        let d = DiffFile(
            filePath: "test.swift",
            additions: 0,
            deletions: 0,
            patch: ""
        )
        #expect(d.status == .modified)
    }
}

// MARK: - DiffStatus Tests

@Suite
struct DiffStatusTests {

    @Test func diffStatusFromCValue() {
        #expect(DiffStatus(fromCValue: 0) == .added)
        #expect(DiffStatus(fromCValue: 1) == .modified)
        #expect(DiffStatus(fromCValue: 2) == .deleted)
        #expect(DiffStatus(fromCValue: 3) == .renamed)
    }

    @Test func diffStatusFromCValueUnknown() {
        // Unknown values should fall back to .modified
        #expect(DiffStatus(fromCValue: 4) == .modified)
        #expect(DiffStatus(fromCValue: 99) == .modified)
    }

    @Test func diffStatusLabels() {
        #expect(DiffStatus.added.label == "Added")
        #expect(DiffStatus.modified.label == "Modified")
        #expect(DiffStatus.deleted.label == "Deleted")
        #expect(DiffStatus.renamed.label == "Renamed")
    }
}

// MARK: - TeamConfig Tests

@Suite
struct TeamConfigTests {

    @Test func teamConfigDefault() {
        let config = TeamConfig.default
        #expect(config.teamLead.agent == .claudeCode)
        #expect(config.teamLead.model == "claude-opus-4-6")
        #expect(config.workers.count == 2)
        #expect(config.workers[0].name == "Teammate 1")
        #expect(config.workers[1].name == "Teammate 2")
        #expect(config.workers[0].agent == .claudeCode)
        #expect(config.workers[0].model == "claude-sonnet-4-6")
        #expect(config.githubRepo == nil)
    }

    @Test func teamConfigTOMLSerialization() {
        let config = TeamConfig.default
        let toml = config.toTOML(projectName: "MyProject")

        // Must contain the required sections
        #expect(toml.contains("[project]"))
        #expect(toml.contains("[team_lead]"))
        #expect(toml.contains("[[workers]]"))

        // Must contain project name
        #expect(toml.contains("name = \"MyProject\""))

        // Must contain team lead config
        #expect(toml.contains("agent = \"claude-code\""))
        #expect(toml.contains("model = \"claude-opus-4-6\""))

        // Must contain worker names
        #expect(toml.contains("name = \"Teammate 1\""))
        #expect(toml.contains("name = \"Teammate 2\""))

        // Must contain worker model
        #expect(toml.contains("model = \"claude-sonnet-4-6\""))

        // Must contain permissions
        #expect(toml.contains("permissions = \"full\""))
    }

    @Test func teamConfigTOMLWithGitHubRepo() {
        var config = TeamConfig.default
        config.githubRepo = "org/repo"
        let toml = config.toTOML(projectName: "TestProject")

        #expect(toml.contains("github_repo = \"org/repo\""))
    }

    @Test func teamConfigTOMLWithoutGitHubRepo() {
        let config = TeamConfig.default
        let toml = config.toTOML(projectName: "TestProject")

        #expect(!toml.contains("github_repo"))
    }

    @Test func teamConfigTOMLEmptyGitHubRepoOmitted() {
        var config = TeamConfig.default
        config.githubRepo = ""
        let toml = config.toTOML(projectName: "Test")
        #expect(!toml.contains("github_repo"))
    }

    @Test func teamConfigValidateEmptyModel() {
        var config = TeamConfig.default
        config.teamLead.model = ""
        let errors = config.validate()
        #expect(!errors.isEmpty)
    }

    @Test func teamConfigValidatePassesDefault() {
        let config = TeamConfig.default
        let errors = config.validate()
        #expect(errors.isEmpty)
    }

    @Test func teamConfigTOMLEscaping() {
        var config = TeamConfig.default
        // Test escaping of special characters in project name
        let toml = config.toTOML(projectName: "My \"Project\" with \\slashes")
        #expect(toml.contains("name = \"My \\\"Project\\\" with \\\\slashes\""))

        // Test escaping in github repo
        config.githubRepo = "org/repo\"name"
        let toml2 = config.toTOML(projectName: "test")
        #expect(toml2.contains("github_repo = \"org/repo\\\"name\""))
    }

    @Test func teamConfigTOMLCodexCli() {
        let config = TeamConfig(
            teamLead: TeamLeadConfig(agent: .codexCli, model: "gpt-4"),
            workers: [],
            githubRepo: nil
        )
        let toml = config.toTOML(projectName: "test")
        #expect(toml.contains("agent = \"codex-cli\""))
        #expect(toml.contains("model = \"gpt-4\""))
    }

    @Test func teamConfigTOMLCustomAgent() {
        let config = TeamConfig(
            teamLead: TeamLeadConfig(agent: .custom("my-agent"), model: "custom-model"),
            workers: [],
            githubRepo: nil
        )
        let toml = config.toTOML(projectName: "test")
        #expect(toml.contains("agent = \"my-agent\""))
    }

    @Test func teamConfigEquality() {
        let c1 = TeamConfig.default
        let c2 = TeamConfig.default
        #expect(c1 == c2)
    }
}

// MARK: - TeamLeadConfig Tests

@Suite
struct TeamLeadConfigTests {

    @Test func teamLeadConfigDefault() {
        let lead = TeamLeadConfig.default
        #expect(lead.agent == .claudeCode)
        #expect(lead.model == "claude-opus-4-6")
    }
}

// MARK: - WorkerConfig Tests

@Suite
struct WorkerConfigTests {

    @Test func workerConfigDefault() {
        let worker = WorkerConfig.default
        #expect(worker.name == "Teammate")
        #expect(worker.agent == .claudeCode)
        #expect(worker.model == "claude-sonnet-4-6")
    }

    @Test func workerConfigCustom() {
        let worker = WorkerConfig(
            id: "custom-id",
            name: "My Worker",
            agent: .codexCli,
            model: "gpt-4"
        )
        #expect(worker.id == "custom-id")
        #expect(worker.name == "My Worker")
        #expect(worker.agent == .codexCli)
        #expect(worker.model == "gpt-4")
    }
}

// MARK: - GitHubStatus Tests

@Suite
struct GitHubStatusTests {

    @Test func gitHubStatusColors() {
        #expect(GitHubStatus.detecting.color == .secondary)
        #expect(GitHubStatus.connected("org/repo").color == .green)
        #expect(GitHubStatus.disconnected.color == .yellow)
        #expect(GitHubStatus.error("fail").color == .red)
    }

    @Test func gitHubStatusLabels() {
        #expect(GitHubStatus.detecting.label == "Detecting...")
        #expect(GitHubStatus.connected("org/repo").label == "Connected \u{2014} org/repo")
        #expect(GitHubStatus.disconnected.label == "Not connected")
        #expect(GitHubStatus.error("timeout").label == "Error: timeout")
    }

    @Test func gitHubStatusEquality() {
        #expect(GitHubStatus.detecting == GitHubStatus.detecting)
        #expect(GitHubStatus.disconnected == GitHubStatus.disconnected)
        #expect(GitHubStatus.connected("a") == GitHubStatus.connected("a"))
        #expect(GitHubStatus.connected("a") != GitHubStatus.connected("b"))
        #expect(GitHubStatus.error("x") == GitHubStatus.error("x"))
        #expect(GitHubStatus.detecting != GitHubStatus.disconnected)
    }
}

// MARK: - MergeStrategy Tests

@Suite
struct MergeStrategyTests {

    @Test func mergeStrategyCValues() {
        #expect(MergeStrategy.squash.cValue == 0)
        #expect(MergeStrategy.rebase.cValue == 1)
        #expect(MergeStrategy.merge.cValue == 2)
    }

    @Test func mergeStrategyStrings() {
        #expect(MergeStrategy.squash.strategyString == "squash")
        #expect(MergeStrategy.rebase.strategyString == "rebase")
        #expect(MergeStrategy.merge.strategyString == "merge")
    }
}

// MARK: - MergeStatus Tests

@Suite
struct MergeStatusTests {

    @Test func mergeStatusColors() {
        #expect(MergeStatus.pending.color == .secondary)
        #expect(MergeStatus.inProgress.color == .orange)
        #expect(MergeStatus.success.color == .green)
        #expect(MergeStatus.conflict.color == .red)
        #expect(MergeStatus.rejected.color == .secondary)
    }

    @Test func mergeStatusLabels() {
        #expect(MergeStatus.pending.label == "Pending")
        #expect(MergeStatus.inProgress.label == "In Progress")
        #expect(MergeStatus.success.label == "Success")
        #expect(MergeStatus.conflict.label == "Conflict")
        #expect(MergeStatus.rejected.label == "Rejected")
    }

    @Test func mergeStatusFromCValue() {
        #expect(MergeStatus(fromCValue: 0) == .pending)
        #expect(MergeStatus(fromCValue: 1) == .inProgress)
        #expect(MergeStatus(fromCValue: 2) == .success)
        #expect(MergeStatus(fromCValue: 3) == .conflict)
        #expect(MergeStatus(fromCValue: 4) == .rejected)
    }

    @Test func mergeStatusFromCValueUnknown() {
        #expect(MergeStatus(fromCValue: 5) == .pending)
        #expect(MergeStatus(fromCValue: -1) == .pending)
        #expect(MergeStatus(fromCValue: 99) == .pending)
        #expect(MergeStatus(fromCValue: Int32.max) == .pending)
    }

    @Test func mergeStatusCValueRoundTrip() {
        for status in MergeStatus.allCases {
            let roundTripped = MergeStatus(fromCValue: Int32(status.rawValue))
            #expect(roundTripped == status)
        }
    }
}

// MARK: - ConflictInfo Tests

@Suite
struct ConflictInfoTests {

    @Test func conflictInfoFieldAccess() {
        let conflict = ConflictInfo(
            filePath: "src/main.swift",
            conflictType: .content,
            ours: "let x = 1",
            theirs: "let x = 2"
        )
        #expect(conflict.filePath == "src/main.swift")
        #expect(conflict.conflictType == .content)
        #expect(conflict.ours == "let x = 1")
        #expect(conflict.theirs == "let x = 2")
    }

    @Test func conflictInfoNullableFields() {
        let conflict = ConflictInfo(
            filePath: "new_file.swift",
            conflictType: .unknown
        )
        #expect(conflict.ours == nil)
        #expect(conflict.theirs == nil)
    }

    @Test func conflictInfoUniqueId() {
        let c1 = ConflictInfo(filePath: "a.swift", conflictType: .content)
        let c2 = ConflictInfo(filePath: "a.swift", conflictType: .content)
        #expect(c1.id != c2.id)
    }

    @Test func conflictInfoEquality() {
        let id = UUID()
        let c1 = ConflictInfo(id: id, filePath: "a.swift", conflictType: .content, ours: "x", theirs: "y")
        let c2 = ConflictInfo(id: id, filePath: "a.swift", conflictType: .content, ours: "x", theirs: "y")
        #expect(c1 == c2)
    }

    @Test func conflictInfoInequality() {
        let c1 = ConflictInfo(filePath: "a.swift", conflictType: .content)
        let c2 = ConflictInfo(filePath: "b.swift", conflictType: .content)
        #expect(c1 != c2)
    }

    @Test func conflictTypeFromRawString() {
        #expect(ConflictType(rawString: "content") == .content)
        #expect(ConflictType(rawString: "unknown") == .unknown)
        #expect(ConflictType(rawString: "add_add") == .unknown)
        #expect(ConflictType(rawString: "") == .unknown)
    }

    @Test func conflictTypeDisplayName() {
        #expect(ConflictType.content.displayName == "Content conflict")
        #expect(ConflictType.unknown.displayName == "Unknown conflict")
    }

    @Test func conflictInfoInequalityByType() {
        let id = UUID()
        let c1 = ConflictInfo(id: id, filePath: "a.swift", conflictType: .content)
        let c2 = ConflictInfo(id: id, filePath: "a.swift", conflictType: .unknown)
        #expect(c1 != c2)
    }
}

// MARK: - Project Tests

@Suite
struct ProjectTests {

    @Test func projectEqualityById() {
        let id = UUID()
        let p1 = Project(id: id, name: "Project A", path: URL(fileURLWithPath: "/tmp/a"))
        let p2 = Project(id: id, name: "Project B", path: URL(fileURLWithPath: "/tmp/b"))
        #expect(p1 == p2)
    }

    @Test func projectInequalityByDifferentId() {
        let p1 = Project(name: "Same", path: URL(fileURLWithPath: "/tmp/a"))
        let p2 = Project(name: "Same", path: URL(fileURLWithPath: "/tmp/a"))
        #expect(p1 != p2) // Different auto-generated UUIDs
    }

    @Test func projectDefaultActivity() {
        let project = Project(name: "Test", path: URL(fileURLWithPath: "/tmp/test"))
        #expect(project.hasUnseenActivity == false)
    }

    @Test func projectWithActivity() {
        let project = Project(
            name: "Active",
            path: URL(fileURLWithPath: "/tmp/active"),
            hasUnseenActivity: true
        )
        #expect(project.hasUnseenActivity == true)
    }
}

// MARK: - C Value Round-Trip Tests

@Suite
struct CValueRoundTripTests {

    @Test func workerStatusCValueRoundTrip() {
        for status in WorkerStatus.allCases {
            let roundTripped = WorkerStatus(fromCValue: Int32(status.rawValue))
            #expect(roundTripped == status)
        }
    }

    @Test func agentTypeRoundTrip() {
        let cases: [(AgentType, String)] = [
            (.claudeCode, "claude"),
            (.codexCli, "codex"),
            (.custom("test-agent"), "test-agent")
        ]
        for (agent, binary) in cases {
            let roundTripped = AgentType(fromCValue: agent.cValue, binaryName: binary)
            #expect(roundTripped == agent)
        }
    }

    @Test func messageTypeRoundTrip() {
        for type in MessageType.allCases {
            let roundTripped = MessageType(fromCValue: type.cValue)
            #expect(roundTripped == type)
        }
    }
}

// MARK: - PRState Tests

@Suite
struct PRStateTests {

    @Test func prStateFromString() {
        #expect(PRState(from: "open") == .open)
        #expect(PRState(from: "closed") == .closed)
        #expect(PRState(from: "merged") == .merged)
        #expect(PRState(from: "OPEN") == .open)  // case insensitive
        #expect(PRState(from: "banana") == .unknown)
    }

    @Test func prStateFromCValue() {
        #expect(PRState(fromCValue: 0) == .open)
        #expect(PRState(fromCValue: 1) == .closed)
        #expect(PRState(fromCValue: 2) == .merged)
    }

    @Test func prStateFromCValueUnknown() {
        #expect(PRState(fromCValue: 3) == .unknown)
        #expect(PRState(fromCValue: 99) == .unknown)
    }
}

// MARK: - RoleDivision Tests

@Suite
struct RoleDivisionTests {

    @Test func roleDivisionDisplayNames() {
        #expect(RoleDivision.engineering.displayName == "Engineering")
        #expect(RoleDivision.design.displayName == "Design")
        #expect(RoleDivision.product.displayName == "Product")
        #expect(RoleDivision.testing.displayName == "Testing")
        #expect(RoleDivision.projectManagement.displayName == "Project Management")
        #expect(RoleDivision.strategy.displayName == "Strategy")
        #expect(RoleDivision.specialized.displayName == "Specialized")
    }

    @Test func roleDivisionRawValues() {
        #expect(RoleDivision.engineering.rawValue == "engineering")
        #expect(RoleDivision.design.rawValue == "design")
        #expect(RoleDivision.product.rawValue == "product")
        #expect(RoleDivision.testing.rawValue == "testing")
        #expect(RoleDivision.projectManagement.rawValue == "project-management")
        #expect(RoleDivision.strategy.rawValue == "strategy")
        #expect(RoleDivision.specialized.rawValue == "specialized")
    }

    @Test func roleDivisionFromRawValue() {
        #expect(RoleDivision(rawValue: "engineering") == .engineering)
        #expect(RoleDivision(rawValue: "project-management") == .projectManagement)
        #expect(RoleDivision(rawValue: "nonexistent") == nil)
    }

    @Test func roleDivisionCaseCount() {
        #expect(RoleDivision.allCases.count == 7)
    }
}

// MARK: - RoleDefinition Tests

@Suite
struct RoleDefinitionTests {

    private func makeRole(
        id: String = "frontend-engineer",
        name: String = "Frontend Engineer",
        division: String = "engineering",
        emoji: String = "\u{1F3A8}",
        description: String = "React, Vue, UI implementation",
        writePatterns: [String] = ["src/frontend/**", "src/components/**"],
        denyWritePatterns: [String] = ["src/backend/**", "infrastructure/**"],
        canPush: Bool = false,
        canMerge: Bool = false
    ) -> RoleDefinition {
        RoleDefinition(
            id: id,
            name: name,
            division: division,
            emoji: emoji,
            description: description,
            writePatterns: writePatterns,
            denyWritePatterns: denyWritePatterns,
            canPush: canPush,
            canMerge: canMerge
        )
    }

    @Test func roleDefinitionFieldAccess() {
        let role = makeRole()
        #expect(role.id == "frontend-engineer")
        #expect(role.name == "Frontend Engineer")
        #expect(role.division == "engineering")
        #expect(role.emoji == "\u{1F3A8}")
        #expect(role.description == "React, Vue, UI implementation")
        #expect(role.writePatterns == ["src/frontend/**", "src/components/**"])
        #expect(role.denyWritePatterns == ["src/backend/**", "infrastructure/**"])
        #expect(role.canPush == false)
        #expect(role.canMerge == false)
    }

    @Test func roleDefinitionCapabilityFlags() {
        let lead = makeRole(id: "tech-lead", canPush: true, canMerge: true)
        #expect(lead.canPush == true)
        #expect(lead.canMerge == true)

        let worker = makeRole(id: "frontend-engineer", canPush: false, canMerge: false)
        #expect(worker.canPush == false)
        #expect(worker.canMerge == false)
    }

    @Test func roleDefinitionIdentityById() {
        // Identifiable.id is the role id string
        let role = makeRole(id: "backend-engineer")
        #expect(role.id == "backend-engineer")
    }

    @Test func roleDefinitionEqualityByAllFields() {
        let r1 = makeRole(id: "a", name: "A")
        let r2 = makeRole(id: "a", name: "A")
        #expect(r1 == r2)
    }

    @Test func roleDefinitionInequalityByDifferentId() {
        let r1 = makeRole(id: "frontend-engineer")
        let r2 = makeRole(id: "backend-engineer")
        #expect(r1 != r2)
    }

    @Test func roleDefinitionInequalityByDifferentPatterns() {
        let r1 = makeRole(writePatterns: ["src/**"])
        let r2 = makeRole(writePatterns: ["lib/**"])
        #expect(r1 != r2)
    }

    @Test func roleDefinitionEmptyPatterns() {
        let role = makeRole(writePatterns: [], denyWritePatterns: [])
        #expect(role.writePatterns.isEmpty)
        #expect(role.denyWritePatterns.isEmpty)
    }

    @Test func roleDefinitionHashable() {
        let r1 = makeRole(id: "a")
        let r2 = makeRole(id: "b")
        let r3 = makeRole(id: "a")
        let set: Set<RoleDefinition> = [r1, r2, r3]
        #expect(set.count == 2)
    }
}
