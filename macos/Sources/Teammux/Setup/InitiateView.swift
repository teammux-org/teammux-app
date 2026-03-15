import SwiftUI

// MARK: - InitiateView

/// Step 3 of the setup flow.
///
/// Shows a summary of the assembled team and a button to launch the session.
/// On initiation it:
/// 1. Creates the `.teammux/` directory
/// 2. Writes `config.toml` via `TeamConfig.toTOML()`
/// 3. Writes `.gitignore` for the `.teammux/` dir
/// 4. Adds the project to `ProjectManager`
/// 5. Creates the engine and starts the session
struct InitiateView: View {
    let projectURL: URL
    let teamConfig: TeamConfig
    let onBack: () -> Void

    @EnvironmentObject private var projectManager: ProjectManager

    @State private var isInitiating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Title
            VStack(spacing: 8) {
                Text("Your team is assembled.")
                    .font(.title.bold())
                Text(projectURL.lastPathComponent)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 28)

            // Team summary
            teamSummary
                .padding(.bottom, 24)

            // Error
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
                    .padding(.bottom, 12)
            }

            // Initiate button
            Button(action: initiateMission) {
                if isInitiating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                } else {
                    Text("Initiate Mission")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInitiating)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 12)

            Spacer()

            // Back
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

    // MARK: - Team summary

    private var teamSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Text("Role")
                    .frame(width: 140, alignment: .leading)
                Text("Agent")
                    .frame(width: 120, alignment: .leading)
                Text("Model")
                    .frame(width: 180, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)

            Divider()

            // Team Lead
            TeamSummaryRow(
                role: "Team Lead",
                agent: teamConfig.teamLead.agent.displayName,
                model: teamConfig.teamLead.model
            )

            // Workers
            ForEach(teamConfig.workers) { worker in
                TeamSummaryRow(
                    role: worker.name,
                    agent: worker.agent.displayName,
                    model: worker.model
                )
            }

            if teamConfig.workers.isEmpty {
                Text("No teammates configured")
                    .foregroundColor(.secondary)
                    .font(.callout)
                    .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(maxWidth: 480)
    }

    // MARK: - Initiation

    private func initiateMission() {
        isInitiating = true
        errorMessage = nil

        let fm = FileManager.default
        let teammuxDir = projectURL.appendingPathComponent(".teammux")
        let configFile = teammuxDir.appendingPathComponent("config.toml")
        let gitignoreFile = teammuxDir.appendingPathComponent(".gitignore")

        do {
            // 1. Create .teammux/ directory
            try fm.createDirectory(at: teammuxDir, withIntermediateDirectories: true)

            // 2. Write config.toml
            let toml = teamConfig.toTOML(projectName: projectURL.lastPathComponent)
            try toml.write(to: configFile, atomically: true, encoding: .utf8)

            // 3. Write .gitignore
            let gitignoreContent = """
            # Teammux runtime data
            *.log
            worktrees/
            """
            try gitignoreContent.write(to: gitignoreFile, atomically: true, encoding: .utf8)

            // 4. Add project to ProjectManager
            let project = projectManager.addProject(
                name: projectURL.lastPathComponent,
                path: projectURL
            )

            // 5. Create engine and start session
            if let engine = projectManager.engine(for: project.id) {
                let created = engine.create(projectRoot: projectURL.path)
                if created {
                    let started = engine.sessionStart()
                    if !started {
                        errorMessage = engine.lastError ?? "Failed to start session."
                    }
                } else {
                    errorMessage = engine.lastError ?? "Failed to create engine."
                }
            }

            isInitiating = false

        } catch {
            isInitiating = false
            errorMessage = "Setup failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - TeamSummaryRow

/// A single row in the team summary table.
struct TeamSummaryRow: View {
    let role: String
    let agent: String
    let model: String

    var body: some View {
        HStack {
            Text(role)
                .frame(width: 140, alignment: .leading)
            Text(agent)
                .frame(width: 120, alignment: .leading)
                .foregroundColor(.secondary)
            Text(model)
                .frame(width: 180, alignment: .leading)
                .font(.system(.body, design: .monospaced))
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}
