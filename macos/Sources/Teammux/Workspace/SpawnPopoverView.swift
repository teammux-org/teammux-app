import SwiftUI

// MARK: - SpawnPopoverView

/// Popover form for spawning a new worker agent.
/// Collects task description, agent type, optional role ID, and optional
/// worker name, then calls engine.spawnWorker() on submit.
struct SpawnPopoverView: View {
    @ObservedObject var engine: EngineClient
    @Binding var isPresented: Bool

    @State private var taskDescription: String = ""
    @State private var workerName: String = ""
    @State private var selectedAgentType: AgentTypeOption = .claudeCode
    @State private var customBinary: String = ""
    @State private var selectedRoleId: String?
    @State private var isSpawning = false
    @State private var spawnError: String?

    /// Simplified agent type picker options.
    enum AgentTypeOption: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codexCli = "Codex CLI"
        case custom = "Custom"

        var id: String { rawValue }

        func toAgentType(customBinary: String) -> AgentType {
            switch self {
            case .claudeCode: return .claudeCode
            case .codexCli:   return .codexCli
            case .custom:     return .custom(customBinary)
            }
        }

        func resolvedBinary(customBinary: String) -> String {
            switch self {
            case .claudeCode: return "claude"
            case .codexCli:   return "codex"
            case .custom:     return customBinary
            }
        }
    }

    private var canSpawn: Bool {
        let trimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if selectedAgentType == .custom {
            return !customBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Worker")
                .font(.headline)

            // Task description
            VStack(alignment: .leading, spacing: 4) {
                Text("Task")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Describe the task...", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            }

            // Agent picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Agent", selection: $selectedAgentType) {
                    ForEach(AgentTypeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Custom binary field (only when Custom is selected)
            if selectedAgentType == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Binary")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("e.g. my-agent", text: $customBinary)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Role picker — loaded or empty (loadAvailableRoles is synchronous)
            rolePicker

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name (optional)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Worker name", text: $workerName)
                    .textFieldStyle(.roundedBorder)
            }

            // Spawn error
            if let error = spawnError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Spawn button
            HStack {
                Spacer()

                Button(action: spawnWorker) {
                    if isSpawning {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text("Initiate Teammate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSpawn || isSpawning)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            if engine.availableRoles.isEmpty {
                engine.loadAvailableRoles()
            }
        }
    }

    // MARK: - Role picker

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Role")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if !engine.availableRoles.isEmpty {
                // Loaded — grouped picker (only divisions with roles)
                Picker("Role", selection: $selectedRoleId) {
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
            } else {
                // Empty — no roles found or load failed
                HStack(spacing: 6) {
                    Text("No roles available")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Reload") {
                        engine.loadAvailableRoles()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }

            // Role description — shown after selection
            if let roleId = selectedRoleId,
               let role = engine.availableRoles.first(where: { $0.id == roleId }) {
                Text(role.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var populatedDivisions: [RoleDivision] {
        RoleDivision.allCases.filter { !rolesForDivision($0).isEmpty }
    }

    private func rolesForDivision(_ division: RoleDivision) -> [RoleDefinition] {
        engine.availableRoles.filter { $0.division == division.rawValue }
    }

    // MARK: - Spawn action

    private func spawnWorker() {
        isSpawning = true
        spawnError = nil

        Task { @MainActor in
            let name = workerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty
                ? "Worker \(engine.roster.count + 1)"
                : name

            let agentType = selectedAgentType.toAgentType(customBinary: customBinary)
            let binary = selectedAgentType.resolvedBinary(customBinary: customBinary)

            let workerId = engine.spawnWorker(
                agentBinary: binary,
                agentType: agentType,
                workerName: resolvedName,
                taskDescription: taskDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                roleId: selectedRoleId
            )

            isSpawning = false

            if workerId == 0 {
                spawnError = engine.lastError ?? "Failed to spawn worker"
                return  // don't dismiss
            }

            // Warn if requested role was not applied
            if let roleId = selectedRoleId,
               engine.workerRoles[workerId]?.id != roleId {
                spawnError = "Worker spawned but role '\(roleId)' could not be applied"
                return  // don't dismiss — let user see the warning
            }

            isPresented = false
        }
    }
}
