import SwiftUI

// MARK: - SetupStep

/// The three stages of the setup wizard.
enum SetupStep {
    case project
    case team
    case initiate
}

// MARK: - SetupView

/// Orchestrates the three-step setup flow:
/// 1. Project picker — choose a git repository
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
                        step = .team
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
            stepLabel("1. Project", isActive: step == .project, isComplete: step != .project)
            stepLabel("2. Team", isActive: step == .team, isComplete: step == .initiate)
            stepLabel("3. Initiate", isActive: step == .initiate, isComplete: false)
        }
        .font(.caption)
    }

    private func stepLabel(_ title: String, isActive: Bool, isComplete: Bool) -> some View {
        Text(title)
            .fontWeight(isActive ? .bold : .regular)
            .foregroundColor(isActive ? .accentColor : (isComplete ? .primary : .secondary))
    }
}
