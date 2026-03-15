import SwiftUI
import UniformTypeIdentifiers

// MARK: - ProjectPickerView

/// Step 1 of the setup flow.
///
/// Lets the user select a project folder via:
/// - An "Open" button that presents `NSOpenPanel`
/// - A recent-projects list loaded from UserDefaults
/// - Drag-and-drop of a directory
///
/// Validates that the selected directory contains a `.git` folder.
/// If not, shows an error and an option to initialise one.
struct ProjectPickerView: View {
    /// Called when the user selects a valid project directory.
    let onNext: (URL) -> Void

    @EnvironmentObject private var projectManager: ProjectManager

    @State private var selectedURL: URL?
    @State private var validationError: String?
    @State private var isTargeted: Bool = false
    @State private var isInitializingGit: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo / title
            VStack(spacing: 8) {
                Text("Teammux")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("Where does this mission begin?")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 32)

            // Select button
            Button(action: selectFolder) {
                Label("Select project folder", systemImage: "folder.badge.plus")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 16)

            // Validation error
            if let error = validationError {
                VStack(spacing: 8) {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.callout)

                    if let url = selectedURL {
                        Button("Initialize git repository") {
                            initializeGitRepo(at: url)
                        }
                        .disabled(isInitializingGit)
                    }
                }
                .padding(.bottom, 16)
            }

            // Recents
            recentsSection
                .padding(.bottom, 24)

            Spacer()

            // Drop zone hint
            Text("or drag a project folder here")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTarget)
    }

    // MARK: - Folder selection

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        validateAndProceed(url)
    }

    // MARK: - Validation

    private func validateAndProceed(_ url: URL) {
        selectedURL = url
        validationError = nil

        let gitDir = url.appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue {
            // Valid git repo
            onNext(url)
        } else {
            validationError = "\"\(url.lastPathComponent)\" is not a git repository."
        }
    }

    // MARK: - Git init

    private func initializeGitRepo(at url: URL) {
        isInitializingGit = true
        validationError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init"]
            process.currentDirectoryURL = url

            do {
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0

                DispatchQueue.main.async {
                    isInitializingGit = false
                    if success {
                        validateAndProceed(url)
                    } else {
                        validationError = "git init failed (exit code \(process.terminationStatus))."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isInitializingGit = false
                    validationError = "Failed to run git init: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Recent projects

    private var recentsSection: some View {
        let recents = projectManager.loadRecents()

        return Group {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Projects")
                        .font(.headline)
                        .padding(.bottom, 4)

                    ForEach(recents, id: \.absoluteString) { url in
                        Button(action: { validateAndProceed(url) }) {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.body)
                                    Text(url.path)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
            }
        }
    }

    // MARK: - Drop target

    private var dropTarget: some View {
        Color.clear
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }

                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                           isDir.boolValue {
                            validateAndProceed(url)
                        } else {
                            selectedURL = url
                            validationError = "Please drop a folder, not a file."
                        }
                    }
                }
                return true
            }
            .border(isTargeted ? Color.accentColor : Color.clear, width: 2)
    }
}
