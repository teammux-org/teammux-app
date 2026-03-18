import SwiftUI

// MARK: - SetupStep

/// The stages of the setup wizard.
/// `.restore` is shown when a saved session file is detected for the selected project.
enum SetupStep {
    case project
    case restore(SessionSnapshot)
    case team
    case initiate
}

// MARK: - SetupView

/// Orchestrates the setup flow:
/// 1. Project picker — choose a git repository
/// 1b. Restore card — if a saved session exists, offer to restore or start fresh
/// 2. Team builder  — configure team lead + workers
/// 3. Initiate      — review and launch the session
struct SetupView: View {
    @EnvironmentObject var projectManager: ProjectManager

    @State private var step: SetupStep = .project
    @State private var selectedProject: URL?
    @State private var teamConfig: TeamConfig = .default

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Step content
            Group {
                switch step {
                case .project:
                    ProjectPickerView { url in
                        selectedProject = url
                        // Check for saved session before advancing
                        if let snapshot = SessionState.load(projectPath: url.path) {
                            step = .restore(snapshot)
                        } else {
                            step = .team
                        }
                    }

                case .restore(let snapshot):
                    if let projectURL = selectedProject {
                        RestoreCardView(
                            snapshot: snapshot,
                            projectURL: projectURL,
                            onRestore: {
                                step = .project // reset — initiation handled by RestoreCardView
                            },
                            onStartFresh: {
                                step = .team
                            },
                            onBack: {
                                selectedProject = nil
                                step = .project
                            }
                        )
                    }

                case .team:
                    TeamBuilderView(config: $teamConfig, projectRoot: selectedProject) {
                        step = .initiate
                    } onBack: {
                        step = .project
                    }

                case .initiate:
                    if let projectURL = selectedProject {
                        InitiateView(
                            projectURL: projectURL,
                            teamConfig: teamConfig
                        ) {
                            step = .team
                        }
                    } else {
                        // Safety fallback — should not happen since we guard
                        // selectedProject before advancing to .initiate
                        VStack(spacing: 12) {
                            Text("No project selected.")
                                .foregroundColor(.secondary)
                            Button("Back to Project Selection") {
                                step = .project
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 24) {
            stepLabel("1. Project", isActive: isProjectStep, isComplete: !isProjectStep)
            stepLabel("2. Team", isActive: isTeamStep, isComplete: isInitiateStep)
            stepLabel("3. Initiate", isActive: isInitiateStep, isComplete: false)
        }
        .font(.caption)
    }

    private var isProjectStep: Bool {
        if case .project = step { return true }
        if case .restore = step { return true }
        return false
    }

    private var isTeamStep: Bool {
        if case .team = step { return true }
        return false
    }

    private var isInitiateStep: Bool {
        if case .initiate = step { return true }
        return false
    }

    private func stepLabel(_ title: String, isActive: Bool, isComplete: Bool) -> some View {
        Text(title)
            .fontWeight(isActive ? .bold : .regular)
            .foregroundColor(isActive ? .accentColor : (isComplete ? .primary : .secondary))
    }
}

// MARK: - RestoreCardView

/// Shows a restore card when a saved session is detected.
/// Displays worker count, last saved timestamp, and role list.
/// Offers "Restore" and "Start Fresh" actions.
struct RestoreCardView: View {
    let snapshot: SessionSnapshot
    let projectURL: URL
    let onRestore: () -> Void
    let onStartFresh: () -> Void
    let onBack: () -> Void

    @EnvironmentObject private var projectManager: ProjectManager

    @State private var isRestoring: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                Text("Previous session found")
                    .font(.title.bold())
                Text(projectURL.lastPathComponent)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 24)

            // Session info card
            sessionInfoCard
                .padding(.bottom, 24)

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
                    .padding(.bottom, 12)
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: startFresh) {
                    Text("Start Fresh")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isRestoring)

                Button(action: performRestore) {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text("Restore Session")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRestoring)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 12)

            Spacer()

            HStack {
                Button("Back") { onBack() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session info card

    private var sessionInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workers")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(snapshot.workers.count)")
                    .fontWeight(.medium)
            }

            HStack {
                Text("Last saved")
                    .foregroundColor(.secondary)
                Spacer()
                Text(snapshot.timestamp, style: .relative)
                    .fontWeight(.medium)
                Text("ago")
                    .foregroundColor(.secondary)
            }

            if !snapshot.workers.isEmpty {
                Divider()

                ForEach(snapshot.workers, id: \.id) { worker in
                    HStack(spacing: 6) {
                        Text(worker.name)
                            .font(.callout)
                        if let roleId = worker.roleId {
                            Text(roleId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                )
                        }
                        Spacer()
                        Text(worker.branchName)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(maxWidth: 480)
    }

    // MARK: - Actions

    private func startFresh() {
        onStartFresh()
    }

    private func performRestore() {
        isRestoring = true
        errorMessage = nil

        let fm = FileManager.default
        let teammuxDir = projectURL.appendingPathComponent(".teammux")
        let configFile = teammuxDir.appendingPathComponent("config.toml")

        // Ensure .teammux directory exists (may exist from previous session)
        if !fm.fileExists(atPath: teammuxDir.path) {
            do {
                try fm.createDirectory(at: teammuxDir, withIntermediateDirectories: true)
            } catch {
                errorMessage = "Failed to create .teammux directory: \(error.localizedDescription)"
                isRestoring = false
                return
            }
        }

        // Ensure config.toml exists (may have been written by previous session)
        if !fm.fileExists(atPath: configFile.path) {
            let minimalConfig = "[project]\nname = \"\(projectURL.lastPathComponent)\"\n"
            do {
                try minimalConfig.write(to: configFile, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Failed to write config.toml: \(error.localizedDescription)"
                isRestoring = false
                return
            }
        }

        // Add project and create engine
        let project = projectManager.addProject(
            name: projectURL.lastPathComponent,
            path: projectURL
        )

        guard let engine = projectManager.engine(for: project.id) else {
            errorMessage = "Failed to create engine"
            isRestoring = false
            return
        }

        // Create and start engine
        if !engine.create(projectRoot: projectURL.path) {
            errorMessage = engine.lastError ?? "Failed to create engine"
            projectManager.closeProject(project.id)
            isRestoring = false
            return
        }

        if !engine.sessionStart() {
            errorMessage = engine.lastError ?? "Failed to start session"
            projectManager.closeProject(project.id)
            isRestoring = false
            return
        }

        // Restore workers and state from snapshot
        engine.restoreSession(snapshot)

        // Delete session file after successful restore
        SessionState.delete(projectPath: projectURL.path)

        isRestoring = false
        onRestore()
    }
}
