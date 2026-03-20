import Testing
@testable import Ghostty

// MARK: - TD42: LCS changedLineIndices unit tests

@Suite
struct ContextViewLCSTests {

    // MARK: - Both empty

    @Test func bothEmpty() {
        let result = ContextView.changedLineIndices(old: [], new: [])
        #expect(result.isEmpty)
    }

    // MARK: - Identical content (0 changes)

    @Test func identicalContent() {
        let lines = ["# Teammux", "", "Some content", "More lines"]
        let result = ContextView.changedLineIndices(old: lines, new: lines)
        #expect(result.isEmpty)
    }

    // MARK: - Old empty — all new lines are changes

    @Test func oldEmpty() {
        let newLines = ["line 1", "line 2", "line 3"]
        let result = ContextView.changedLineIndices(old: [], new: newLines)
        #expect(result == Set([0, 1, 2]))
    }

    // MARK: - New empty — no changed indices (empty result set)

    @Test func newEmpty() {
        let oldLines = ["line 1", "line 2"]
        let result = ContextView.changedLineIndices(old: oldLines, new: [])
        #expect(result.isEmpty)
    }

    // MARK: - Single edit (one line changed)

    @Test func singleEdit() {
        let old = ["alpha", "beta", "gamma"]
        let new = ["alpha", "BETA", "gamma"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // Only index 1 changed
        #expect(result == Set([1]))
    }

    // MARK: - Insertion in middle (TD28 motivating case)

    @Test func insertionInMiddle() {
        let old = ["line 1", "line 2", "line 3"]
        let new = ["line 1", "INSERTED", "line 2", "line 3"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // Only the inserted line (index 1) should be highlighted
        #expect(result == Set([1]))
    }

    // MARK: - Deletion

    @Test func deletion() {
        let old = ["line 1", "line 2", "line 3"]
        let new = ["line 1", "line 3"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // All surviving lines are part of the LCS — no changes in new
        #expect(result.isEmpty)
    }

    // MARK: - Complete replacement

    @Test func completeReplacement() {
        let old = ["aaa", "bbb", "ccc"]
        let new = ["xxx", "yyy", "zzz"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // Every new line is changed
        #expect(result == Set([0, 1, 2]))
    }

    // MARK: - Mixed insertion and deletion

    @Test func mixedInsertionAndDeletion() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["a", "X", "c", "Y", "e"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // "a", "c", "e" are in LCS (indices 0, 2, 4); "X" and "Y" are new (indices 1, 3)
        #expect(result == Set([1, 3]))
    }

    // MARK: - Single line old and new (same)

    @Test func singleLineSame() {
        let result = ContextView.changedLineIndices(old: ["only"], new: ["only"])
        #expect(result.isEmpty)
    }

    // MARK: - Single line old and new (different)

    @Test func singleLineDifferent() {
        let result = ContextView.changedLineIndices(old: ["old"], new: ["new"])
        #expect(result == Set([0]))
    }

    // MARK: - Append at end

    @Test func appendAtEnd() {
        let old = ["a", "b"]
        let new = ["a", "b", "c", "d"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // "a" and "b" are LCS; "c" and "d" are new
        #expect(result == Set([2, 3]))
    }

    // MARK: - Prepend at start

    @Test func prependAtStart() {
        let old = ["b", "c"]
        let new = ["a", "b", "c"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // "b" and "c" are LCS; "a" is new at index 0
        #expect(result == Set([0]))
    }

    // MARK: - Duplicate/repeated lines

    @Test func duplicateLines() {
        let old = ["a", "b", "a"]
        let new = ["a", "a", "b"]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // LCS length 2 ("a","b"); new index 1 ("a") is the non-LCS element
        #expect(result.count == 1)
    }

    // MARK: - Trailing empty string (real-world from components(separatedBy:))

    @Test func trailingEmptyString() {
        let old = ["line 1", "line 2", ""]
        let new = ["line 1", "CHANGED", ""]
        let result = ContextView.changedLineIndices(old: old, new: new)
        // "line 1" and "" are LCS; only index 1 changed
        #expect(result == Set([1]))
    }
}
