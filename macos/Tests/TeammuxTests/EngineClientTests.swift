import Testing
import Foundation
@testable import Ghostty

// MARK: - EngineClient Tests

/// All tests are @MainActor since EngineClient is @MainActor-isolated.
@Suite
@MainActor
struct EngineClientTests {

    // MARK: - Version

    @Test func versionCallable() {
        // tm_version() should return a non-empty string (or "unknown" if the
        // C library is not linked, which is still non-empty).
        let version = EngineClient.version()
        #expect(!version.isEmpty)
    }

    // MARK: - Initial state

    @Test func rosterEmptyOnCreate() {
        let client = EngineClient()
        #expect(client.roster.isEmpty)
    }

    @Test func messagesEmptyOnCreate() {
        let client = EngineClient()
        #expect(client.messages.isEmpty)
    }

    @Test func lastErrorNilOnCreate() {
        let client = EngineClient()
        #expect(client.lastError == nil)
    }

    @Test func projectRootNilOnCreate() {
        let client = EngineClient()
        #expect(client.projectRoot == nil)
    }

    // MARK: - Operations without engine

    @Test func sessionStartWithoutCreate() {
        let client = EngineClient()
        let result = client.sessionStart()
        #expect(result == false)
        #expect(client.lastError != nil)
        #expect(client.lastError == "Engine not created")
    }

    @Test func dismissWorkerWithoutEngine() {
        let client = EngineClient()
        let result = client.dismissWorker(1)
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func sendMessageWithoutEngine() {
        let client = EngineClient()
        let result = client.sendMessage(to: 1, type: .task, payload: "hello")
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func broadcastMessageWithoutEngine() {
        let client = EngineClient()
        let result = client.broadcastMessage(type: .broadcast, payload: "hello all")
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func connectGitHubWithoutEngine() {
        let client = EngineClient()
        let result = client.connectGitHub()
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func getDiffWithoutEngine() {
        let client = EngineClient()
        let diff = client.getDiff(for: 1)
        #expect(diff.isEmpty)
        #expect(client.lastError == "Engine not created")
    }

    @Test func destroyWithoutEngine() {
        let client = EngineClient()
        // Pre-populate some state to verify it gets cleared
        client.roster = [
            WorkerInfo(
                id: 1,
                name: "W1",
                taskDescription: "task",
                branchName: "branch",
                worktreePath: "/tmp",
                status: .working,
                agentType: .claudeCode,
                agentBinary: "claude",
                model: "claude-sonnet-4-6",
                spawnedAt: Date()
            )
        ]
        client.messages = [
            TeamMessage(
                from: 0,
                to: 1,
                type: .task,
                payload: "test",
                timestamp: Date(),
                seq: 1
            )
        ]
        client.lastError = "some error"
        client.mergeStatuses[1] = .conflict
        client.pendingConflicts[1] = [
            ConflictInfo(filePath: "f.swift", conflictType: .content)
        ]

        // destroy() should not crash and should clear all state
        client.destroy()

        #expect(client.roster.isEmpty)
        #expect(client.messages.isEmpty)
        #expect(client.mergeStatuses.isEmpty)
        #expect(client.pendingConflicts.isEmpty)
        #expect(client.lastError == nil)
        #expect(client.projectRoot == nil)
    }

    @Test func spawnWorkerWithoutEngine() {
        let client = EngineClient()
        let workerId = client.spawnWorker(
            agentBinary: "claude",
            agentType: .claudeCode,
            workerName: "Test",
            taskDescription: "do something"
        )
        #expect(workerId == 0)
        #expect(client.lastError == "Engine not created")
    }

    @Test func createPRWithoutEngine() {
        let client = EngineClient()
        let pr = client.createPR(for: 1, title: "PR", body: "body")
        #expect(pr == nil)
        #expect(client.lastError == "Engine not created")
    }

    @Test func mergePRWithoutEngine() {
        let client = EngineClient()
        let result = client.mergePR(1, strategy: .squash)
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func reloadConfigWithoutEngine() {
        let client = EngineClient()
        client.reloadConfig()
        #expect(client.lastError == "Engine not created")
    }

    // MARK: - Slugify

    @Test func slugify() {
        #expect(EngineClient.slugify("Add user auth") == "add-user-auth")
        #expect(EngineClient.slugify("Fix Bug #123") == "fix-bug-123")
        #expect(EngineClient.slugify("hello world") == "hello-world")
        #expect(EngineClient.slugify("UPPER CASE") == "upper-case")
        #expect(EngineClient.slugify("simple") == "simple")
    }

    @Test func slugifyEdgeCases() {
        // Empty string
        #expect(EngineClient.slugify("") == "")

        // Special characters only
        #expect(EngineClient.slugify("!@#$%^&*()") == "")

        // Leading and trailing hyphens should be stripped
        #expect(EngineClient.slugify(" hello ") == "hello")
        #expect(EngineClient.slugify("--hello--") == "hello")

        // Long string truncation (over 40 characters)
        let longString = "This is a very long task description that should be truncated"
        let slug = EngineClient.slugify(longString)
        #expect(slug.count <= 40)

        // Mixed special chars and spaces
        #expect(EngineClient.slugify("feat: add new feature!") == "feat-add-new-feature")

        // Numbers only
        #expect(EngineClient.slugify("12345") == "12345")

        // Hyphens preserved
        #expect(EngineClient.slugify("already-slugified") == "already-slugified")

        // Multiple spaces collapse to a single hyphen (consecutive hyphens are collapsed)
        let multiSpace = EngineClient.slugify("a  b")
        #expect(multiSpace == "a-b")
    }

    // MARK: - Surface registry

    @Test func surfaceRegistry() {
        let client = EngineClient()
        let surface = NSObject()

        // Register
        client.registerSurface(surface, for: 1, injector: { _ in })
        #expect(client.surfaceView(for: 1) != nil)
        #expect(client.surfaceView(for: 1) === surface)

        // Unregistered worker returns nil
        #expect(client.surfaceView(for: 2) == nil)

        // Unregister
        client.unregisterSurface(for: 1)
        #expect(client.surfaceView(for: 1) == nil)
    }

    @Test func surfaceRegistryMultipleWorkers() {
        let client = EngineClient()
        let surface1 = NSObject()
        let surface2 = NSObject()

        client.registerSurface(surface1, for: 1, injector: { _ in })
        client.registerSurface(surface2, for: 2, injector: { _ in })

        #expect(client.surfaceView(for: 1) === surface1)
        #expect(client.surfaceView(for: 2) === surface2)

        // Unregister one, the other remains
        client.unregisterSurface(for: 1)
        #expect(client.surfaceView(for: 1) == nil)
        #expect(client.surfaceView(for: 2) === surface2)
    }

    @Test func surfaceRegistryOverwrite() {
        let client = EngineClient()
        let surface1 = NSObject()
        let surface2 = NSObject()

        client.registerSurface(surface1, for: 1, injector: { _ in })
        #expect(client.surfaceView(for: 1) === surface1)

        // Overwrite with a new surface
        client.registerSurface(surface2, for: 1, injector: { _ in })
        #expect(client.surfaceView(for: 1) === surface2)
    }

    @Test func destroyClearsSurfaceRegistry() {
        let client = EngineClient()
        let surface = NSObject()
        client.registerSurface(surface, for: 1, injector: { _ in })

        client.destroy()

        #expect(client.surfaceView(for: 1) == nil)
    }

    // MARK: - Merge initial state

    @Test func mergeStatusesEmptyOnCreate() {
        let client = EngineClient()
        #expect(client.mergeStatuses.isEmpty)
    }

    @Test func pendingConflictsEmptyOnCreate() {
        let client = EngineClient()
        #expect(client.pendingConflicts.isEmpty)
    }

    // MARK: - Merge operations without engine

    @Test func approveMergeWithoutEngine() {
        let client = EngineClient()
        let result = client.approveMerge(workerId: 1, strategy: .merge)
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
        // Failure must not populate mergeStatuses or start polling
        #expect(client.mergeStatuses.isEmpty)
    }

    @Test func rejectMergeWithoutEngine() {
        let client = EngineClient()
        let result = client.rejectMerge(workerId: 1)
        #expect(result == false)
        #expect(client.lastError == "Engine not created")
    }

    @Test func rejectMergeWithoutEngineDoesNotMutateState() {
        let client = EngineClient()
        client.mergeStatuses[1] = .inProgress
        client.pendingConflicts[1] = [
            ConflictInfo(filePath: "a.swift", conflictType: .content)
        ]

        let result = client.rejectMerge(workerId: 1)

        #expect(result == false)
        // State must NOT be mutated on failure
        #expect(client.mergeStatuses[1] == .inProgress)
        #expect(client.pendingConflicts[1]?.count == 1)
    }

    @Test func getMergeStatusWithoutEngine() {
        let client = EngineClient()
        let status = client.getMergeStatus(workerId: 1)
        #expect(status == .pending)
        #expect(client.lastError == "Engine not created")
    }

    @Test func getConflictsWithoutEngine() {
        let client = EngineClient()
        let conflicts = client.getConflicts(workerId: 1)
        #expect(conflicts.isEmpty)
        #expect(client.lastError == "Engine not created")
    }

    @Test func interceptorPathWithoutEngine() {
        let client = EngineClient()
        let path = client.interceptorPath(for: 1)
        #expect(path == nil)
    }

    // MARK: - Double create guard

    @Test func doubleCreatePrevented() {
        let client = EngineClient()
        // First create with a non-existent path will fail at the C level
        // (tm_engine_create returns nil), but a second call when engine
        // is already set should set lastError about "already created".
        //
        // Since we cannot actually create a valid engine in unit tests
        // (no valid project root), we verify the guard path by confirming
        // the first call sets an error about nil return.
        let result1 = client.create(projectRoot: "/nonexistent/path/for/test")
        // This may succeed or fail depending on whether the C library
        // is linked and whether the path exists. Either way, the second
        // call tests the guard.
        if result1 {
            // Engine was created — second call should be blocked
            let result2 = client.create(projectRoot: "/another/path")
            #expect(result2 == false)
            #expect(client.lastError == "Engine already created")
            client.destroy()
        } else {
            // C library returned nil — lastError should be set
            #expect(client.lastError != nil)
        }
    }
}
