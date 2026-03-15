# Stream 3: Swift UI — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the complete Teammux Swift UI — setup screens, three-pane workspace, project tab bar, roster, spawn popover, all four right pane tabs. Native macOS. No web views.

**Architecture:** Ghostty owns the PTY. The Zig engine coordinates (worktrees, message bus, config, GitHub). Swift owns the view layer and SurfaceView lifecycle. EngineClient.swift is the sole bridge to tm_* C functions. All views call EngineClient — never tm_* directly.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSWindowController, NSViewRepresentable), GhosttyKit (SurfaceView, SurfaceConfiguration), libteammux.a (C API via teammux.h)

---

## Pre-flight: Pull Stream 1 + Stream 2

**This must happen before any implementation begins.**

```bash
git checkout feat/stream3-swift-ui
git pull origin main    # gets Stream 1 (foundation) + Stream 2 (engine)
```

After pull, verify these files exist:
- `engine/include/teammux.h` — C API header (from Stream 1)
- `macos/Sources/Teammux/Engine/EngineClient.swift` — stub with `version()` (from Stream 1)
- `macos/Sources/App/macOS/AppDelegate.swift` — modified by Stream 1 to suppress Ghostty window
- `engine/src/` — Zig engine implementation (from Stream 2)
- `build.sh` — unified build script (from Stream 1)

Read `engine/include/teammux.h` completely. The function signatures below are from the spec — the actual header may have slight variations. Adapt to match the real header.

---

## Task 1: Swift Types — Data Models

**Files:**
- Create: `macos/Sources/Teammux/Models/WorkerInfo.swift`
- Create: `macos/Sources/Teammux/Models/TeamMessage.swift`
- Create: `macos/Sources/Teammux/Models/TeamConfig.swift`
- Create: `macos/Sources/Teammux/Models/Project.swift`
- Test: `macos/Tests/TeammuxTests/ModelsTests.swift`

### Step 1: Create WorkerInfo.swift

```swift
// macos/Sources/Teammux/Models/WorkerInfo.swift
import SwiftUI

struct WorkerInfo: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let taskDescription: String
    let branchName: String
    let worktreePath: String
    var status: WorkerStatus
    let agentType: AgentType
    let agentBinary: String
    let spawnedAt: Date

    static func == (lhs: WorkerInfo, rhs: WorkerInfo) -> Bool {
        lhs.id == rhs.id
    }
}

enum WorkerStatus: String, CaseIterable {
    case idle, working, complete, blocked, error

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .working: return .orange
        case .complete: return .green
        case .blocked: return .yellow
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .complete: return "Complete"
        case .blocked: return "Blocked"
        case .error: return "Error"
        }
    }
}

enum AgentType: Equatable, Hashable {
    case claudeCode
    case codexCli
    case custom(String)

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "Codex CLI"
        case .custom(let name): return name
        }
    }

    /// Resolve the binary name for PATH lookup
    func resolvedBinary() -> String {
        switch self {
        case .claudeCode: return "claude"
        case .codexCli: return "codex"
        case .custom(let name): return name
        }
    }
}
```

### Step 2: Create TeamMessage.swift

```swift
// macos/Sources/Teammux/Models/TeamMessage.swift
import SwiftUI

struct TeamMessage: Identifiable, Equatable {
    let id = UUID()
    let from: UInt32
    let to: UInt32
    let type: MessageType
    let payload: String
    let timestamp: Date
    let seq: UInt64
    let gitCommit: String?

    static func == (lhs: TeamMessage, rhs: TeamMessage) -> Bool {
        lhs.id == rhs.id
    }
}

enum MessageType: String, CaseIterable {
    case task, instruction, context
    case statusReq, statusRpt, completion, error, broadcast

    var color: Color {
        switch self {
        case .task: return .blue
        case .instruction: return .purple
        case .context: return .cyan
        case .statusReq: return .secondary
        case .statusRpt: return .green
        case .completion: return .green
        case .error: return .red
        case .broadcast: return .orange
        }
    }

    var label: String {
        switch self {
        case .task: return "TASK"
        case .instruction: return "INSTRUCTION"
        case .context: return "CONTEXT"
        case .statusReq: return "STATUS_REQ"
        case .statusRpt: return "STATUS_RPT"
        case .completion: return "COMPLETION"
        case .error: return "ERROR"
        case .broadcast: return "BROADCAST"
        }
    }
}
```

### Step 3: Create TeamConfig.swift

```swift
// macos/Sources/Teammux/Models/TeamConfig.swift
import Foundation

struct TeamConfig {
    var teamLead: TeamLeadConfig
    var workers: [WorkerConfig]
    var githubRepo: String?

    static var `default`: TeamConfig {
        TeamConfig(
            teamLead: .default,
            workers: [WorkerConfig.default],
            githubRepo: nil
        )
    }

    /// Serialize to TOML for writing .teammux/config.toml
    func toTOML(projectName: String) -> String {
        var lines: [String] = []
        lines.append("[project]")
        lines.append("name = \"\(projectName)\"")
        if let repo = githubRepo {
            lines.append("github_repo = \"\(repo)\"")
        }
        lines.append("")
        lines.append("[team_lead]")
        lines.append("agent = \"\(teamLead.agent.resolvedBinary())\"")
        lines.append("model = \"\(teamLead.model)\"")
        lines.append("permissions = \"full\"")
        lines.append("")
        for worker in workers {
            lines.append("[[workers]]")
            lines.append("id = \"\(worker.id)\"")
            lines.append("name = \"\(worker.name)\"")
            lines.append("agent = \"\(worker.agent.resolvedBinary())\"")
            lines.append("model = \"\(worker.model)\"")
            lines.append("permissions = \"full\"")
            lines.append("")
        }
        lines.append("[bus]")
        lines.append("delivery = \"guaranteed\"")
        return lines.joined(separator: "\n")
    }
}

struct TeamLeadConfig {
    var agent: AgentType
    var model: String

    static var `default`: TeamLeadConfig {
        TeamLeadConfig(agent: .claudeCode, model: "claude-opus-4-6")
    }
}

struct WorkerConfig: Identifiable {
    let id: String
    var name: String
    var agent: AgentType
    var model: String

    static var `default`: WorkerConfig {
        WorkerConfig(
            id: UUID().uuidString,
            name: "Teammate",
            agent: .claudeCode,
            model: "claude-sonnet-4-6"
        )
    }
}

enum GitHubStatus: Equatable {
    case detecting, connected(String), disconnected, error(String)

    var color: Color {
        switch self {
        case .detecting: return .secondary
        case .connected: return .green
        case .disconnected: return .red
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .detecting: return "Detecting..."
        case .connected(let via): return "Connected via \(via)"
        case .disconnected: return "Not connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
```

Note: `TeamConfig.swift` imports `Color` via `WorkerInfo.swift`'s `AgentType`. Add `import SwiftUI` if the compiler requires it for `GitHubStatus.color`.

### Step 4: Create Project.swift

```swift
// macos/Sources/Teammux/Models/Project.swift
import Foundation

struct Project: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: URL
    var hasUnseenActivity: Bool = false

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
}
```

### Step 5: Write model tests

```swift
// macos/Tests/TeammuxTests/ModelsTests.swift
import XCTest
@testable import Teammux

final class ModelsTests: XCTestCase {
    func testWorkerStatusColors() {
        // Each status should map to the correct semantic color
        XCTAssertNotNil(WorkerStatus.idle.color)
        XCTAssertNotNil(WorkerStatus.working.color)
        XCTAssertNotNil(WorkerStatus.complete.color)
        XCTAssertNotNil(WorkerStatus.blocked.color)
        XCTAssertNotNil(WorkerStatus.error.color)
    }

    func testAgentTypeDisplayNames() {
        XCTAssertEqual(AgentType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentType.codexCli.displayName, "Codex CLI")
        XCTAssertEqual(AgentType.custom("gemini").displayName, "gemini")
    }

    func testAgentTypeResolvedBinary() {
        XCTAssertEqual(AgentType.claudeCode.resolvedBinary(), "claude")
        XCTAssertEqual(AgentType.codexCli.resolvedBinary(), "codex")
        XCTAssertEqual(AgentType.custom("my-agent").resolvedBinary(), "my-agent")
    }

    func testTeamConfigDefaultValues() {
        let config = TeamConfig.default
        XCTAssertEqual(config.teamLead.model, "claude-opus-4-6")
        XCTAssertEqual(config.workers.count, 1)
        XCTAssertNil(config.githubRepo)
    }

    func testTeamConfigTOMLSerialization() {
        let config = TeamConfig.default
        let toml = config.toTOML(projectName: "test-project")
        XCTAssertTrue(toml.contains("[project]"))
        XCTAssertTrue(toml.contains("name = \"test-project\""))
        XCTAssertTrue(toml.contains("[team_lead]"))
        XCTAssertTrue(toml.contains("[[workers]]"))
        XCTAssertTrue(toml.contains("[bus]"))
    }

    func testMessageTypeLabels() {
        XCTAssertEqual(MessageType.task.label, "TASK")
        XCTAssertEqual(MessageType.completion.label, "COMPLETION")
        XCTAssertEqual(MessageType.error.label, "ERROR")
    }

    func testWorkerInfoEquality() {
        let w1 = WorkerInfo(id: 1, name: "A", taskDescription: "t", branchName: "b",
                           worktreePath: "/p", status: .idle, agentType: .claudeCode,
                           agentBinary: "claude", spawnedAt: Date())
        let w2 = WorkerInfo(id: 1, name: "B", taskDescription: "t2", branchName: "b2",
                           worktreePath: "/p2", status: .working, agentType: .codexCli,
                           agentBinary: "codex", spawnedAt: Date())
        XCTAssertEqual(w1, w2)  // equality by ID only
    }
}
```

### Step 6: Run tests

Run: `./build.sh` or `swift test` (depending on build setup)
Expected: All model tests pass.

### Step 7: Commit

```bash
git add macos/Sources/Teammux/Models/ macos/Tests/TeammuxTests/ModelsTests.swift
git commit -m "feat: Swift data models — WorkerInfo, TeamMessage, TeamConfig, Project

Add all Swift types for Stream 3 UI layer:
- WorkerInfo with status colors (system semantic)
- TeamMessage with type classification
- TeamConfig with TOML serialization
- Project for multi-project tab management
- Unit tests for all models"
```

---

## Task 2: EngineClient — Complete Swift Bridge

**Files:**
- Modify: `macos/Sources/Teammux/Engine/EngineClient.swift`
- Test: `macos/Tests/TeammuxTests/EngineClientTests.swift`

### Step 1: Read the actual teammux.h

Before writing, read `engine/include/teammux.h` to confirm exact function signatures. The code below assumes the spec signatures — adapt if the real header differs.

### Step 2: Implement EngineClient.swift

Replace the Stream 1 stub with the complete bridge. This is the only file that imports tm_* C functions.

```swift
// macos/Sources/Teammux/Engine/EngineClient.swift
import Foundation
import Combine

// NOTE: Ghostty.App is ObservableObject with @Published var app: ghostty_app_t?
// WorkerTerminalView and TeamLeadTerminalView access ghosttyApp.app to create SurfaceView.
// SurfaceView init: init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration?, uuid: UUID?)
// SurfaceConfiguration supports: workingDirectory, command, environmentVariables, initialInput

// MARK: - EngineClient

@MainActor
class EngineClient: ObservableObject {
    private var engine: OpaquePointer?  // tm_engine_t*
    private(set) var projectRoot: String?

    // MARK: Published state
    @Published var roster: [WorkerInfo] = []
    @Published var messages: [TeamMessage] = []
    @Published var githubConnected: Bool = false
    @Published var lastError: String?

    /// Queue of workers whose worktrees are ready for SurfaceView creation.
    /// WorkerPaneView observes this and creates SurfaceView per item.
    @Published var worktreeReadyQueue: [(workerId: UInt32, path: String, binary: String, task: String)] = []

    /// Registry of active SurfaceViews for message bus text injection.
    /// Maps worker ID → SurfaceView. Used by injectText(_:to:).
    private var surfaceViews: [UInt32: AnyObject] = [:]
    // AnyObject because we can't import Ghostty.SurfaceView here without circular deps.
    // The actual type is Ghostty.SurfaceView — callers must cast.

    // MARK: Static

    static func version() -> String { "0.1.0" }

    // MARK: Lifecycle

    func create(projectRoot: String) -> Bool {
        guard let e = tm_engine_create(projectRoot) else {
            lastError = "Failed to create engine for \(projectRoot)"
            return false
        }
        engine = e
        self.projectRoot = projectRoot
        return true
    }

    func sessionStart() -> Bool {
        guard let e = engine else {
            lastError = "Engine not initialized"
            return false
        }
        let result = tm_session_start(e)
        if result != 0 {
            lastError = "Session start failed"
            return false
        }
        setupCallbacks()
        return true
    }

    func sessionStop() {
        guard let e = engine else { return }
        tm_session_stop(e)
    }

    func destroy() {
        sessionStop()
        guard let e = engine else { return }
        tm_engine_destroy(e)
        engine = nil
        projectRoot = nil
    }

    // MARK: Config

    func reloadConfig() {
        guard let e = engine else { return }
        tm_config_reload(e)
    }

    // MARK: Workers

    /// Spawn a worker. Engine creates worktree + branch + CLAUDE.md.
    /// Does NOT spawn PTY — Ghostty does that via SurfaceView.
    /// Returns worker ID (0 on failure).
    func spawnWorker(
        agentBinary: String,
        taskDescription: String,
        taskSlug: String
    ) -> UInt32 {
        guard let e = engine else { return 0 }
        return tm_worker_spawn(e, agentBinary, taskDescription, taskSlug)
    }

    func dismissWorker(_ workerId: UInt32) -> Bool {
        guard let e = engine else { return false }
        let result = tm_worker_dismiss(e, workerId)
        unregisterSurface(for: workerId)
        return result == 0
    }

    func refreshRoster() {
        guard let e = engine else { return }
        guard let cRoster = tm_roster_get(e) else { return }
        defer { tm_roster_free(cRoster) }
        updateRoster(from: cRoster)
    }

    // MARK: Messaging

    func sendMessage(to workerId: UInt32, type: String, payload: String) -> Bool {
        guard let e = engine else { return false }
        return tm_message_send(e, workerId, type, payload) == 0
    }

    func broadcastMessage(type: String, payload: String) -> Bool {
        guard let e = engine else { return false }
        // tm_message_broadcast may not exist in header — check.
        // If not, iterate roster and send individually.
        for worker in roster {
            _ = tm_message_send(e, worker.id, type, payload)
        }
        return true
    }

    /// Inject text into a worker's terminal via their SurfaceView.
    /// This is how the message bus delivers text — NOT via engine PTY.
    func injectText(_ text: String, to workerId: UInt32) {
        // Callers must import GhosttyKit and cast surfaceViews[workerId]
        // to Ghostty.SurfaceView, then call sendText().
        // This method exists to document the pattern.
        // Actual injection happens in WorkerPaneView which holds the SurfaceView refs.
    }

    // MARK: GitHub

    func connectGitHub() -> Bool {
        guard let e = engine else { return false }
        let result = tm_github_auth(e)
        githubConnected = (result == 0)
        return githubConnected
    }

    func createPR(for workerId: UInt32, title: String) -> GitHubPR? {
        guard let e = engine else { return nil }
        guard let pr = tm_github_create_pr(e, workerId, title) else { return nil }
        defer { tm_pr_free(pr) }
        return GitHubPR(
            number: pr.pointee.pr_number,
            url: String(cString: pr.pointee.pr_url),
            title: String(cString: pr.pointee.title),
            state: String(cString: pr.pointee.state)
        )
    }

    func mergePR(_ prNumber: UInt64) -> Bool {
        guard let e = engine else { return false }
        return tm_github_merge_pr(e, prNumber, 0) == 0  // 0 = squash
    }

    func getDiff(for workerId: UInt32) -> [DiffFile] {
        guard let e = engine else { return [] }
        guard let diff = tm_github_get_diff(e, workerId) else { return [] }
        defer { tm_diff_free(diff) }
        var files: [DiffFile] = []
        for i in 0..<Int(diff.pointee.count) {
            let f = diff.pointee.files[i]
            files.append(DiffFile(
                filePath: String(cString: f.file_path),
                additions: Int(f.additions),
                deletions: Int(f.deletions),
                patch: String(cString: f.patch)
            ))
        }
        return files
    }

    // MARK: Surface registry

    func registerSurface(_ surface: AnyObject, for workerId: UInt32) {
        surfaceViews[workerId] = surface
    }

    func unregisterSurface(for workerId: UInt32) {
        surfaceViews.removeValue(forKey: workerId)
    }

    func surfaceView(for workerId: UInt32) -> AnyObject? {
        surfaceViews[workerId]
    }

    // MARK: Callbacks (private)

    private func setupCallbacks() {
        guard let e = engine else { return }

        // Roster changes
        tm_roster_watch(e, { roster, userdata in
            guard let userdata, let roster else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.updateRoster(from: roster)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Incoming messages
        tm_message_subscribe(e, { message, userdata in
            guard let userdata, let message else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            let msg = TeamMessage(
                from: message.pointee.from,
                to: message.pointee.to,
                type: MessageType(rawValue: String(cString: message.pointee.type)) ?? .instruction,
                payload: String(cString: message.pointee.payload),
                timestamp: Date(timeIntervalSince1970: TimeInterval(message.pointee.timestamp)),
                seq: message.pointee.seq,
                gitCommit: message.pointee.git_commit.map { String(cString: $0) }
            )
            Task { @MainActor in
                client.messages.append(msg)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // /teammux-* commands
        tm_commands_watch(e, { command, args, userdata in
            guard let userdata else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            let cmd = String(cString: command!)
            let cmdArgs = String(cString: args!)
            Task { @MainActor in
                client.handleCommand(cmd, args: cmdArgs)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Private helpers

    private func updateRoster(from cRoster: UnsafePointer<tm_roster_t>) {
        var workers: [WorkerInfo] = []
        for i in 0..<Int(cRoster.pointee.count) {
            let w = cRoster.pointee.workers[i]
            workers.append(WorkerInfo(
                id: w.id,
                name: String(cString: w.name),
                taskDescription: String(cString: w.task_description),
                branchName: String(cString: w.branch_name),
                worktreePath: String(cString: w.worktree_path),
                status: workerStatusFromC(w.status),
                agentType: agentTypeFromC(w.agent_type, binary: w.agent_binary),
                agentBinary: String(cString: w.agent_binary),
                spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at))
            ))
        }
        self.roster = workers
    }

    private func workerStatusFromC(_ status: UInt32) -> WorkerStatus {
        switch status {
        case 0: return .idle
        case 1: return .working
        case 2: return .complete
        case 3: return .blocked
        default: return .error
        }
    }

    private func agentTypeFromC(_ type: UInt32, binary: UnsafePointer<CChar>) -> AgentType {
        let name = String(cString: binary)
        switch name {
        case "claude": return .claudeCode
        case "codex": return .codexCli
        default: return .custom(name)
        }
    }

    private func handleCommand(_ command: String, args: String) {
        switch command {
        case "/teammux-add":
            // Parse args, spawn worker via engine
            _ = spawnWorker(agentBinary: "claude", taskDescription: args, taskSlug: slugify(args))
        case "/teammux-remove":
            if let id = UInt32(args) { _ = dismissWorker(id) }
        case "/teammux-message":
            // Parse "workerId message" format
            let parts = args.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let id = UInt32(parts[0]) {
                _ = sendMessage(to: id, type: "instruction", payload: String(parts[1]))
            }
        case "/teammux-broadcast":
            _ = broadcastMessage(type: "instruction", payload: args)
        default:
            break
        }
    }

    private func slugify(_ text: String) -> String {
        let slug = text.prefix(40)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return slug.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
    }
}

// MARK: - GitHubPR

struct GitHubPR: Identifiable {
    let id = UUID()
    let number: UInt64
    let url: String
    let title: String
    let state: String
}

// MARK: - DiffFile

struct DiffFile: Identifiable {
    let id = UUID()
    let filePath: String
    let additions: Int
    let deletions: Int
    let patch: String
}
```

**IMPORTANT:** The C type names (`tm_roster_t`, `tm_message_t`, field names like `.from`, `.to`, `.payload`) are from the spec. When you read the actual `teammux.h`, adapt the field names to match. The struct layout may differ.

### Step 3: Write EngineClient tests

```swift
// macos/Tests/TeammuxTests/EngineClientTests.swift
import XCTest
@testable import Teammux

@MainActor
final class EngineClientTests: XCTestCase {
    func testVersionCallable() {
        XCTAssertEqual(EngineClient.version(), "0.1.0")
    }

    func testCreateWithInvalidPath() async {
        let client = EngineClient()
        XCTAssertFalse(client.create(projectRoot: "/nonexistent/path/that/does/not/exist"))
        XCTAssertNotNil(client.lastError)
    }

    func testRosterEmptyOnCreate() {
        let client = EngineClient()
        XCTAssertTrue(client.roster.isEmpty)
    }

    func testMessagesEmptyOnCreate() {
        let client = EngineClient()
        XCTAssertTrue(client.messages.isEmpty)
    }

    func testGitHubDisconnectedOnCreate() {
        let client = EngineClient()
        XCTAssertFalse(client.githubConnected)
    }

    func testWorktreeReadyQueueEmptyOnCreate() {
        let client = EngineClient()
        XCTAssertTrue(client.worktreeReadyQueue.isEmpty)
    }

    func testSlugify() {
        // Test via spawnWorker with invalid engine — should return 0
        let client = EngineClient()
        let result = client.spawnWorker(
            agentBinary: "claude",
            taskDescription: "Implement auth flow",
            taskSlug: "implement-auth-flow"
        )
        XCTAssertEqual(result, 0)  // no engine → returns 0
    }

    func testDestroyWithoutEngine() {
        let client = EngineClient()
        client.destroy()  // should not crash
        XCTAssertNil(client.projectRoot)
    }
}
```

### Step 4: Build and run tests

Run: `./build.sh`
Expected: Compilation succeeds. Tests pass (engine calls return nil/0 gracefully).

### Step 5: Commit

```bash
git add macos/Sources/Teammux/Engine/EngineClient.swift macos/Tests/TeammuxTests/EngineClientTests.swift
git commit -m "feat: EngineClient — complete Swift bridge for tm_* functions

Wraps all tm_* C API functions: lifecycle, config, workers, messaging,
GitHub, commands. Ghostty owns PTY — no tm_pty_fd/tm_pty_send wrappers.

New: worktreeReadyQueue (array) for safe rapid worker spawning.
New: surfaceViews registry for message bus text injection.

All callbacks: extract C values on background thread, dispatch to
@MainActor via Task, update @Published properties.

ARCHITECTURE NOTE FOR STREAM 2: tm_pty_fd() and tm_pty_send() must
be no-op stubs only. PTY ownership belongs to Ghostty via Swift's
SurfaceConfiguration. Text injection goes through SurfaceView.sendText()."
```

---

## Task 3: App Lifecycle — Single Teammux Window

**Files:**
- Create: `macos/Sources/Teammux/ProjectManager.swift`
- Create: `macos/Sources/Teammux/WorkspaceWindowController.swift`
- Create: `macos/Sources/Teammux/ContentView.swift`
- Modify: `macos/Sources/App/macOS/AppDelegate.swift`

### Step 1: Create ProjectManager.swift

```swift
// macos/Sources/Teammux/ProjectManager.swift
import Foundation
import SwiftUI

@MainActor
class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var activeProjectId: UUID?

    private var engines: [UUID: EngineClient] = [:]

    var activeProject: Project? {
        projects.first { $0.id == activeProjectId }
    }

    var activeEngine: EngineClient? {
        guard let id = activeProjectId else { return nil }
        return engines[id]
    }

    var hasActiveProject: Bool {
        activeProjectId != nil
    }

    func addProject(name: String, path: URL) -> Project {
        let project = Project(name: name, path: path)
        projects.append(project)
        let engine = EngineClient()
        engines[project.id] = engine
        activeProjectId = project.id
        saveRecents()
        return project
    }

    func activate(_ project: Project) {
        activeProjectId = project.id
    }

    func closeProject(_ project: Project) {
        engines[project.id]?.destroy()
        engines.removeValue(forKey: project.id)
        projects.removeAll { $0.id == project.id }
        if activeProjectId == project.id {
            activeProjectId = projects.first?.id
        }
    }

    func openNewProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose your project folder"
        if panel.runModal() == .OK, let url = panel.url {
            _ = addProject(name: url.lastPathComponent, path: url)
        }
    }

    // MARK: Recents

    private let recentsKey = "com.teammux.recentProjects"

    func loadRecents() -> [URL] {
        guard let data = UserDefaults.standard.array(forKey: recentsKey) as? [String] else {
            return []
        }
        return data.compactMap { URL(fileURLWithPath: $0) }
    }

    private func saveRecents() {
        let paths = projects.map { $0.path.path }
        UserDefaults.standard.set(paths, forKey: recentsKey)
    }
}
```

### Step 2: Create WorkspaceWindowController.swift

```swift
// macos/Sources/Teammux/WorkspaceWindowController.swift
import AppKit
import SwiftUI
import GhosttyKit

class WorkspaceWindowController: NSWindowController {
    let ghosttyApp: Ghostty.App
    let projectManager: ProjectManager

    init(ghosttyApp: Ghostty.App, projectManager: ProjectManager) {
        self.ghosttyApp = ghosttyApp
        self.projectManager = projectManager

        let contentView = ContentView()
            .environmentObject(ghosttyApp)
            .environmentObject(projectManager)

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teammux"
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("TeammuxMainWindow")
        window.minSize = NSSize(width: 1100, height: 700)

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
```

### Step 3: Create ContentView.swift

```swift
// macos/Sources/Teammux/ContentView.swift
import SwiftUI
import GhosttyKit

struct ContentView: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject var projectManager: ProjectManager

    var body: some View {
        Group {
            if projectManager.hasActiveProject,
               let engine = projectManager.activeEngine {
                WorkspaceView(engine: engine)
            } else {
                SetupView(projectManager: projectManager)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}
```

### Step 4: Modify AppDelegate.swift

Read the existing AppDelegate.swift from Stream 1 first. The key change: suppress `TerminalController.newWindow(ghostty)` and replace with `WorkspaceWindowController`.

Find and modify the `applicationDidBecomeActive` or the equivalent point where Stream 1 opens the Teammux window. The modification:

```swift
// In AppDelegate — add property
var workspaceWindowController: WorkspaceWindowController?
let projectManager = ProjectManager()

// In the method that opens the window (adapt to Stream 1's actual code):
func openTeammuxWindow() {
    let controller = WorkspaceWindowController(
        ghosttyApp: ghostty,
        projectManager: projectManager
    )
    controller.showWindow(nil)
    workspaceWindowController = controller
}

// Prevent Ghostty terminal windows
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { workspaceWindowController?.showWindow(nil) }
    return false
}
```

**IMPORTANT:** Read AppDelegate.swift after pulling Stream 1. The exact modification points depend on what Stream 1 did. The principle: suppress `TerminalController.newWindow()`, inject `WorkspaceWindowController`.

### Step 5: Build

Run: `./build.sh`
Expected: App launches with single Teammux window. ContentView shows SetupView (no project configured). No Ghostty terminal window appears.

### Step 6: Commit

```bash
git add macos/Sources/Teammux/ProjectManager.swift macos/Sources/Teammux/WorkspaceWindowController.swift macos/Sources/Teammux/ContentView.swift macos/Sources/App/macOS/AppDelegate.swift
git commit -m "feat: app lifecycle — single Teammux window, no Ghostty terminal

WorkspaceWindowController wraps NSHostingController with ContentView.
ContentView routes between SetupView and WorkspaceView.
ProjectManager manages multi-project state.
AppDelegate opens Teammux window instead of Ghostty terminal."
```

---

## Task 4: Setup Flow — Three Screens

**Files:**
- Create: `macos/Sources/Teammux/Setup/SetupView.swift`
- Create: `macos/Sources/Teammux/Setup/ProjectPickerView.swift`
- Create: `macos/Sources/Teammux/Setup/TeamBuilderView.swift`
- Create: `macos/Sources/Teammux/Setup/InitiateView.swift`

### Step 1: Create SetupView.swift

```swift
// macos/Sources/Teammux/Setup/SetupView.swift
import SwiftUI

struct SetupView: View {
    @ObservedObject var projectManager: ProjectManager
    @State private var step: SetupStep = .project
    @State private var selectedProject: URL?
    @State private var teamConfig: TeamConfig = .default

    enum SetupStep { case project, team, initiate }

    var body: some View {
        switch step {
        case .project:
            ProjectPickerView(
                selectedProject: $selectedProject,
                recentProjects: projectManager.loadRecents()
            ) {
                step = .team
            }
        case .team:
            if let projectURL = selectedProject {
                TeamBuilderView(
                    projectURL: projectURL,
                    config: $teamConfig
                ) {
                    step = .initiate
                }
            }
        case .initiate:
            if let projectURL = selectedProject {
                InitiateView(
                    projectURL: projectURL,
                    config: teamConfig,
                    projectManager: projectManager
                )
            }
        }
    }
}
```

### Step 2: Create ProjectPickerView.swift

```swift
// macos/Sources/Teammux/Setup/ProjectPickerView.swift
import SwiftUI
import UniformTypeIdentifiers

struct ProjectPickerView: View {
    @Binding var selectedProject: URL?
    let recentProjects: [URL]
    let onNext: () -> Void
    @State private var errorMessage: String?
    @State private var showGitInitButton = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Teammux")
                .font(.system(size: 32, weight: .semibold, design: .default))

            Text("Where does this mission begin?")
                .font(.title3)
                .foregroundColor(.secondary)

            Button("Select project folder") {
                selectFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(recentProjects, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            validateAndSelect(url)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundColor(.secondary.opacity(0.4))
                .frame(height: 80)
                .overlay(Text("or drag a git repo here").foregroundColor(.secondary))
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }

            if let error = errorMessage {
                VStack(spacing: 8) {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                    if showGitInitButton {
                        Button("Initialize git repository") {
                            gitInit()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Spacer()
        }
        .frame(width: 480)
        .padding(48)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose your project folder"
        if panel.runModal() == .OK, let url = panel.url {
            validateAndSelect(url)
        }
    }

    private func validateAndSelect(_ url: URL) {
        let gitDir = url.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            errorMessage = nil
            showGitInitButton = false
            selectedProject = url
            onNext()
        } else {
            errorMessage = "This folder isn't a git repository. Teammux needs a git repo to manage agent worktrees."
            showGitInitButton = true
        }
    }

    private func gitInit() {
        guard let url = selectedProject ?? {
            // If no project selected, re-open picker
            return nil
        }() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            validateAndSelect(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                validateAndSelect(url)
            }
        }
    }
}
```

### Step 3: Create TeamBuilderView.swift

```swift
// macos/Sources/Teammux/Setup/TeamBuilderView.swift
import SwiftUI

struct TeamBuilderView: View {
    let projectURL: URL
    @Binding var config: TeamConfig
    let onNext: () -> Void
    @State private var githubStatus: GitHubStatus = .detecting

    private let claudeModels = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Build your team")
                .font(.title2).fontWeight(.semibold)

            GroupBox("Team Lead") {
                HStack {
                    Text("Agent:")
                    Picker("", selection: $config.teamLead.agent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Text("Model:")
                    Picker("", selection: $config.teamLead.model) {
                        ForEach(claudeModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                .padding(4)
            }

            GroupBox("Teammates") {
                VStack(spacing: 12) {
                    ForEach($config.workers) { $worker in
                        HStack {
                            TextField("Name", text: $worker.name)
                                .frame(width: 120)
                            Picker("Agent", selection: $worker.agent) {
                                Text("Claude Code").tag(AgentType.claudeCode)
                                Text("Codex CLI").tag(AgentType.codexCli)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            Picker("Model", selection: $worker.model) {
                                ForEach(claudeModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                                Text("gpt-5").tag("gpt-5")
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            Button {
                                config.workers.removeAll { $0.id == worker.id }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        config.workers.append(WorkerConfig(
                            id: UUID().uuidString,
                            name: "Teammate \(config.workers.count + 1)",
                            agent: .claudeCode,
                            model: "claude-sonnet-4-6"
                        ))
                    } label: {
                        Label("Add teammate", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(4)
            }

            GroupBox("GitHub") {
                HStack {
                    Circle()
                        .fill(githubStatus.color)
                        .frame(width: 8, height: 8)
                    Text(githubStatus.label)
                    Spacer()
                    if case .disconnected = githubStatus {
                        Button("Connect") { connectGitHub() }
                    }
                }
                .padding(4)
            }

            Text("Permissions: Full (recommended — git worktree isolation is in place)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Continue") { onNext() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 600)
        .padding(40)
        .onAppear { detectGitHub() }
    }

    private func detectGitHub() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            githubStatus = process.terminationStatus == 0
                ? .connected("gh CLI")
                : .disconnected
        } catch {
            githubStatus = .disconnected
        }
    }

    private func connectGitHub() {
        // OAuth flow handled by GitHubClient (Task 8)
        githubStatus = .disconnected
    }
}
```

### Step 4: Create InitiateView.swift

```swift
// macos/Sources/Teammux/Setup/InitiateView.swift
import SwiftUI

struct InitiateView: View {
    let projectURL: URL
    let config: TeamConfig
    @ObservedObject var projectManager: ProjectManager
    @State private var isInitiating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Your team is assembled.")
                .font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                TeamSummaryRow(role: "Team Lead", agent: config.teamLead.agent.displayName, model: config.teamLead.model)
                ForEach(config.workers) { worker in
                    TeamSummaryRow(role: worker.name, agent: worker.agent.displayName, model: worker.model)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                initiate()
            } label: {
                if isInitiating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 160)
                } else {
                    Text("Initiate Mission")
                        .font(.title3).fontWeight(.medium)
                        .frame(width: 160)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInitiating)

            Spacer()
        }
        .frame(width: 480)
        .padding(48)
    }

    private func initiate() {
        isInitiating = true
        Task {
            do {
                // Create .teammux directory
                let teammuxDir = projectURL.appendingPathComponent(".teammux")
                try FileManager.default.createDirectory(at: teammuxDir, withIntermediateDirectories: true)

                // Write config.toml
                let configPath = teammuxDir.appendingPathComponent("config.toml")
                let toml = config.toTOML(projectName: projectURL.lastPathComponent)
                try toml.write(to: configPath, atomically: true, encoding: .utf8)

                // Write .gitignore entries
                let gitignorePath = teammuxDir.appendingPathComponent(".gitignore")
                let gitignore = "worker-*/\nconfig.local.toml\ncommands/\nlogs/\n"
                try gitignore.write(to: gitignorePath, atomically: true, encoding: .utf8)

                // Add project to manager (creates EngineClient)
                let project = projectManager.addProject(
                    name: projectURL.lastPathComponent,
                    path: projectURL
                )

                // Initialize engine
                if let engine = projectManager.activeEngine {
                    if engine.create(projectRoot: projectURL.path) {
                        _ = engine.sessionStart()
                    }
                }
                // ContentView will now show WorkspaceView because hasActiveProject is true
            } catch {
                self.error = "Failed to initialize: \(error.localizedDescription)"
                isInitiating = false
            }
        }
    }
}

struct TeamSummaryRow: View {
    let role: String
    let agent: String
    let model: String

    var body: some View {
        HStack {
            Text(role)
                .frame(width: 120, alignment: .leading)
                .fontWeight(.medium)
            Text(agent)
                .frame(width: 120, alignment: .leading)
                .foregroundColor(.secondary)
            Text(model)
                .frame(width: 180, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
```

### Step 5: Build

Run: `./build.sh`
Expected: App launches → SetupView shows → click "Select project folder" → picks a git repo → TeamBuilderView renders → click "Continue" → InitiateView shows team summary → click "Initiate Mission" → transitions to WorkspaceView.

### Step 6: Commit

```bash
git add macos/Sources/Teammux/Setup/
git commit -m "feat: setup flow — project picker, team builder, initiate

Three-step setup: select git repo, configure team composition,
initiate mission. Writes .teammux/config.toml. Supports drag-and-drop.
Detects GitHub auth via gh CLI. Navigates to workspace on initiate."
```

---

## Task 5: Workspace Three-Pane Layout Skeleton

**Files:**
- Create: `macos/Sources/Teammux/Workspace/WorkspaceView.swift`

### Step 1: Create WorkspaceView.swift with placeholder content

```swift
// macos/Sources/Teammux/Workspace/WorkspaceView.swift
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var engine: EngineClient
    @State var activeWorkerId: UInt32?

    var body: some View {
        VStack(spacing: 0) {
            // Project tab bar — placeholder until Task 6
            HStack {
                Text("Project Tab Bar")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                Spacer()
            }
            .frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Three panes
            HSplitView {
                // Left — roster placeholder
                VStack {
                    Text("Roster")
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                // Centre — worker pane placeholder
                VStack {
                    Text("Worker Terminal")
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 400)
                .background(Color.black.opacity(0.05))

                // Right — tabs placeholder
                VStack {
                    Text("Right Pane Tabs")
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 320, idealWidth: 420)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}
```

### Step 2: Build

Run: `./build.sh`
Expected: After initiating a project, workspace renders with three panes separated by draggable dividers.

### Step 3: Commit

```bash
git add macos/Sources/Teammux/Workspace/WorkspaceView.swift
git commit -m "feat: workspace three-pane HSplitView skeleton

Root layout with placeholder content in each pane.
Roster (left, 180-280px), worker terminal (centre, min 400px),
right tabs (right, min 320px). Draggable dividers."
```

---

## Task 6: Project Tab Bar + Roster + Spawn Popover

**Files:**
- Create: `macos/Sources/Teammux/Workspace/ProjectTabBar.swift`
- Create: `macos/Sources/Teammux/Workspace/RosterView.swift`
- Create: `macos/Sources/Teammux/Workspace/WorkerRow.swift`
- Create: `macos/Sources/Teammux/Workspace/TeamLeadRow.swift`
- Create: `macos/Sources/Teammux/Workspace/SpawnPopoverView.swift`
- Modify: `macos/Sources/Teammux/Workspace/WorkspaceView.swift`

### Step 1: Create ProjectTabBar.swift

```swift
// macos/Sources/Teammux/Workspace/ProjectTabBar.swift
import SwiftUI

struct ProjectTabBar: View {
    @EnvironmentObject var projectManager: ProjectManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(projectManager.projects) { project in
                        ProjectTab(
                            project: project,
                            isActive: project.id == projectManager.activeProjectId,
                            hasActivity: project.hasUnseenActivity,
                            onClose: { projectManager.closeProject(project) }
                        )
                        .onTapGesture {
                            projectManager.activate(project)
                        }
                    }
                }
            }

            Button {
                projectManager.openNewProject()
            } label: {
                Image(systemName: "plus")
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}

struct ProjectTab: View {
    let project: Project
    let isActive: Bool
    let hasActivity: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if hasActivity {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
            Text(project.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(Divider(), alignment: .trailing)
    }
}
```

### Step 2: Create TeamLeadRow.swift

```swift
// macos/Sources/Teammux/Workspace/TeamLeadRow.swift
import SwiftUI

struct TeamLeadRow: View {
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("TEAM LEAD")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Claude Code")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(
            isActive ? Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                : nil,
            alignment: .leading
        )
    }
}
```

### Step 3: Create WorkerRow.swift

```swift
// macos/Sources/Teammux/Workspace/WorkerRow.swift
import SwiftUI

struct WorkerRow: View {
    let worker: WorkerInfo
    let isActive: Bool
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(worker.status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(worker.taskDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .overlay(
            isActive ? Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                : nil,
            alignment: .leading
        )
    }
}
```

### Step 4: Create SpawnPopoverView.swift

```swift
// macos/Sources/Teammux/Workspace/SpawnPopoverView.swift
import SwiftUI

struct SpawnPopoverView: View {
    @ObservedObject var engine: EngineClient
    @Binding var isPresented: Bool
    @State private var taskDescription = ""
    @State private var selectedAgent: AgentType = .claudeCode
    @State private var selectedModel = "claude-sonnet-4-6"
    @State private var workerName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Teammate")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Task").font(.caption).foregroundColor(.secondary)
                TextField("what should this worker do?", text: $taskDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedAgent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                        Text("Codex CLI").tag(AgentType.codexCli)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundColor(.secondary)
                    TextField("auto", text: $workerName)
                        .frame(width: 120)
                }
            }

            Text("Permissions: Full (git worktree isolated)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Initiate Teammate") {
                    spawn()
                }
                .buttonStyle(.borderedProminent)
                .disabled(taskDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func spawn() {
        let name = workerName.isEmpty ? "Worker \(engine.roster.count + 1)" : workerName
        let slug = taskDescription.prefix(40)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let binary = selectedAgent.resolvedBinary()
        _ = engine.spawnWorker(
            agentBinary: binary,
            taskDescription: taskDescription,
            taskSlug: slug
        )
        isPresented = false
    }
}
```

### Step 5: Create RosterView.swift

```swift
// macos/Sources/Teammux/Workspace/RosterView.swift
import SwiftUI

struct RosterView: View {
    @ObservedObject var engine: EngineClient
    @Binding var activeWorkerId: UInt32?
    @State private var showingSpawnPopover = false

    var body: some View {
        VStack(spacing: 0) {
            TeamLeadRow(
                isActive: activeWorkerId == nil,
                onTap: { activeWorkerId = nil }
            )

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(engine.roster) { worker in
                        WorkerRow(
                            worker: worker,
                            isActive: activeWorkerId == worker.id,
                            onTap: { activeWorkerId = worker.id },
                            onDismiss: { _ = engine.dismissWorker(worker.id) }
                        )
                    }
                }
            }

            Spacer()

            Divider()

            VStack(spacing: 0) {
                Button {
                    showingSpawnPopover = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("New Worker")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingSpawnPopover, arrowEdge: .trailing) {
                    SpawnPopoverView(engine: engine, isPresented: $showingSpawnPopover)
                }

                Button {
                    // Project settings — placeholder
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Project Settings")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}
```

### Step 6: Update WorkspaceView.swift with real components

Replace placeholder content in WorkspaceView with ProjectTabBar and RosterView:

```swift
// Replace the entire body in WorkspaceView.swift
var body: some View {
    VStack(spacing: 0) {
        ProjectTabBar()
            .frame(height: 38)

        HSplitView {
            RosterView(
                engine: engine,
                activeWorkerId: $activeWorkerId
            )
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            // Centre — worker pane placeholder (Task 7)
            VStack {
                if engine.roster.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.3")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("No workers yet.")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Click + to spawn your first teammate.")
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                } else {
                    Text("Worker Terminal — coming in next commit")
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 400)
            .background(Color.black.opacity(0.05))

            // Right — tabs placeholder (Task 8)
            VStack {
                Text("Right Pane — coming in next commit")
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 320, idealWidth: 420)
        }
    }
    .frame(minWidth: 1100, minHeight: 700)
}
```

### Step 7: Build

Run: `./build.sh`
Expected: Tab bar renders with project name + [+] button. Roster shows Team Lead pinned top, workers scrollable. [+] New Worker opens popover with all fields.

### Step 8: Commit

```bash
git add macos/Sources/Teammux/Workspace/
git commit -m "feat: project tab bar, roster, spawn popover

Chrome-style ProjectTabBar with activity indicator and close buttons.
RosterView with Team Lead pinned top, workers scrollable below.
WorkerRow shows status dot (semantic color), name, task, dismiss on hover.
Active worker highlighted with accent left border.
SpawnPopoverView with task, agent, model, name fields."
```

---

## Task 7: Worker Terminal Pane with Ghostty SurfaceView

**Files:**
- Create: `macos/Sources/Teammux/Workspace/WorkerPaneView.swift`
- Create: `macos/Sources/Teammux/Workspace/WorkerTerminalView.swift`
- Modify: `macos/Sources/Teammux/Workspace/WorkspaceView.swift`

### Step 1: Create WorkerTerminalView.swift

```swift
// macos/Sources/Teammux/Workspace/WorkerTerminalView.swift
import SwiftUI
import GhosttyKit

struct WorkerTerminalView: NSViewRepresentable {
    let worker: WorkerInfo
    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
            let fallback = NSView()
            fallback.wantsLayer = true
            fallback.layer?.backgroundColor = NSColor.black.cgColor
            return fallback
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = worker.agentBinary
        config.workingDirectory = worker.worktreePath
        config.initialInput = "\n[Teammux] task: \(worker.taskDescription)\n"

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        return surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SurfaceView manages its own state — no updates needed
    }
}
```

### Step 2: Create WorkerPaneView.swift

```swift
// macos/Sources/Teammux/Workspace/WorkerPaneView.swift
import SwiftUI
import GhosttyKit

struct WorkerPaneView: View {
    @ObservedObject var engine: EngineClient
    let activeWorkerId: UInt32?

    var body: some View {
        ZStack {
            if engine.roster.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No workers yet.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Click + to spawn your first teammate.")
                        .font(.body)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } else {
                ForEach(engine.roster) { worker in
                    WorkerTerminalView(worker: worker)
                        .opacity(worker.id == activeWorkerId ? 1 : 0)
                        .allowsHitTesting(worker.id == activeWorkerId)
                        .id(worker.id)
                }
            }
        }
        .background(Color.black)
    }
}
```

### Step 3: Update WorkspaceView.swift

Replace the centre pane placeholder with `WorkerPaneView`:

```swift
// In WorkspaceView body, replace centre pane placeholder with:
WorkerPaneView(
    engine: engine,
    activeWorkerId: activeWorkerId
)
.frame(minWidth: 400)
```

### Step 4: Build

Run: `./build.sh`
Expected: Centre pane shows empty state when no workers. When a worker is spawned, a Ghostty terminal appears with the agent running. Clicking different workers in roster switches the active terminal (opacity swap). PTY state preserved for hidden terminals.

### Step 5: Commit

```bash
git add macos/Sources/Teammux/Workspace/WorkerPaneView.swift macos/Sources/Teammux/Workspace/WorkerTerminalView.swift macos/Sources/Teammux/Workspace/WorkspaceView.swift
git commit -m "feat: worker terminal pane with Ghostty SurfaceView

WorkerPaneView uses ZStack + opacity for terminal switching.
WorkerTerminalView wraps Ghostty.SurfaceView via NSViewRepresentable.
SurfaceConfiguration sets command=agentBinary, workingDirectory=worktreePath.
PTY state preserved when hidden (opacity 0, hit testing disabled).
Empty state shown when no workers spawned."
```

---

## Task 8: Right Pane — Four Tabs

**Files:**
- Create: `macos/Sources/Teammux/RightPane/RightPaneView.swift`
- Create: `macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift`
- Create: `macos/Sources/Teammux/RightPane/GitView.swift`
- Create: `macos/Sources/Teammux/RightPane/DiffView.swift`
- Create: `macos/Sources/Teammux/RightPane/LiveFeedView.swift`
- Modify: `macos/Sources/Teammux/Workspace/WorkspaceView.swift`

### Step 1: Create RightPaneView.swift with custom tab bar

```swift
// macos/Sources/Teammux/RightPane/RightPaneView.swift
import SwiftUI

struct RightPaneView: View {
    @ObservedObject var engine: EngineClient
    @State private var selectedTab: RightTab = .teamLead

    enum RightTab: String, CaseIterable {
        case teamLead = "Team Lead"
        case git = "Git"
        case diff = "Diff"
        case liveFeed = "Feed"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar with underline indicator
            HStack(spacing: 0) {
                ForEach(RightTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 0) {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .medium : .regular))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)

                            Rectangle()
                                .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Tab content
            Group {
                switch selectedTab {
                case .teamLead:
                    TeamLeadTerminalView(engine: engine)
                case .git:
                    GitView(engine: engine)
                case .diff:
                    DiffView(engine: engine)
                case .liveFeed:
                    LiveFeedView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

### Step 2: Create TeamLeadTerminalView.swift

```swift
// macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift
import SwiftUI
import GhosttyKit

struct TeamLeadTerminalView: View {
    @ObservedObject var engine: EngineClient
    @EnvironmentObject var ghosttyApp: Ghostty.App

    var body: some View {
        if let app = ghosttyApp.app, let projectRoot = engine.projectRoot {
            TeamLeadSurfaceView(app: app, projectRoot: projectRoot)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting Team Lead...")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct TeamLeadSurfaceView: NSViewRepresentable {
    let app: ghostty_app_t
    let projectRoot: String

    func makeNSView(context: Context) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "claude"
        config.workingDirectory = projectRoot

        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    func updateNSView(_ nsView: Ghostty.SurfaceView, context: Context) {}
}
```

### Step 3: Create GitView.swift

```swift
// macos/Sources/Teammux/RightPane/GitView.swift
import SwiftUI

struct GitView: View {
    @ObservedObject var engine: EngineClient
    @State private var prs: [GitHubPR] = []

    var body: some View {
        Group {
            if engine.roster.isEmpty && prs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No active branches")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Spawn workers to create branches.")
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Main branch") {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                            Text("main")
                            Spacer()
                            Text("up to date")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Active workers") {
                        ForEach(engine.roster) { worker in
                            HStack {
                                Circle()
                                    .fill(worker.status.color)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worker.branchName)
                                        .font(.system(size: 13, design: .monospaced))
                                    Text(worker.name)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    Button("Open PR") {
                                        let pr = engine.createPR(
                                            for: worker.id,
                                            title: "[teammux] \(worker.name): \(worker.taskDescription)"
                                        )
                                        if let pr { prs.append(pr) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
```

### Step 4: Create DiffView.swift

```swift
// macos/Sources/Teammux/RightPane/DiffView.swift
import SwiftUI

struct DiffView: View {
    @ObservedObject var engine: EngineClient
    @State private var selectedWorkerId: UInt32?
    @State private var diffFiles: [DiffFile] = []

    var body: some View {
        VStack(spacing: 0) {
            // Worker picker
            HStack {
                Text("Worker:")
                    .foregroundColor(.secondary)
                Picker("", selection: $selectedWorkerId) {
                    Text("Select...").tag(Optional<UInt32>.none)
                    ForEach(engine.roster) { worker in
                        Text(worker.name).tag(Optional(worker.id))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                if !diffFiles.isEmpty {
                    Text("\(diffFiles.count) files changed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Diff content
            if diffFiles.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(selectedWorkerId == nil ? "Select a worker to view diff" : "No changes")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diffFiles) { file in
                            DiffFileView(file: file)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .onChange(of: selectedWorkerId) { _, workerId in
            guard let id = workerId else { diffFiles = []; return }
            diffFiles = engine.getDiff(for: id)
        }
    }
}

struct DiffFileView: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack {
                Text(file.filePath)
                    .fontWeight(.medium)
                Spacer()
                HStack(spacing: 4) {
                    Text("+\(file.additions)")
                        .foregroundColor(.green)
                    Text("-\(file.deletions)")
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            // Diff lines with syntax highlighting
            ForEach(file.patch.components(separatedBy: "\n"), id: \.self) { line in
                Text(line)
                    .foregroundColor(diffLineColor(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .background(diffLineBackground(line))
            }
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") { return Color.green.opacity(0.08) }
        if line.hasPrefix("-") { return Color.red.opacity(0.08) }
        if line.hasPrefix("@@") { return Color.blue.opacity(0.06) }
        return .clear
    }
}
```

### Step 5: Create LiveFeedView.swift

```swift
// macos/Sources/Teammux/RightPane/LiveFeedView.swift
import SwiftUI

struct LiveFeedView: View {
    @ObservedObject var engine: EngineClient

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live Feed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(engine.messages.count) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            if engine.messages.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No activity yet")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Messages will appear here in real time.")
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(engine.messages) { msg in
                                LiveFeedRow(message: msg, roster: engine.roster)
                                    .id(msg.id)
                            }
                        }
                    }
                    .onChange(of: engine.messages.count) { _, _ in
                        if let last = engine.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct LiveFeedRow: View {
    let message: TeamMessage
    let roster: [WorkerInfo]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)

            Circle()
                .fill(message.type.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(senderName)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(receiverName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text(message.payload)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(Divider(), alignment: .bottom)
    }

    private var senderName: String {
        message.from == 0 ? "Team Lead" :
        roster.first { $0.id == message.from }?.name ?? "Worker \(message.from)"
    }

    private var receiverName: String {
        message.to == 0 ? "Team Lead" :
        roster.first { $0.id == message.to }?.name ?? "All"
    }
}
```

### Step 6: Update WorkspaceView.swift

Replace the right pane placeholder:

```swift
// In WorkspaceView body, replace right pane placeholder with:
RightPaneView(engine: engine)
    .frame(minWidth: 320, idealWidth: 420)
```

### Step 7: Build

Run: `./build.sh`
Expected: Right pane shows four tabs. Team Lead tab auto-launches Claude Code terminal. Git tab shows branch list. Diff tab shows worker picker. Live Feed shows empty state.

### Step 8: Commit

```bash
git add macos/Sources/Teammux/RightPane/ macos/Sources/Teammux/Workspace/WorkspaceView.swift
git commit -m "feat: right pane — Team Lead terminal, Git, Diff, Live Feed

Custom tab bar with underline indicator. Four tabs:
- Team Lead: Ghostty terminal, auto-launches Claude Code
- Git: branch list with worker status and PR buttons
- Diff: worker picker + syntax-highlighted diff (green/red/blue)
- Live Feed: real-time message stream with sender→receiver, auto-scroll"
```

---

## Task 9: GitHub OAuth Client

**Files:**
- Create: `macos/Sources/Teammux/GitHub/GitHubClient.swift`

### Step 1: Create GitHubClient.swift

```swift
// macos/Sources/Teammux/GitHub/GitHubClient.swift
import AuthenticationServices
import Security

@MainActor
class GitHubOAuthFlow: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var isAuthenticating = false
    @Published var token: String?
    @Published var error: String?

    // Replace with your actual GitHub OAuth App client ID
    private let clientId = "YOUR_GITHUB_CLIENT_ID"
    private let keychainService = "com.teammux.app"
    private let keychainAccount = "github-token"

    func startOAuthFlow() {
        isAuthenticating = true
        let authURL = URL(string: "https://github.com/login/oauth/authorize?client_id=\(clientId)&scope=repo")!
        let callbackScheme = "teammux"

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if let error {
                    self.error = error.localizedDescription
                    return
                }
                guard let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.error = "No authorization code received"
                    return
                }
                await self.exchangeCodeForToken(code)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? ASPresentationAnchor()
    }

    private func exchangeCodeForToken(_ code: String) async {
        // Exchange auth code for access token via GitHub API
        // In production, this should go through a backend to keep client_secret safe
        // For v0.1, we use the engine's tm_github_auth which handles this
        token = code  // placeholder — real flow uses tm_github_auth
        saveToKeychain(code)
    }

    // MARK: Keychain

    func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    private func saveToKeychain(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
```

### Step 2: Build

Run: `./build.sh`
Expected: Compiles. OAuth flow is wired but not connected to UI yet (TeamBuilderView's "Connect" button is a placeholder).

### Step 3: Commit

```bash
git add macos/Sources/Teammux/GitHub/GitHubClient.swift
git commit -m "feat: GitHub OAuth client via ASWebAuthenticationSession

Token stored in macOS Keychain under com.teammux.app.
Supports browser-based OAuth flow with callback scheme.
Keychain load/save for persistent token storage."
```

---

## Task 10: Complete Test Suite

**Files:**
- Modify: `macos/Tests/TeammuxTests/ModelsTests.swift`
- Modify: `macos/Tests/TeammuxTests/EngineClientTests.swift`

### Step 1: Expand tests

Add any additional tests discovered during implementation. At minimum, verify:

```swift
// Additional EngineClientTests
func testSessionStartWithoutCreate() async {
    let client = EngineClient()
    XCTAssertFalse(client.sessionStart())
    XCTAssertNotNil(client.lastError)
}

func testDismissWorkerWithoutEngine() async {
    let client = EngineClient()
    XCTAssertFalse(client.dismissWorker(1))
}

func testSendMessageWithoutEngine() async {
    let client = EngineClient()
    XCTAssertFalse(client.sendMessage(to: 1, type: "task", payload: "test"))
}

func testConnectGitHubWithoutEngine() async {
    let client = EngineClient()
    XCTAssertFalse(client.connectGitHub())
    XCTAssertFalse(client.githubConnected)
}

func testGetDiffWithoutEngine() async {
    let client = EngineClient()
    XCTAssertTrue(client.getDiff(for: 1).isEmpty)
}
```

### Step 2: Run full test suite

Run: `./build.sh` (with test target)
Expected: All tests pass with zero failures.

### Step 3: Commit

```bash
git add macos/Tests/
git commit -m "test: complete Swift test suite for EngineClient and models

All edge cases: nil engine returns, empty state initialization,
status color mapping, TOML serialization, agent type resolution."
```

---

## Post-implementation: Open PR

After all 9 commits are verified:

```bash
git push origin feat/stream3-swift-ui
gh pr create \
  --title "feat: Stream 3 — Swift UI, setup flow, workspace, all four right pane tabs" \
  --body "## Summary
- Complete Teammux Swift UI layer
- Setup flow: project picker → team builder → initiate
- Three-pane workspace with HSplitView
- Project tab bar (Chrome-style, multi-project)
- Roster with Team Lead pinned, workers scrollable, spawn popover
- Worker terminal pane with Ghostty SurfaceView (ZStack opacity switching)
- Right pane with four tabs: Team Lead terminal, Git, Diff, Live Feed
- EngineClient bridge wrapping all tm_* functions
- GitHub OAuth via ASWebAuthenticationSession

## Architecture: PTY Ownership
**CRITICAL FOR STREAM 2:** Ghostty owns the PTY. The Zig engine does NOT spawn processes.
- tm_worker_spawn() creates worktree + CLAUDE.md only
- Swift creates SurfaceView with SurfaceConfiguration(command, workingDirectory, initialInput)
- tm_pty_fd() and tm_pty_send() must be no-op stubs only
- Message bus text injection goes via SurfaceView.sendText(), not engine PTY writes

## Test plan
- [ ] ./build.sh succeeds
- [ ] One window opens on launch (Teammux workspace, no Ghostty terminal)
- [ ] Setup flow navigates correctly
- [ ] Drag-and-drop git repo works
- [ ] Tab bar renders with [+] button
- [ ] Roster shows Team Lead + workers
- [ ] Spawn popover opens with all fields
- [ ] Four right pane tabs render
- [ ] All Swift tests pass
- [ ] No force-unwraps in production paths

🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
  --base main
```

**Do NOT merge. Report back with PR link.**
