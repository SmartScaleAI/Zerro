//
//  APIKeyFieldModelRevalidateTests.swift
//  ZerroTests
//
//  Locks the Revalidate empty-field behavior in `APIKeyFieldModel`. THE BUG: an
//  emptied-but-not-yet-blurred field, then Revalidate, used to fall back to the
//  still-stored key and validate it → the pill flipped to "Verified" instead of
//  removing the key. The fix routes an empty field through `removeKey()` (the same
//  path `saveAndValidate` uses), so the visible empty state and the stored state
//  agree. Driven through the injectable in-memory Keychain + a recording validator,
//  so nothing touches the real Keychain or the network.
//
//  (`Analytics.capture` is a no-op until `Analytics.start()` runs — never in tests
//  — so `byok_key_removed` isn't directly observable here; these assert the
//  observable effects instead: deletion, state, presence refresh, and — the crux —
//  that the validator is NEVER invoked on an emptied field.)
//

import XCTest
@testable import Zerro

@MainActor
final class APIKeyFieldModelRevalidateTests: XCTestCase {

    /// THE REPORTED BUG: a stored (validated) key, the field cleared but NOT
    /// blurred, then Revalidate → the key is REMOVED (not resurrected to
    /// "Verified"), state is `.unverified`, presence refreshes, and the validator
    /// is NEVER invoked.
    func testRevalidateEmptiedFieldRemovesKeyAndNeverValidates() async {
        let slot = InMemoryKeychainSlot("sk-stored-validated-key")
        let model = APIKeyFieldModel(provider: .openai, keychain: slot, firstKeyProbe: { false })
        // Init read the stored key → resting `.verified`, exactly like a returning
        // user opening Settings.
        XCTAssertEqual(model.state, .verified)

        var validatorCalls = 0
        model.validator = { _ in validatorCalls += 1; return .valid }
        var storeChanged = 0
        model.onKeyStoreChanged = { storeChanged += 1 }

        // Select-all + delete, focus still in the field (nothing committed on blur).
        model.rawKey = ""
        model.revalidate()
        await Task.yield()   // catch any stray async validation (there must be none)

        XCTAssertNil(slot.read(), "an emptied field commits a REMOVE, never a re-validate of the stored key")
        XCTAssertEqual(model.state, .unverified, "removed, not flipped back to .verified (the bug)")
        XCTAssertEqual(validatorCalls, 0, "the validator must NEVER run on an emptied field")
        XCTAssertEqual(storeChanged, 1, "onKeyStoreChanged fires so ProviderKeyPresence refreshes")
    }

    /// A NON-empty field on Revalidate still validates exactly what's typed and
    /// writes it through on `.valid` (unchanged behavior).
    func testRevalidateNonEmptyFieldValidatesThatContent() async {
        let slot = InMemoryKeychainSlot("sk-old")
        let model = APIKeyFieldModel(provider: .openai, keychain: slot, firstKeyProbe: { false })
        var validated: String?
        model.validator = { key in validated = key; return .valid }

        model.rawKey = "sk-new-typed"
        model.revalidate()
        await waitUntilSettled(model)

        XCTAssertEqual(validated, "sk-new-typed", "a non-empty field validates exactly what's typed")
        XCTAssertEqual(model.state, .verified)
        XCTAssertEqual(slot.read(), "sk-new-typed", "a valid revalidate writes the typed key through")
    }

    /// Revalidate with NO stored key and an empty field is a no-op removal: state
    /// `.unverified` and the validator is not called.
    func testRevalidateEmptyFieldNoStoredKeyIsNoOpRemoval() {
        let slot = InMemoryKeychainSlot(nil)
        let model = APIKeyFieldModel(provider: .openai, keychain: slot, firstKeyProbe: { true })
        var validatorCalls = 0
        model.validator = { _ in validatorCalls += 1; return .valid }

        model.rawKey = ""
        model.revalidate()

        XCTAssertNil(slot.read())
        XCTAssertEqual(model.state, .unverified)
        XCTAssertEqual(validatorCalls, 0, "validator not called on an empty field")
    }

    /// `saveAndValidate`'s empty-field removal (now routed through `removeKey()`)
    /// still behaves exactly as before: the key is deleted, state `.unverified`,
    /// presence refreshes, and the validator isn't called.
    func testSaveAndValidateEmptyFieldStillRemovesKey() {
        let slot = InMemoryKeychainSlot("sk-stored")
        let model = APIKeyFieldModel(provider: .openai, keychain: slot, firstKeyProbe: { false })
        var validatorCalls = 0
        model.validator = { _ in validatorCalls += 1; return .valid }
        var storeChanged = 0
        model.onKeyStoreChanged = { storeChanged += 1 }

        model.rawKey = ""
        model.saveAndValidate()

        XCTAssertNil(slot.read(), "empty field on blur still removes the key")
        XCTAssertEqual(model.state, .unverified)
        XCTAssertEqual(storeChanged, 1, "presence refreshes on removal (unchanged)")
        XCTAssertEqual(validatorCalls, 0)
    }

    private func waitUntilSettled(_ model: APIKeyFieldModel, iterations: Int = 200) async {
        for _ in 0..<iterations {
            if model.state != .checking { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
    }
}
