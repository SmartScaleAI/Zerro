import XCTest
@testable import Zerro

@MainActor
final class BYOKTrialManagerTests: XCTestCase {
    private let deviceHash = String(repeating: "a", count: 64)

    private func makeManager(
        transport: StubManagedTransport,
        tokenSlot: InMemoryKeychainSlot? = nil
    ) -> BYOKTrialManager {
        BYOKTrialManager(
            tokenSlot: tokenSlot ?? InMemoryKeychainSlot(),
            transport: transport,
            defaults: .ephemeralPreview(),
            deviceHash: { self.deviceHash }
        )
    }

    private func response(
        status: String,
        remaining: Int,
        token: String? = "trial-token",
        counted: Bool? = nil
    ) -> String {
        var fields = [
            #""status":"\#(status)""#,
            #""generations_remaining":\#(remaining)"#,
            #""generations_limit":10"#,
        ]
        if let token { fields.append(#""token":"\#(token)""#) }
        if status != "eligible" {
            fields.append(#""trial_grant_id":"11111111-1111-4111-8111-111111111111""#)
        }
        if let counted { fields.append(#""counted":\#(counted)"#) }
        return "{\(fields.joined(separator: ","))}"
    }

    func testEligibilityDoesNotSelectUntilUserContinues() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(response(status: "eligible", remaining: 10), status: 200)
        let manager = makeManager(transport: transport)

        let result = try await manager.checkEligibility()

        XCTAssertEqual(result, .eligible(generationsRemaining: 10))
        XCTAssertFalse(manager.isSelected)
        manager.select()
        XCTAssertTrue(manager.isSelected)
        XCTAssertEqual(manager.generationsRemaining, 10)
    }

    func testSuccessfulGenerationCountsLocallyThenSyncsOnce() async {
        let transport = StubManagedTransport()
        let tokenSlot = InMemoryKeychainSlot("trial-token")
        transport.enqueue(
            response(status: "active", remaining: 9, counted: true),
            status: 200
        )
        let manager = makeManager(transport: transport, tokenSlot: tokenSlot)
        manager.select()
        let id = "22222222-2222-4222-8222-222222222222"

        await manager.recordSuccessfulGeneration(id: id)

        XCTAssertEqual(manager.generationsRemaining, 9)
        XCTAssertNotNil(manager.grantId)
        XCTAssertEqual(transport.callCount, 1)

        await manager.recordSuccessfulGeneration(id: id)
        XCTAssertEqual(manager.generationsRemaining, 9)
        XCTAssertEqual(transport.callCount, 1, "a retry must not consume or sync twice")
    }

    func testFailedSyncKeepsLocalResultAndRetriesIdempotently() async {
        let transport = StubManagedTransport()
        let tokenSlot = InMemoryKeychainSlot("trial-token")
        transport.enqueue("{}", status: 500)
        let manager = makeManager(transport: transport, tokenSlot: tokenSlot)
        manager.select()
        let id = "33333333-3333-4333-8333-333333333333"

        await manager.recordSuccessfulGeneration(id: id)
        XCTAssertEqual(manager.generationsRemaining, 9)
        XCTAssertEqual(transport.callCount, 1)

        transport.enqueue(
            response(status: "active", remaining: 9, counted: true),
            status: 200
        )
        await manager.recordSuccessfulGeneration(id: id)
        XCTAssertEqual(manager.generationsRemaining, 9)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testTenthSuccessfulGenerationTransitionsEntitlementToExpired() async {
        let transport = StubManagedTransport()
        let tokenSlot = InMemoryKeychainSlot("trial-token")
        let manager = makeManager(transport: transport, tokenSlot: tokenSlot)
        manager.select()

        for index in 0..<9 {
            transport.enqueue(
                response(
                    status: "active",
                    remaining: 9 - index,
                    counted: true
                ),
                status: 200
            )
            let suffix = String(format: "%012x", index + 1)
            await manager.recordSuccessfulGeneration(
                id: "44444444-4444-4444-8444-\(suffix)"
            )
        }

        transport.enqueue(
            response(status: "exhausted", remaining: 0, counted: true),
            status: 200
        )
        XCTAssertTrue(
            manager.recordSuccessfulGenerationLocally(
                id: "44444444-4444-4444-8444-00000000000a"
            )
        )
        XCTAssertEqual(manager.generationsRemaining, 0)
        XCTAssertTrue(manager.isExhausted)
        await manager.syncPending()

        let store = EntitlementStore(
            licenseService: LicenseService(
                licenseKeySlot: InMemoryKeychainSlot(),
                instanceIDSlot: InMemoryKeychainSlot(),
                lastValidatedSlot: InMemoryKeychainSlot(),
                transport: OfflineLicenseTransport()
            ),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(),
            byokTrial: manager,
            defaults: .ephemeralPreview()
        )
        XCTAssertEqual(store.state, .byokTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    func testPaidBYOKLicenseOutranksAnonymousTrial() {
        let transport = StubManagedTransport()
        let manager = makeManager(transport: transport)
        manager.select()
        let license = LicenseService(
            licenseKeySlot: InMemoryKeychainSlot("PAID-KEY"),
            instanceIDSlot: InMemoryKeychainSlot("instance"),
            lastValidatedSlot: InMemoryKeychainSlot(),
            transport: OfflineLicenseTransport()
        )

        let store = EntitlementStore(
            licenseService: license,
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.byok.rawValue),
            byokTrial: manager,
            defaults: .ephemeralPreview()
        )

        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }
}
