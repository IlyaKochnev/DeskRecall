import Foundation
import Darwin

@MainActor enum CheckState { static var failures = 0 }
@MainActor func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    CheckState.failures += 1
    print("FAIL: \(message) (\(file):\(line))")
}
@MainActor func expectTrue(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition { recordFailure("Expected true", file: file, line: line) }
}
@MainActor func expectFalse(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if condition { recordFailure("Expected false", file: file, line: line) }
}
@MainActor func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { recordFailure("Expected equal values", file: file, line: line) }
}
@MainActor func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a == b { recordFailure("Expected different values", file: file, line: line) }
}

let suite = CoreTests()
let checks: [(String, @MainActor () async throws -> Void)] = [
    ("Topology identity and layout", { suite.testTopologyIgnoresEnumerationOrderAndGeometryForProfileKey() }),
    ("Ambiguous duplicate windows", { suite.testDuplicateTitlesNeverPickAnArbitraryWindow() }),
    ("Session identity and one-to-one assignment", { suite.testRuntimeIdentityResolvesDuplicatesAndNoWindowIsReused() }),
    ("Application isolation and missing evidence", { suite.testMatchingDoesNotCrossApplicationsOrInventEvidence() }),
    ("Document identity outranks title", { suite.testStrongIdentityPrecedesConflictingTitle() }),
    ("Coordinate origins", { suite.testCoordinatesSupportDisplaysAboveAndLeftOfPrimary() }),
    ("Normalized geometry and clamping", { suite.testGeometryNormalizesAndKeepsWindowsInsideChangedArea() }),
    ("Invalid profile data", { suite.testInvalidGeometryAndUnknownDisplayRejectProfile() }),
    ("Stale operation generations", { suite.testGenerationRejectsStalePlans() }),
    ("Separate profiles and backup", { try await suite.testStoreSeparatesTopologiesAndKeepsPreviousBackup() }),
    ("Corrupt and future profile preservation", { try await suite.testStorePreservesCorruptAndFutureProfiles() }),
    ("Journal persistence and redaction", { try await suite.testJournalPersistsAcrossInstancesWithoutRawWindowMetadata() }),
    ("Journal rotation and interrupted writes", { try await suite.testJournalRotatesAndRepairsAnInterruptedLine() }),
    ("Honest restoration summary", { suite.testSummaryDoesNotCountNoProfileOrCancellationAsSuccess() }),
    ("Journal retention and failure reporting", { try await suite.testJournalRetentionAndWriteFailuresAreVisible() }),
    ("All window states and overlapping windows", { try suite.testAllWindowStatesRoundTripIncludingIdenticalGeometry() }),
    ("Legacy profiles and complete-scope upgrade", { try await suite.testLegacyVisibleOnlyProfileLoadsAndUpgradesWithoutInventingScope() }),
    ("Off-display window capture", { suite.testOffDisplayWindowGetsNearestDisplayInsteadOfBeingDropped() }),
    ("Server-only windows across six desktops", { try suite.testSystemInventorySurvivesEmptyAXListsAcrossSixDesktops() }),
    ("System window identity isolation", { suite.testWindowIDsDoNotCrossProcessesLaunchesOrBoots() }),
    ("No guessed AX handles for overlapping server windows", { suite.testAmbiguousGeometryNeverAttachesAXToWrongSystemWindow() }),
    ("Logical desktop resolution after reconnect", { try suite.testSpaceResolutionUsesMonitorAndOrdinalAfterIDsChange() }),
    ("Offscreen auxiliary geometry preservation", { suite.testUnchangedMonitorPreservesIntentionalOffscreenGeometry() })
]
for (name, check) in checks {
    let before = CheckState.failures
    do { try await check() } catch { recordFailure("\(name): \(error)") }
    if before == CheckState.failures { print("PASS: \(name)") }
}
print("\(checks.count) checks; \(CheckState.failures) failures")
exit(CheckState.failures == 0 ? 0 : 1)
