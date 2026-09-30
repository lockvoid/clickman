import Foundation
import XCTest
@testable import ClickMan

/// Every case of the client fixtures in protocol/fixtures, against this client.
final class ConformanceTests: XCTestCase {
    private struct FieldCase: Decodable {
        let name: String
        let field: String
        let value: String
        let valid: Bool
    }

    private struct BatchCase: Decodable {
        let name: String
        let maxEvents: Int
        let maxBytes: Int
        let bodies: [String]
        let taken: Int
    }

    private struct OutcomeCase: Decodable {
        let name: String
        let status: Int
        let outcome: String
    }

    private struct BackoffCase: Decodable {
        let name: String
        let failures: Int
        let retryAfter: Double?
        let min: Double
        let max: Double
    }

    func testEvents() throws {
        for scenario in try Fixture.cases("events.json", as: FieldCase.self) {
            let field = try XCTUnwrap(EventField(rawValue: scenario.field), scenario.name)
            XCTAssertEqual(field.accepts(scenario.value), scenario.valid, scenario.name)
        }
    }

    func testTraits() throws {
        for scenario in try Fixture.cases("traits.json") {
            let stored = try XCTUnwrap(scenario["stored"]?.object)
            let changes = try XCTUnwrap(scenario["changes"]?.object)
            XCTAssertEqual(Identity.merge(traits: stored, with: changes), scenario["traits"]?.object, "\(scenario["name"]!)")
        }
    }

    func testLifecycle() throws {
        for scenario in try Fixture.cases("lifecycle.json") {
            let last = scenario["last"] == .null ? nil : try launch(scenario["last"])
            let expected = try XCTUnwrap(scenario["events"]?.array).map(event)
            XCTAssertEqual(try launch(scenario["launch"]).events(after: last), expected, "\(scenario["name"]!)")
        }
    }

    func testBatches() throws {
        for scenario in try Fixture.cases("batches.json", as: BatchCase.self) {
            let taken = Batch.count(taking: scenario.bodies, maxEvents: scenario.maxEvents, maxBytes: scenario.maxBytes)
            XCTAssertEqual(taken, scenario.taken, scenario.name)
        }
    }

    func testOutcomes() throws {
        for scenario in try Fixture.cases("outcomes.json", as: OutcomeCase.self) {
            XCTAssertEqual(Outcome(status: scenario.status).rawValue, scenario.outcome, scenario.name)
        }
    }

    func testBackoff() throws {
        for scenario in try Fixture.cases("backoff.json", as: BackoffCase.self) {
            let bounds = RetryDelay.jitterRange
            for jitter in [bounds.lowerBound, 1, bounds.upperBound, .random(in: bounds)] {
                let seconds = RetryDelay.seconds(failures: scenario.failures, retryAfter: scenario.retryAfter, jitter: jitter)
                XCTAssertTrue((scenario.min...scenario.max).contains(seconds), "\(scenario.name): \(seconds)s at \(jitter)")
            }
        }
    }

    private func launch(_ value: JSONValue?) throws -> Launch {
        Launch(version: try XCTUnwrap(value?["version"]?.string), build: try XCTUnwrap(value?["build"]?.string))
    }

    private func event(_ value: JSONValue) throws -> Event {
        Event(name: try XCTUnwrap(value["event"]?.string), properties: try XCTUnwrap(value["properties"]?.object))
    }
}
