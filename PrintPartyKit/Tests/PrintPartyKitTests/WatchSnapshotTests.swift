import XCTest
@testable import PrintPartyKit

final class WatchSnapshotTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let state = PrintJobState(
            printerId: UUID(),
            printerDisplayName: "Garage A1 Mini",
            printerModel: "Bambu Lab A1 Mini",
            jobName: "benchy.gcode",
            stage: .printing,
            progressPercent: 42.5,
            currentLayer: 120,
            totalLayers: 300,
            estimatedEndAt: Date(timeIntervalSince1970: 1_800_000_000),
            nozzleTempC: 210,
            bedTempC: 60,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = WatchSnapshot(
            printers: [state],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.printers.first?.progressPercent, 42.5)
        XCTAssertEqual(decoded.printers.first?.stage, .printing)
    }

    func testEmptyIsStable() {
        XCTAssertTrue(WatchSnapshot.empty.printers.isEmpty)
        XCTAssertEqual(WatchSnapshot.empty.generatedAt, .distantPast)
    }
}
