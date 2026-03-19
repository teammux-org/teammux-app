# Teammux v0.1 — Stream 3: Swift UI

**Branch:** `feat/stream3-swift-ui`  
**Merges into:** `main`  
**Merge order:** THIRD — after Stream 1 and Stream 2  
**Dependencies:** Both Stream 1 (header bridge) and Stream 2 (libteammux.a) must be merged first.

---

## Your mission

Build the entire Teammux user interface. Every screen, every pane, every tab. Swift and SwiftUI throughout — native macOS, no web views, no compromises.

You are building against `engine/include/teammux.h` via `EngineClient.swift`. Every interaction with the engine goes through that bridge. No direct `tm_*` calls outside `EngineClient.swift`.

The UI must feel like a professional macOS tool from day one. Study how Conductor, Warp, and Linear handle their interfaces — clean, purposeful, no clutter.

---

## Step 0 — Read first

```bash
git pull origin main                      # get Stream 1 + 2 output
cat engine/include/teammux.h              # every function you can call
cat CLAUDE.md                             # project context
cat macos/Sources/Teammux/Engine/EngineClient.swift  # the bridge you extend
```

The `EngineClient.swift` stub from Stream 1 only has `version()`. You will extend it to wrap every `tm_*` function.

---

## Step 1 — `EngineClient.swift` — complete Swift bridge

This is the only file that calls `tm_*` functions directly. Everything else in the Swift layer calls `EngineClient`.

```swift
import Foundation
import Combine

// MARK: - Swift types mirroring C structs

struct WorkerInfo: Identifiable {
    let id: UInt32
    let name: String
    let taskDescription: String
    let branchName: String
    let worktreePath: String
    var status: WorkerStatus
    let agentType: AgentType
    let agentBinary: String
    let spawnedAt: Date
}

enum WorkerStatus {
    case idle, working, complete, blocked, error
}

enum AgentType {
    case claudeCode, codexCli, custom(String)
}

struct TeamMessage: Identifiable {
    let id = UUID()
    let from: UInt32
    let to: UInt32
    let type: MessageType
    let payload: String
    let timestamp: Date
    let seq: UInt64
    let gitCommit: String?
}

enum MessageType {
    case task, instruction, context
    case statusReq, statusRpt, completion, error, broadcast
}

struct GitHubPR {
    let number: UInt64
    let url: String
    let title: String
    let state: String
}

struct DiffFile: Identifiable {
    let id = UUID()
    let filePath: String
    let additions: Int
    let deletions: Int
    let patch: String
}

// MARK: - EngineClient

@MainActor
class EngineClient: ObservableObject {
    private var engine: OpaquePointer?

    @Published var roster: [WorkerInfo] = []
    @Published var messages: [TeamMessage] = []
    @Published var githubConnected: Bool = false
    @Published var lastError: String?

    // MARK: Lifecycle

    func create(projectRoot: String) -> Bool {
        engine = tm_engine_create(projectRoot)
        guard engine != nil else {
            lastError = "Failed to create engine for \(projectRoot)"
            return false
        }
        return true
    }

    func sessionStart() -> Bool {
        guard let e = engine else { return false }
        let result = tm_session_start(e)
        if result != 0 {
            lastError = String(cString: tm_engine_last_error(e))
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
        guard let e = engine else { return }
        tm_engine_destroy(e)
        engine = nil
    }

    // MARK: Callbacks

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

        // Incoming messages (worker → Team Lead)
        tm_message_subscribe(e, { message, userdata in
            guard let userdata, let message else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.handleIncomingMessage(from: message)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // GitHub events
        tm_github_webhooks_start(e, { eventType, payload, userdata in
            guard let userdata else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.handleGitHubEvent(
                    type: String(cString: eventType!),
                    payload: String(cString: payload!)
                )
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // /teammux-* commands
        tm_commands_watch(e, { command, args, userdata in
            guard let userdata else { return }
            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.handleCommand(
                    command: String(cString: command!),
                    args: String(cString: args!)
                )
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Worker management

    func spawnWorker(
        agentBinary: String,
        agentType: AgentType,
        workerName: String,
        taskDescription: String
    ) -> UInt32 {
        guard let e = engine else { return 0 }
        return tm_worker_spawn(
            e,
            agentBinary,
            agentType.cValue,
            workerName,
            taskDescription
        )
    }

    func dismissWorker(_ workerId: UInt32) -> Bool {
        guard let e = engine else { return false }
        return tm_worker_dismiss(e, workerId) == 0
    }

    func ptyFd(for workerId: UInt32) -> Int32 {
        guard let e = engine else { return -1 }
        return tm_pty_fd(e, workerId)
    }

    // MARK: Messaging

    func sendMessage(to workerId: UInt32, type: MessageType, payload: String) -> Bool {
        guard let e = engine else { return false }
        return tm_message_send(e, workerId, type.cValue, payload) == 0
    }

    func broadcastMessage(type: MessageType, payload: String) -> Bool {
        guard let e = engine else { return false }
        return tm_message_broadcast(e, type.cValue, payload) == 0
    }

    // MARK: GitHub

    func connectGitHub() -> Bool {
        guard let e = engine else { return false }
        let result = tm_github_auth(e)
        githubConnected = (result == 0)
        return githubConnected
    }

    func createPR(for workerId: UInt32, title: String, body: String) -> GitHubPR? {
        guard let e = engine else { return nil }
        guard let pr = tm_github_create_pr(e, workerId, title, body) else { return nil }
        defer tm_pr_free(pr)
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
        defer tm_diff_free(diff)
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
                status: WorkerStatus(from: w.status),
                agentType: AgentType(from: w.agent_type),
                agentBinary: String(cString: w.agent_binary),
                spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at))
            ))
        }
        self.roster = workers
    }

    private func handleIncomingMessage(from cMsg: UnsafePointer<tm_message_t>) {
        let msg = TeamMessage(
            from: cMsg.pointee.from,
            to: cMsg.pointee.to,
            type: MessageType(from: cMsg.pointee.type),
            payload: String(cString: cMsg.pointee.payload),
            timestamp: Date(timeIntervalSince1970: TimeInterval(cMsg.pointee.timestamp)),
            seq: cMsg.pointee.seq,
            gitCommit: cMsg.pointee.git_commit.map { String(cString: $0) }
        )
        messages.append(msg)
    }

    private func handleGitHubEvent(type: String, payload: String) {
        // Parse event and notify relevant views
        // PR merged → update roster status
        // PR opened → update Git tab
        // Check run completed → update Live Feed
        objectWillChange.send()
    }

    private func handleCommand(_ command: String, args: String) {
        // Dispatch /teammux-* commands from Team Lead
        switch command {
        case "/teammux-add":
            // Parse args JSON, spawn worker
            break
        case "/teammux-remove":
            // Dismiss worker
            break
        case "/teammux-message":
            // Send message to specific worker
            break
        case "/teammux-broadcast":
            // Broadcast to all workers
            break
        default:
            break
        }
    }
}
```

---

## Step 2 — App entry point

### 2.1 `AppDelegate.swift` — single window, correct lifecycle

```swift
@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    var workspaceWindowController: WorkspaceWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ghostty initializes here (existing code — do not remove)
        // ...

        // Open Teammux workspace window — ONE window, nothing else
        openTeammuxWindow()
    }

    func openTeammuxWindow() {
        let controller = WorkspaceWindowController()
        controller.showWindow(nil)
        workspaceWindowController = controller
    }

    // Prevent Ghostty from opening its own terminal window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspaceWindowController?.showWindow(nil) }
        return false
    }
}
```

---

## Step 3 — Setup screens

### 3.1 `SetupView.swift` — orchestrates the 3-step flow

```swift
struct SetupView: View {
    @State private var step: SetupStep = .project
    @State private var selectedProject: URL?
    @State private var teamConfig: TeamConfig = .default

    enum SetupStep { case project, team, initiate }

    var body: some View {
        switch step {
        case .project:
            ProjectPickerView(selectedProject: $selectedProject) {
                step = .team
            }
        case .team:
            TeamBuilderView(
                projectURL: selectedProject!,
                config: $teamConfig
            ) {
                step = .initiate
            }
        case .initiate:
            InitiateView(
                projectURL: selectedProject!,
                config: teamConfig
            )
        }
    }
}
```

### 3.2 `ProjectPickerView.swift`

```swift
struct ProjectPickerView: View {
    @Binding var selectedProject: URL?
    let onNext: () -> Void
    @State private var recentProjects: [URL] = []  // loaded from UserDefaults
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            // Logo/wordmark area
            Text("Teammux")
                .font(.system(size: 32, weight: .semibold, design: .default))

            Text("Where does this mission begin?")
                .font(.title3)
                .foregroundColor(.secondary)

            // Primary action
            Button("Select project folder") {
                selectFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Recent projects
            if !recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(recentProjects, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            selectedProject = url
                            onNext()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }

            // Drag target
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(dash: [6]))
                .foregroundColor(.secondary.opacity(0.4))
                .frame(height: 80)
                .overlay(Text("or drag a git repo here").foregroundColor(.secondary))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
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
        // Check for .git directory
        let gitDir = url.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            selectedProject = url
            saveToRecents(url)
            onNext()
        } else {
            errorMessage = "This folder isn't a git repository. Teammux needs a git repo to manage agent worktrees."
            // Offer git init button
        }
    }
}
```

### 3.3 `TeamBuilderView.swift`

```swift
struct TeamBuilderView: View {
    let projectURL: URL
    @Binding var config: TeamConfig
    let onNext: () -> Void
    @State private var githubStatus: GitHubStatus = .detecting

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Build your team")
                .font(.title2).fontWeight(.semibold)

            // Team Lead
            GroupBox("Team Lead") {
                HStack {
                    Text("Agent:")
                    Picker("", selection: $config.teamLead.agent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                    }
                    .frame(width: 160)
                    Text("Model:")
                    Picker("", selection: $config.teamLead.model) {
                        ForEach(claudeModels, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 200)
                }
            }

            // Workers
            GroupBox("Teammates") {
                VStack(spacing: 12) {
                    ForEach($config.workers) { $worker in
                        WorkerRowView(worker: $worker) {
                            config.workers.removeAll { $0.id == worker.id }
                        }
                    }
                    Button {
                        config.workers.append(WorkerConfig.default)
                    } label: {
                        Label("Add teammate", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }

            // GitHub
            GroupBox("GitHub") {
                HStack {
                    Circle()
                        .fill(githubStatus.color)
                        .frame(width: 8, height: 8)
                    Text(githubStatus.label)
                    if githubStatus == .disconnected {
                        Button("Connect") { connectGitHub() }
                    }
                }
            }

            // Permissions note
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
}
```

### 3.4 `InitiateView.swift`

```swift
struct InitiateView: View {
    let projectURL: URL
    let config: TeamConfig
    @StateObject private var engine = EngineClient()
    @State private var isInitiating = false
    @State private var initiated = false

    var body: some View {
        VStack(spacing: 32) {
            Text("Your team is assembled.")
                .font(.title2).fontWeight(.semibold)

            // Team summary
            VStack(alignment: .leading, spacing: 8) {
                TeamSummaryRow(role: "Team Lead", agent: config.teamLead.agent.displayName, model: config.teamLead.model)
                ForEach(config.workers) { worker in
                    TeamSummaryRow(role: worker.name, agent: worker.agent.displayName, model: worker.model)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            Button {
                initiate()
            } label: {
                if isInitiating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Initiate Mission")
                        .font(.title3).fontWeight(.medium)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInitiating)
        }
        .frame(width: 480)
        .padding(48)
    }

    private func initiate() {
        isInitiating = true
        Task {
            // Write .teammux/config.toml
            await writeConfig()
            // Create engine and start session
            if engine.create(projectRoot: projectURL.path) {
                _ = engine.sessionStart()
            }
            initiated = true
        }
    }
}
```

---

## Step 4 — Main workspace

### 4.1 `WorkspaceView.swift` — root layout

```swift
struct WorkspaceView: View {
    @StateObject var engine: EngineClient
    @State var activeWorkerId: UInt32? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Project tab bar
            ProjectTabBar()
                .frame(height: 38)

            // Three panes
            HSplitView {
                // Left — roster
                RosterView(
                    engine: engine,
                    activeWorkerId: $activeWorkerId
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                // Centre — active worker terminal
                WorkerPaneView(
                    engine: engine,
                    activeWorkerId: activeWorkerId
                )
                .frame(minWidth: 400)

                // Right — tabs
                RightPaneView(engine: engine)
                    .frame(minWidth: 320, idealWidth: 420)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}
```

### 4.2 `ProjectTabBar.swift` — Chrome-style tabs

```swift
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
                            hasActivity: project.hasUnseenActivity
                        )
                        .onTapGesture {
                            projectManager.activate(project)
                        }
                    }
                }
            }

            // Add project button
            Button {
                projectManager.openNewProject()
            } label: {
                Image(systemName: "plus")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}

struct ProjectTab: View {
    let project: Project
    let isActive: Bool
    let hasActivity: Bool

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
            Button {
                // close tab
            } label: {
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

### 4.3 `RosterView.swift` — left pane

```swift
struct RosterView: View {
    @ObservedObject var engine: EngineClient
    @Binding var activeWorkerId: UInt32?
    @State private var showingSpawnPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Team Lead — pinned top
            TeamLeadRow(
                isActive: activeWorkerId == nil,
                onTap: { activeWorkerId = nil }  // nil = Team Lead is focus
            )

            Divider()

            // Workers — scrollable
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(engine.roster) { worker in
                        WorkerRow(
                            worker: worker,
                            isActive: activeWorkerId == worker.id,
                            onTap: { activeWorkerId = worker.id },
                            onDismiss: {
                                engine.dismissWorker(worker.id)
                            }
                        )
                    }
                }
            }

            Spacer()

            Divider()

            // Bottom controls
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
                    // Open project settings
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

struct WorkerRow: View {
    let worker: WorkerInfo
    let isActive: Bool
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
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
                .frame(maxHeight: .infinity, alignment: .leading)
                : nil,
            alignment: .leading
        )
    }
}
```

### 4.4 `SpawnPopoverView.swift` — new worker popover

```swift
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
                TextEditor(text: $taskDescription)
                    .frame(height: 70)
                    .font(.system(size: 13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3))
                    )
                    .overlay(
                        Group {
                            if taskDescription.isEmpty {
                                Text("what should this worker do?")
                                    .foregroundColor(.secondary)
                                    .padding(4)
                            }
                        },
                        alignment: .topLeading
                    )
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedAgent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                        Text("Codex CLI").tag(AgentType.codexCli)
                    }
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
        let binary = selectedAgent.resolvedBinary()
        _ = engine.spawnWorker(
            agentBinary: binary,
            agentType: selectedAgent,
            workerName: name,
            taskDescription: taskDescription
        )
        isPresented = false
    }
}
```

### 4.5 `WorkerPaneView.swift` — centre pane with ZStack switching

```swift
struct WorkerPaneView: View {
    @ObservedObject var engine: EngineClient
    let activeWorkerId: UInt32?

    var body: some View {
        ZStack {
            if engine.roster.isEmpty {
                // Empty state
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
                    WorkerTerminalView(worker: worker, engine: engine)
                        .opacity(worker.id == activeWorkerId ? 1 : 0)
                        .allowsHitTesting(worker.id == activeWorkerId)
                        .id(worker.id)
                }
            }
        }
        .background(Color.black)
    }
}

struct WorkerTerminalView: NSViewRepresentable {
    let worker: WorkerInfo
    let engine: EngineClient

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        // Wire Ghostty SurfaceView with worker's PTY fd
        // cwd = worker.worktreePath
        // agent binary = worker.agentBinary
        let view = GhosttyTerminalNSView()
        view.configure(
            ptyFd: engine.ptyFd(for: worker.id),
            workingDirectory: worker.worktreePath
        )
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}
}
```

---

## Step 5 — Right pane

### 5.1 `RightPaneView.swift` — four tabs

```swift
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
            // Tab bar
            HStack(spacing: 0) {
                ForEach(RightTab.allCases, id: \.self) { tab in
                    RightPaneTab(
                        title: tab.rawValue,
                        isSelected: selectedTab == tab
                    )
                    .onTapGesture { selectedTab = tab }
                }
                Spacer()
            }
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Tab content — full height
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

### 5.2 `TeamLeadTerminalView.swift` — full Ghostty terminal for Team Lead

```swift
struct TeamLeadTerminalView: NSViewRepresentable {
    let engine: EngineClient

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = GhosttyTerminalNSView()
        view.configure(
            ptyFd: engine.ptyFd(for: 0),  // 0 = TM_WORKER_TEAM_LEAD
            workingDirectory: engine.projectRoot
        )
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}
}
```

### 5.3 `GitView.swift` — branch list + PR status

```swift
struct GitView: View {
    @ObservedObject var engine: EngineClient
    @State private var prs: [GitHubPR] = []
    @State private var selectedWorkerId: UInt32? = nil

    var body: some View {
        List {
            Section("Main branch") {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text("main")
                    Spacer()
                    Text("up to date").font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Active workers") {
                ForEach(engine.roster) { worker in
                    WorkerBranchRow(
                        worker: worker,
                        pr: prs.first { $0.title.contains(worker.branchName) },
                        onApprove: {
                            if let pr = prs.first(where: { $0.title.contains(worker.branchName) }) {
                                _ = engine.mergePR(pr.number)
                            }
                        },
                        onReject: {
                            _ = engine.dismissWorker(worker.id)
                        },
                        onOpenPR: {
                            let pr = engine.createPR(
                                for: worker.id,
                                title: "[teammux] \(worker.name): \(worker.taskDescription)",
                                body: "Automated PR from Teammux worker \(worker.name)"
                            )
                            prs.append(contentsOf: [pr].compactMap { $0 })
                        }
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }
}
```

### 5.4 `DiffView.swift` — syntax-highlighted diff

```swift
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
                Spacer()
                Text(selectedWorkerId == nil ? "Select a worker to view diff" : "No changes")
                    .foregroundColor(.secondary)
                Spacer()
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
        .onChange(of: selectedWorkerId) { workerId in
            guard let id = workerId else { diffFiles = []; return }
            diffFiles = engine.getDiff(for: id)
        }
    }
}
```

### 5.5 `LiveFeedView.swift` — real-time activity stream

```swift
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(engine.messages) { msg in
                            LiveFeedRow(message: msg, roster: engine.roster)
                                .id(msg.id)
                        }
                    }
                }
                .onChange(of: engine.messages.count) { _ in
                    if let last = engine.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
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

    var senderName: String {
        message.from == 0 ? "Team Lead" :
        roster.first { $0.id == message.from }?.name ?? "Worker \(message.from)"
    }

    var receiverName: String {
        message.to == 0 ? "Team Lead" :
        roster.first { $0.id == message.to }?.name ?? "All"
    }
}
```

---

## Step 6 — GitHub client

`macos/Sources/Teammux/GitHub/GitHubClient.swift` handles the OAuth flow (the part that requires a browser):

```swift
@MainActor
class GitHubOAuthFlow: ObservableObject {
    @Published var isAuthenticating = false
    @Published var token: String?

    func startOAuthFlow() {
        // Open browser to GitHub OAuth authorization URL
        // Listen for callback on localhost redirect URI
        // Extract token and store in macOS Keychain
        let authURL = URL(string: "https://github.com/login/oauth/authorize?client_id=\(clientId)&scope=repo")!
        NSWorkspace.shared.open(authURL)
    }
}
```

---

## Step 7 — Tests

```swift
// TeammuxEngineClientTests.swift
import XCTest
@testable import Teammux

class EngineClientTests: XCTestCase {
    func testVersionCallable() {
        XCTAssertEqual(EngineClient.version(), "0.1.0")
    }

    func testCreateWithInvalidPath() {
        let client = EngineClient()
        XCTAssertFalse(client.create(projectRoot: "/nonexistent/path"))
    }

    func testRosterEmptyOnCreate() {
        let client = EngineClient()
        XCTAssertTrue(client.roster.isEmpty)
    }

    func testMessagesEmptyOnCreate() {
        let client = EngineClient()
        XCTAssertTrue(client.messages.isEmpty)
    }
}
```

---

## Definition of done — Stream 3

- [ ] `./build.sh` succeeds and app launches
- [ ] Exactly one window opens — the Teammux workspace window
- [ ] Project tab bar renders at top with `[+]` button
- [ ] Setup flow: project picker → team builder → initiate — all three screens render and navigate
- [ ] Drag-and-drop of a git repo folder onto the project picker works
- [ ] Left roster shows Team Lead pinned at top
- [ ] `[+] New Worker` opens spawn popover with all fields
- [ ] Right pane has four tabs: Team Lead | Git | Diff | Feed
- [ ] Team Lead tab shows a Ghostty terminal surface (agent running)
- [ ] Git tab shows branch list
- [ ] Diff tab shows worker picker
- [ ] Live Feed tab shows empty state with correct layout
- [ ] All Swift tests pass
- [ ] No force-unwraps in production paths (guard/if let throughout)

**Commit message:** `feat: stream 3 — Swift UI, setup flow, workspace, all four right pane tabs`

**Open a PR from `feat/stream3-swift-ui` into `main`. Do not merge — report back.**
