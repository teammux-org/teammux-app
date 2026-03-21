## Domain
Swift layer new views introduced or significantly changed in v0.1.6, with focus on the right-pane additions, conflict-resolution UI, and new worker health/memory surfaces.

## Files Reviewed
- macos/Sources/Teammux/RightPane/PaneIconRail.swift
- macos/Sources/Teammux/RightPane/UserTerminalView.swift
- macos/Sources/Teammux/RightPane/ContextView.swift
- macos/Sources/Teammux/RightPane/GitView.swift
- macos/Sources/Teammux/RightPane/ConflictView.swift
- macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift
- macos/Sources/Teammux/Workspace/WorkerRow.swift
- macos/Sources/Teammux/RightPane/RightPaneView.swift
- macos/Sources/Teammux/Engine/EngineClient.swift
- macos/Sources/Teammux/Models/TeamMessage.swift
- macos/Sources/Teammux/Models/MergeTypes.swift
- macos/Sources/Teammux/Models/WorkerInfo.swift

## Finding Counts (Critical / Important / Suggestion)
1 / 3 / 0

## Top 3 Findings
1. The new `Restart Worker` button does not restart a worker PTY; it only clears engine health state, so the UI can mark a dead worker healthy without actually recovering it.
2. The TD38 cleanup-warning fix is still ineffective for `GitWorkerRow` and `ConflictView` because those warnings are stored in views that disappear as soon as merge status becomes terminal.
3. The new conflict-resolution and health actions still run synchronous engine work on `MainActor`, so merge/restart flows can freeze the UI despite showing progress indicators.

## Overall Health Assessment
The v0.1.6 Swift surface is visually cohesive and avoids obvious crash hazards such as force unwraps or unremoved key monitors in the reviewed files, but the new recovery paths are not production-ready yet. The largest gaps are behavioral: worker restart is wired to the wrong layer, cleanup warnings are still not reliably visible, and the new memory timeline parser is too fragile for arbitrary markdown content.
