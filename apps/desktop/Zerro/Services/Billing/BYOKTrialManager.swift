//
//  BYOKTrialManager.swift
//  Zerro
//
//  Anonymous ten-generation BYOK trial. Generations, transcription, and API
//  keys stay on the direct provider path; this service sends only the existing
//  one-way Mac identifier and a random per-recording idempotency UUID to Zerro.
//

import Foundation
import os

enum BYOKTrialError: Error, Equatable {
    case deviceUnavailable
    case managedTrialAlreadyUsed
    case rateLimited
    case network
    case unauthorized
    case server
    case malformedResponse

    var userMessage: String {
        switch self {
        case .deviceUnavailable:
            return "Zerro couldn\u{2019}t identify this Mac for trial eligibility. Try again or use the email trial."
        case .managedTrialAlreadyUsed:
            return "This Mac has already used its free trial."
        case .rateLimited:
            return "Too many attempts. Wait a little and try again."
        case .network:
            return "Couldn\u{2019}t reach Zerro. Check your connection and try again."
        case .unauthorized, .server, .malformedResponse:
            return "Something went wrong. Please try again."
        }
    }
}

enum BYOKTrialEligibility: Equatable {
    case eligible(generationsRemaining: Int)
    case active(generationsRemaining: Int)
    case exhausted
}

@MainActor
@Observable
final class BYOKTrialManager {
    static let generationLimit = 10

    private let tokenSlot: KeychainSlot
    private let defaults: UserDefaults
    private let transport: ManagedTransport
    private let deviceHash: () -> String?

    private static let selectedKey = "byok_trial_selected_v1"
    private static let remainingKey = "byok_trial_generations_remaining_v1"
    private static let grantIdKey = "byok_trial_grant_id_v1"
    private static let pendingKey = "byok_trial_pending_generation_ids_v1"
    private static let completedKey = "byok_trial_completed_generation_ids_v1"

    /// Called after a local or server reconciliation changes entitlement.
    @ObservationIgnored var stateDidChange: (() -> Void)?

    init(
        tokenSlot: KeychainSlot? = nil,
        transport: ManagedTransport? = nil,
        defaults: UserDefaults = .standard,
        deviceHash: @escaping () -> String? = { DeviceIdentity.hashedDeviceID() }
    ) {
        self.tokenSlot = tokenSlot ?? KeychainStore.byokTrialToken
        self.transport = transport ?? URLSessionManagedTransport()
        self.defaults = defaults
        self.deviceHash = deviceHash
    }

    var isSelected: Bool {
        defaults.bool(forKey: Self.selectedKey)
    }

    var generationsRemaining: Int {
        guard isSelected else { return Self.generationLimit }
        if defaults.object(forKey: Self.remainingKey) == nil {
            return Self.generationLimit
        }
        return max(0, defaults.integer(forKey: Self.remainingKey))
    }

    var grantId: String? {
        defaults.string(forKey: Self.grantIdKey)
    }

    var hasStarted: Bool { grantId != nil || generationsRemaining < Self.generationLimit }
    var isExhausted: Bool { isSelected && generationsRemaining <= 0 }

    /// Marks BYOK as the chosen onboarding path. This does not claim the
    /// server-side trial; the atomic claim occurs on the first successful result.
    func select() {
        defaults.set(true, forKey: Self.selectedKey)
        if defaults.object(forKey: Self.remainingKey) == nil {
            defaults.set(Self.generationLimit, forKey: Self.remainingKey)
        }
        stateDidChange?()
    }

    /// Backing out before the first successful generation restores the email
    /// choice. A claimed/partially-used trial can never be locally unclaimed.
    func deselectIfUnstarted() {
        guard !hasStarted else { return }
        defaults.removeObject(forKey: Self.selectedKey)
        defaults.removeObject(forKey: Self.remainingKey)
        tokenSlot.delete()
        stateDidChange?()
    }

    @discardableResult
    func checkEligibility() async throws -> BYOKTrialEligibility {
        guard let hash = deviceHash() else {
            throw BYOKTrialError.deviceUnavailable
        }
        let response = try await post(
            payload: ["action": "eligibility", "device_id_hash": hash],
            bearer: nil
        )
        return try apply(response, selecting: false)
    }

    /// Counts one successful primary recording and waits for the best-effort
    /// server reconciliation. Most production callers use
    /// `recordSuccessfulGenerationLocally` first so the next recording is gated
    /// synchronously, then call `syncPending` without delaying the delivered
    /// result.
    func recordSuccessfulGeneration(id: String) async {
        _ = recordSuccessfulGenerationLocally(id: id)
        await syncPending()
    }

    /// Applies the local half of a successful-generation count synchronously.
    /// Returns true only when this UUID was newly counted. The local count
    /// changes first so an already-delivered result is never lost to a counter
    /// outage; the stable id remains queued until `syncPending` confirms it.
    @discardableResult
    func recordSuccessfulGenerationLocally(id: String) -> Bool {
        guard isSelected, generationsRemaining > 0 else { return false }
        guard UUID(uuidString: id) != nil else {
            Log.billing.error("BYOK trial ignored a non-UUID generation id")
            return false
        }
        guard !completedIDs.contains(id), !pendingIDs.contains(id) else {
            return false
        }

        var pending = pendingIDs
        pending.append(id)
        save(pending, key: Self.pendingKey)

        var completed = completedIDs
        completed.append(id)
        save(Array(completed.suffix(Self.generationLimit)), key: Self.completedKey)

        setRemaining(generationsRemaining - 1)
        stateDidChange?()
        Analytics.capture("byok_trial_generation_consumed", [
            "generations_remaining": generationsRemaining,
        ])
        return true
    }

    /// Best-effort reconciliation for launch and post-generation calls.
    func syncPending() async {
        guard isSelected, !pendingIDs.isEmpty else { return }
        for id in pendingIDs {
            do {
                let response = try await complete(id: id)
                _ = try apply(response, selecting: true)
                var pending = pendingIDs
                pending.removeAll { $0 == id }
                save(pending, key: Self.pendingKey)
            } catch BYOKTrialError.managedTrialAlreadyUsed {
                setRemaining(0)
                stateDidChange?()
                return
            } catch {
                Log.billing.info("BYOK trial sync deferred")
                return
            }
        }
    }

    private func complete(id: String) async throws -> BYOKTrialResponseDTO {
        if let token = tokenSlot.read(), !token.isEmpty {
            do {
                return try await post(
                    payload: ["action": "complete", "generation_id": id],
                    bearer: token
                )
            } catch BYOKTrialError.unauthorized {
                // Token may have expired. Refresh it anonymously against the
                // same device claim, then retry once.
            }
        }

        guard let hash = deviceHash() else {
            throw BYOKTrialError.deviceUnavailable
        }
        let resumed = try await post(
            payload: ["action": "resume", "device_id_hash": hash],
            bearer: nil
        )
        _ = try apply(resumed, selecting: true)
        guard let token = tokenSlot.read(), !token.isEmpty else {
            throw BYOKTrialError.malformedResponse
        }
        return try await post(
            payload: ["action": "complete", "generation_id": id],
            bearer: token
        )
    }

    private func apply(
        _ dto: BYOKTrialResponseDTO,
        selecting: Bool
    ) throws -> BYOKTrialEligibility {
        switch dto.status {
        case "managed_trial_used":
            throw BYOKTrialError.managedTrialAlreadyUsed
        case "eligible", "active", "exhausted":
            break
        default:
            throw BYOKTrialError.malformedResponse
        }

        if let token = dto.token, !token.isEmpty {
            tokenSlot.write(token)
        }
        if let grant = dto.trialGrantId, !grant.isEmpty {
            defaults.set(grant, forKey: Self.grantIdKey)
        }
        if selecting {
            defaults.set(true, forKey: Self.selectedKey)
        }
        if let serverRemaining = dto.generationsRemaining {
            let reconciled = selecting
                ? min(generationsRemaining, max(0, serverRemaining))
                : max(0, serverRemaining)
            defaults.set(reconciled, forKey: Self.remainingKey)
        }
        stateDidChange?()

        switch dto.status {
        case "eligible":
            return .eligible(generationsRemaining: dto.generationsRemaining ?? Self.generationLimit)
        case "active":
            return .active(generationsRemaining: dto.generationsRemaining ?? generationsRemaining)
        case "exhausted":
            return .exhausted
        default:
            throw BYOKTrialError.malformedResponse
        }
    }

    private func post(
        payload: [String: String],
        bearer: String?
    ) async throws -> BYOKTrialResponseDTO {
        var request = URLRequest(url: ManagedBackend.byokTrialURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.send(request)
        } catch {
            throw BYOKTrialError.network
        }
        let dto = try? JSONDecoder().decode(BYOKTrialResponseDTO.self, from: data)
        if status == 429 { throw BYOKTrialError.rateLimited }
        if status == 401 { throw BYOKTrialError.unauthorized }
        guard (200...299).contains(status) else { throw BYOKTrialError.server }
        guard let dto else { throw BYOKTrialError.malformedResponse }
        return dto
    }

    private var pendingIDs: [String] { load(Self.pendingKey) }
    private var completedIDs: [String] { load(Self.completedKey) }

    private func load(_ key: String) -> [String] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }

    private func save(_ values: [String], key: String) {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
        }
    }

    private func setRemaining(_ remaining: Int) {
        defaults.set(max(0, remaining), forKey: Self.remainingKey)
    }

    static func inMemory() -> BYOKTrialManager {
        let suite = "BYOKTrialManager.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return BYOKTrialManager(
            tokenSlot: InMemoryKeychainSlot(),
            transport: OfflineManagedTransport(),
            defaults: defaults,
            deviceHash: { String(repeating: "a", count: 64) }
        )
    }
}

private struct BYOKTrialResponseDTO: Decodable {
    let status: String?
    let token: String?
    let trialGrantId: String?
    let generationsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case status, token
        case trialGrantId = "trial_grant_id"
        case generationsRemaining = "generations_remaining"
    }
}
