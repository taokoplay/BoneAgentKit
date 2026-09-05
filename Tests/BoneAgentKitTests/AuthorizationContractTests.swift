import Foundation
import XCTest
@testable import BoneAgentKit

final class AuthorizationContractTests: XCTestCase {
    private func grant() throws -> BoneAuthorizationGrant {
        try .init(ticketID: .init("ticket"), runID: .init("run"), stepID: .init("step"), attemptID: .init("attempt"), toolCallID: .init("call"),
            canonicalCall: .init(toolID: "write", toolVersion: "1", schemaVersion: 1, arguments: Data("{\"value\":1}".utf8)),
            principal: "host-user", resourceScope: "document", resourceRevision: 7, impact: .ordinaryPublicRead,
            grantedAtUptime: 10, expiresAtUptime: 20, nonce: "host-nonce")
    }

    private func validation(_ grant: BoneAuthorizationGrant, changing field: String = "", now: TimeInterval = 15) throws -> BoneAuthorizationValidation {
        .init(ticketID: field == "ticket" ? try .init("other") : grant.ticketID,
              runID: field == "run" ? try .init("other") : grant.runID,
              stepID: field == "step" ? try .init("other") : grant.stepID,
              attemptID: field == "attempt" ? try .init("other") : grant.attemptID,
              toolCallID: field == "call" ? try .init("other") : grant.toolCallID,
              canonicalCall: try .init(toolID: field == "tool" ? "other" : "write", toolVersion: field == "version" ? "2" : "1", schemaVersion: field == "schema" ? 2 : 1,
                arguments: Data((field == "arguments" ? "{\"value\":2}" : "{ \"value\" : 1 }").utf8)),
              principal: field == "principal" ? "model-claimed-user" : grant.principal,
              resourceScope: field == "scope" ? "other" : grant.resourceScope,
              resourceRevision: field == "revision" ? 8 : grant.resourceRevision,
              impact: field == "impact" ? .init(dataAccess: .public, externalTransmission: .none, stateChange: .irreversible, economic: .none, userVisible: .none, permissionChange: .none) : grant.impact,
              nonce: field == "nonce" ? "model-claimed-approval" : grant.nonce, nowUptime: now)
    }

    func testEveryBindingIsCheckedAndRejectionDoesNotConsumeGrant() async throws {
        for field in ["ticket", "run", "step", "attempt", "call", "tool", "version", "schema", "arguments", "principal", "scope", "revision", "impact", "nonce"] {
            let handler = BoneInMemoryAuthorizationHandler()
            let grant = try grant()
            try await handler.store(grant)
            do { try await handler.consume(validation(grant, changing: field)); XCTFail("Accepted mismatch: \(field)") }
            catch { XCTAssertEqual(error as? BoneAuthorizationError, field == "ticket" ? .notFound : field == "revision" ? .resourceRevisionChanged : .bindingMismatch, field) }
            // Canonical JSON whitespace is irrelevant, but values/identity are not.
            try await handler.consume(validation(grant))
        }
    }

    func testExpiryAndInvalidClockFailClosedWithoutConsuming() async throws {
        for now in [9, 21, Double.nan, Double.infinity, -Double.infinity] {
            let handler = BoneInMemoryAuthorizationHandler()
            let grant = try grant()
            try await handler.store(grant)
            do { try await handler.consume(validation(grant, now: now)); XCTFail("Accepted invalid time") }
            catch { XCTAssertEqual(error as? BoneAuthorizationError, .expired) }
            try await handler.consume(validation(grant))
        }
        // Existing SDK contract uses an inclusive expiry instant.
        for now in [10.0, 20.0] {
            let handler = BoneInMemoryAuthorizationHandler()
            let grant = try grant()
            try await handler.store(grant)
            try await handler.consume(validation(grant, now: now))
        }
    }

    func testConcurrentConsumeHasOneWinnerAndTicketCannotBeReissued() async throws {
        let handler = BoneInMemoryAuthorizationHandler()
        let grant = try grant()
        let request = try validation(grant)
        try await handler.store(grant)
        do { try await handler.store(grant); XCTFail("Duplicate accepted") }
        catch { XCTAssertEqual(error as? BoneAuthorizationError, .duplicateTicket) }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask {
                do { try await handler.consume(request); return true }
                catch { XCTAssertEqual(error as? BoneAuthorizationError, .alreadyConsumed); return false }
            } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        do { try await handler.store(grant); XCTFail("Consumed ticket reissued") }
        catch { XCTAssertEqual(error as? BoneAuthorizationError, .duplicateTicket) }
    }

    func testModelClaimCannotCreateAuthorizationFact() async throws {
        let request = try validation(grant(), changing: "nonce")
        do { try await BoneInMemoryAuthorizationHandler().consume(request); XCTFail("Missing grant accepted") }
        catch { XCTAssertEqual(error as? BoneAuthorizationError, .notFound) }
        do { try await BoneDenyingAuthorizationHandler().consume(request); XCTFail("Default handler accepted") }
        catch { XCTAssertEqual(error as? BoneAuthorizationError, .denied) }
    }
}
