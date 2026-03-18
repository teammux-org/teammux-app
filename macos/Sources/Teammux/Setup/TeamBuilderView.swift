import SwiftUI

// MARK: - TeamBuilderView

/// Step 2 of the setup flow.
///
/// Allows configuration of:
/// - Team Lead agent + model
/// - Worker agents (add/remove/configure)
/// - GitHub connection status
struct TeamBuilderView: View {
    @Binding var config: TeamConfig
    let projectRoot: URL?
    let onNext: () -> Void
    let onBack: () -> Void

    /// Available model identifiers for the model picker.
    private let availableModels = [
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
        "gpt-5",
    ]

    @State private var ghStatus: GitHubStatus = .detecting
    @State private var bundledRoles: [RoleDefinition] = []
    @State private var rolesLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Build Your Team")
                    .font(.title2.bold())
                    .padding(.bottom, 4)

                // Team Lead
                teamLeadSection

                // Workers
                workersSection

                // GitHub status
                githubSection

                Spacer(minLength: 20)

                // Navigation
                HStack {
                    Button("Back") { onBack() }
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Continue") { onNext() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detectGitHubAuth()
            if !rolesLoaded {
                bundledRoles = EngineClient.listBundledRoles(projectRoot: projectRoot?.path)
                rolesLoaded = true
            }
        }
    }

    // MARK: - Team Lead

    private var teamLeadSection: some View {
        GroupBox("Team Lead") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agent")
                        .frame(width: 60, alignment: .leading)
                    Picker("Agent", selection: $config.teamLead.agent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                HStack {
                    Text("Model")
                        .frame(width: 60, alignment: .leading)
                    Picker("Model", selection: $config.teamLead.model) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Workers

    private var workersSection: some View {
        GroupBox("Teammates") {
            VStack(alignment: .leading, spacing: 8) {
                if config.workers.isEmpty {
                    Text("No teammates configured.")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(config.workers.indices, id: \.self) { index in
                        workerRow(at: index)
                        if index < config.workers.count - 1 {
                            Divider()
                        }
                    }
                }

                Button(action: addWorker) {
                    Label("Add Teammate", systemImage: "plus")
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
    }

    private func workerRow(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                // Name
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Name", text: $config.workers[index].name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                }

                // Agent
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Agent", selection: $config.workers[index].agent) {
                        Text("Claude Code").tag(AgentType.claudeCode)
                        Text("Codex CLI").tag(AgentType.codexCli)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                // Model
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Model", selection: $config.workers[index].model) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                // Role
                VStack(alignment: .leading, spacing: 2) {
                    Text("Role")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    workerRolePicker(at: index)
                }

                Spacer()

                // Remove
                Button(action: { removeWorker(at: index) }) {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this teammate")
            }

            // Role description
            if let roleId = config.workers[index].roleId,
               let role = bundledRoles.first(where: { $0.id == roleId }) {
                Text(role.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func addWorker() {
        let count = config.workers.count + 1
        let worker = WorkerConfig(
            name: "Teammate \(count)",
            agent: .claudeCode,
            model: "claude-sonnet-4-6"
        )
        config.workers.append(worker)
    }

    private func removeWorker(at index: Int) {
        guard config.workers.indices.contains(index) else { return }
        config.workers.remove(at: index)
    }

    // MARK: - Role picker

    @ViewBuilder
    private func workerRolePicker(at index: Int) -> some View {
        if !rolesLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: 180)
        } else if !bundledRoles.isEmpty {
            Picker("Role", selection: $config.workers[index].roleId) {
                Text("No role (generic)").tag(Optional<String>.none)
                ForEach(populatedDivisions, id: \.self) { division in
                    Section(division.displayName) {
                        ForEach(rolesForDivision(division)) { role in
                            Text(role.emoji.isEmpty ? role.name : "\(role.emoji) \(role.name)")
                                .tag(Optional(role.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
        } else {
            Text("Roles unavailable — you can assign roles after launch")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 180)
        }
    }

    private var populatedDivisions: [RoleDivision] {
        RoleDivision.allCases.filter { !rolesForDivision($0).isEmpty }
    }

    private func rolesForDivision(_ division: RoleDivision) -> [RoleDefinition] {
        bundledRoles.filter { $0.division == division.rawValue }
    }

    // MARK: - GitHub

    private var githubSection: some View {
        GroupBox("GitHub") {
            HStack(spacing: 8) {
                Circle()
                    .fill(ghStatus.color)
                    .frame(width: 10, height: 10)

                Text(ghStatus.label)
                    .font(.body)

                Spacer()

                if case .disconnected = ghStatus {
                    Button("Connect") {
                        detectGitHubAuth()
                    }
                }
            }
            .padding(8)
        }
    }

    /// Detect `gh auth status` by running the CLI process.
    private func detectGitHubAuth() {
        ghStatus = .detecting

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "auth", "status"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        // Try to extract account name from output
                        let account = parseGHAccount(from: output)
                        ghStatus = .connected(account)
                    } else {
                        ghStatus = .disconnected
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    ghStatus = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Best-effort parse of the `gh auth status` output to find the account.
    private func parseGHAccount(from output: String) -> String {
        // Output typically contains "Logged in to github.com account <user> ..."
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Logged in to") || line.contains("account") {
                // Return a cleaned up version of the relevant line
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return "Authenticated"
    }
}
