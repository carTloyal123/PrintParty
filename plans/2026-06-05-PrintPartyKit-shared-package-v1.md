# PrintPartyKit: Shared SPM Package Plan

## Objective

Eliminate 7 duplicated type definitions between the iOS app (`Shared/`) and the gateway (`gateway/Sources/PrintPartyGateway/`) by extracting them into a single `PrintPartyKit` Swift package that both targets depend on. The relay has **no shared types** and is out of scope.

---

## Current Duplication Inventory

### 1. `MessageType` + `MessageEnvelope` — **Identical**

| iOS | Gateway |
|-----|---------|
| `Shared/Domain/MessageEnvelope.swift:15-98` | `gateway/Sources/PrintPartyGateway/Domain/MessageEnvelope.swift:13-96` |

- Diff: **Header comments only.** All properties, factory helpers (`event`, `request`, `response`, `error`), and payload helpers are byte-for-byte identical.
- Action: Move verbatim into `PrintPartyKit`.

### 2. `PrintJobState` — **Structurally identical, init differs**

| iOS | Gateway |
|-----|---------|
| `Shared/Domain/PrintJobState.swift:12-123` | `gateway/Sources/PrintPartyGateway/Domain/PrintJobState.swift:13-52` |

- Same 18 properties, same conformances (`Codable, Equatable, Sendable, Hashable`).
- iOS has a full 18-parameter init with defaults; gateway has a 5-parameter abbreviated init.
- `updatedAt` default: `.now` (iOS) vs `Date()` (gateway) — semantically identical.
- iOS has `// MARK:` sections and doc comments; gateway has none.
- Both have an `idle()` factory.
- Action: Use the iOS version (superset) as the canonical one. The gateway's abbreviated init can be provided as a convenience extension if needed, or callers can just use the full init with defaults.

### 3. `PrinterStage` — **Wire-format identical, iOS has UI extensions**

| iOS | Gateway |
|-----|---------|
| `Shared/Domain/PrinterStage.swift:13-83` | `gateway/Sources/PrintPartyGateway/Domain/PrintJobState.swift:54-70` |

- Same 9 cases, same `isActive` and `isTerminal` computed properties.
- iOS adds three SwiftUI properties: `displayName`, `symbolName`, `tint` (requires `import SwiftUI`).
- Action: Core enum + `isActive`/`isTerminal` go into `PrintPartyKit`. UI extensions stay in the iOS app via an extension on `PrinterStage` (they require SwiftUI which is unavailable on Linux).

### 4. `FrameCrypto` + `FrameCryptoError` — **Logic identical, import differs**

| iOS | Gateway |
|-----|---------|
| `Shared/Crypto/FrameCrypto.swift:1-87` | `gateway/Sources/PrintPartyGateway/Crypto/FrameCrypto.swift:1-87` |

- Every line of logic from line 14 onward is identical.
- iOS: `import CryptoKit` — gateway: `import Crypto` (swift-crypto).
- Action: Move into `PrintPartyKit` with a conditional import (`#if canImport(CryptoKit)` / `else import Crypto`). Both libraries expose the identical `AES.GCM` API surface.

### 5. `EncryptedContentState` / `EncryptedEnvelope` — **Same wire format, different names**

| iOS | Gateway |
|-----|---------|
| `Shared/Crypto/ContentStateDecryptor.swift:27-32` | `gateway/Sources/PrintPartyGateway/Crypto/ContentStateEncryptor.swift:25-30` |

- Same 4 fields: `printerId: String`, `v: Int`, `nonce: String`, `ciphertext: String`.
- iOS name: `EncryptedContentState` (public, `Hashable`); gateway name: `EncryptedEnvelope` (internal, nested).
- Action: Unify as `EncryptedContentState` in `PrintPartyKit`. Add `Hashable` conformance (free via synthesis). `ContentStateDecryptor` and `ContentStateEncryptor` remain in their respective targets since they are complementary, not duplicated.

### Not Duplicated (Stay Where They Are)

| Type | Location | Reason |
|------|----------|--------|
| `ConnectionPhase` | `Shared/Domain/ConnectionPhase.swift` | iOS-only, uses `SwiftUI.Color` |
| `PrintPartyActivityAttributes` | `Shared/Domain/PrintPartyActivityAttributes.swift` | iOS-only, uses `ActivityKit` |
| `ContentStateDecryptor` | `Shared/Crypto/ContentStateDecryptor.swift` | iOS-only (decrypt side) |
| `ContentStateEncryptor` | `gateway/.../Crypto/ContentStateEncryptor.swift` | Gateway-only (encrypt side) |
| All relay types | `relay/Sources/PrintPartyRelay/` | Opaque pass-through, no domain types |

---

## Recommended Package Structure

```
PrintPartyKit/
├── Package.swift
├── Sources/
│   └── PrintPartyKit/
│       ├── Domain/
│       │   ├── MessageEnvelope.swift      ← MessageType + MessageEnvelope
│       │   ├── PrintJobState.swift        ← full 18-property version
│       │   └── PrinterStage.swift         ← core enum (no SwiftUI)
│       └── Crypto/
│           ├── FrameCrypto.swift          ← conditional CryptoKit/Crypto import
│           └── EncryptedContentState.swift ← unified wire-format struct
└── Tests/
    └── PrintPartyKitTests/
        ├── MessageEnvelopeTests.swift
        ├── PrintJobStateTests.swift
        └── FrameCryptoTests.swift
```

### Package.swift Sketch

- `swift-tools-version: 5.10`
- Platforms: `.macOS(.v14), .iOS(.v17)` (matches existing targets)
- Dependencies: `swift-crypto` 3.0+ (only resolved on Linux; on Apple platforms CryptoKit is used instead)
- Single library product: `PrintPartyKit`
- The `swift-crypto` dependency should use a conditional target dependency so it only links on non-Apple platforms, or simply rely on the conditional `#if canImport` pattern at source level (swift-crypto re-exports CryptoKit on Apple, so listing it everywhere is safe).

### Conditional Import Pattern for Crypto

```swift
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
```

This works because `swift-crypto` deliberately mirrors the CryptoKit API surface. All types used (`SymmetricKey`, `AES.GCM.Nonce`, `AES.GCM.SealedBox`, `ChaChaPoly`) are available on both.

---

## Implementation Plan

### Phase 1: Create the Package

- [ ] 1.1 Create `PrintPartyKit/Package.swift` at the repo root with `swift-tools-version: 5.10`, platforms `[.macOS(.v14), .iOS(.v17)]`, dependency on `swift-crypto` 3.0+, and a library product `PrintPartyKit`.

- [ ] 1.2 Create `PrintPartyKit/Sources/PrintPartyKit/Domain/MessageEnvelope.swift` containing `MessageType` and `MessageEnvelope` taken from the iOS version (the superset with better doc comments). Remove the "Mirror of gateway" header comment since this is now the single source of truth.

- [ ] 1.3 Create `PrintPartyKit/Sources/PrintPartyKit/Domain/PrinterStage.swift` with the core enum (9 cases), `isActive`, and `isTerminal`. Omit `displayName`, `symbolName`, `tint` (those stay in the iOS app). Import only `Foundation`, no SwiftUI.

- [ ] 1.4 Create `PrintPartyKit/Sources/PrintPartyKit/Domain/PrintJobState.swift` using the iOS version's full 18-parameter init. Include the `idle()` factory.

- [ ] 1.5 Create `PrintPartyKit/Sources/PrintPartyKit/Crypto/FrameCrypto.swift` with the conditional `#if canImport(CryptoKit)` import pattern. All logic is identical on both platforms.

- [ ] 1.6 Create `PrintPartyKit/Sources/PrintPartyKit/Crypto/EncryptedContentState.swift` as a public top-level struct with `Codable, Sendable, Hashable` conformances and the 4 fields (`printerId`, `v`, `nonce`, `ciphertext`).

### Phase 2: Wire Up the Gateway

- [ ] 2.1 Add a local-path dependency in `gateway/Package.swift`: `.package(path: "../PrintPartyKit")` and add `"PrintPartyKit"` to the target's dependency array.

- [ ] 2.2 Delete `gateway/Sources/PrintPartyGateway/Domain/MessageEnvelope.swift` (replaced by PrintPartyKit).

- [ ] 2.3 Delete `gateway/Sources/PrintPartyGateway/Domain/PrintJobState.swift` (contained both `PrintJobState` and `PrinterStage`, now in PrintPartyKit).

- [ ] 2.4 Delete `gateway/Sources/PrintPartyGateway/Crypto/FrameCrypto.swift` (replaced by PrintPartyKit).

- [ ] 2.5 Update `gateway/.../Crypto/ContentStateEncryptor.swift`: remove the nested `EncryptedEnvelope` struct, add `import PrintPartyKit`, and change `EncryptedEnvelope` references to `EncryptedContentState`.

- [ ] 2.6 Add `import PrintPartyKit` to every gateway file that currently references `MessageEnvelope`, `PrintJobState`, `PrinterStage`, `FrameCrypto`, or `FrameCryptoError`. Remove their now-redundant `import Foundation` if PrintPartyKit re-exports it (or leave them — no harm).

- [ ] 2.7 Verify gateway builds: `cd gateway && swift build`. Fix any compilation errors.

- [ ] 2.8 Run gateway tests: `cd gateway && swift test`.

### Phase 3: Wire Up the iOS App / Widget Extension

- [ ] 3.1 Add a local-path dependency in the Xcode project (or a root `Package.swift` if the app uses SPM): `.package(path: "PrintPartyKit")`. Add the `PrintPartyKit` library to both the app target and the widget extension target.

- [ ] 3.2 Delete `Shared/Domain/MessageEnvelope.swift` (replaced by PrintPartyKit).

- [ ] 3.3 Delete `Shared/Domain/PrintJobState.swift` (replaced by PrintPartyKit).

- [ ] 3.4 Refactor `Shared/Domain/PrinterStage.swift`: remove everything except a SwiftUI extension on `PrinterStage` that provides `displayName`, `symbolName`, and `tint`. Add `import PrintPartyKit` and `import SwiftUI`. (Alternatively, move this extension into the app's UI layer.)

- [ ] 3.5 Delete `Shared/Crypto/FrameCrypto.swift` (replaced by PrintPartyKit).

- [ ] 3.6 Update `Shared/Crypto/ContentStateDecryptor.swift`: remove the `EncryptedContentState` struct definition, add `import PrintPartyKit`. The `ContentStateDecryptor` enum stays (it's iOS-only logic).

- [ ] 3.7 Add `import PrintPartyKit` to all iOS/widget files that reference shared types. Update the Xcode project file (`PrintParty.xcodeproj`) to remove deleted files from build phases.

- [ ] 3.8 Build and test the iOS app and widget extension in Xcode.

### Phase 4: Tests and Cleanup

- [ ] 4.1 Create `PrintPartyKit/Tests/PrintPartyKitTests/MessageEnvelopeTests.swift` — round-trip Codable encoding, factory helpers.

- [ ] 4.2 Create `PrintPartyKit/Tests/PrintPartyKitTests/PrintJobStateTests.swift` — verify init defaults, `idle()` factory, Codable round-trip.

- [ ] 4.3 Create `PrintPartyKit/Tests/PrintPartyKitTests/FrameCryptoTests.swift` — encrypt/decrypt round-trip with known key.

- [ ] 4.4 Migrate any existing tests from gateway that exercise these types to use `import PrintPartyKit`.

- [ ] 4.5 Remove any "Mirror of iOS" or "Mirror of gateway" comments from remaining files, since the duplication no longer exists.

---

## Verification Criteria

- `cd PrintPartyKit && swift build` succeeds on macOS (uses CryptoKit).
- `cd PrintPartyKit && swift build` succeeds on Linux (uses swift-crypto) — verifiable via Docker or CI.
- `cd gateway && swift build && swift test` passes with zero local copies of shared types.
- iOS app + widget extension build and run in Xcode with no local copies of shared types.
- `git grep -l 'MessageEnvelope' Shared/Domain gateway/Sources/PrintPartyGateway/Domain` returns zero results (types only exist in `PrintPartyKit/`).
- Wire compatibility: an envelope encrypted by the gateway can be decrypted by the iOS widget (and vice versa for FrameCrypto). This is a no-op since the code is identical, but a round-trip integration test confirms it.

---

## Potential Risks and Mitigations

1. **Xcode project file complexity**
   Adding an SPM local package to an `.xcodeproj` requires careful build-phase configuration. The widget extension must also link `PrintPartyKit`.
   *Mitigation:* Use Xcode's "Add Package Dependency" with a local path. Both targets (app + widget) must add `PrintPartyKit` to "Frameworks, Libraries, and Embedded Content."

2. **Gateway's abbreviated `PrintJobState.init` breaks**
   Gateway code that uses the 5-parameter init will still compile if the canonical init has defaults for the missing 13 parameters. Verify no call sites rely on positional-only matching.
   *Mitigation:* The iOS version's init already has defaults for all optional fields, so the 5-parameter call pattern `PrintJobState(printerId:printerDisplayName:printerModel:stage:updatedAt:)` will resolve correctly.

3. **`swift-crypto` version conflicts**
   The gateway already depends on `swift-crypto` 3.0+. If `PrintPartyKit` also declares this dependency, SPM must resolve a compatible version. Since both use `from: "3.0.0"`, there's no conflict.
   *Mitigation:* Use the same version range. On Apple platforms `swift-crypto` is essentially a shim over CryptoKit, so it resolves but adds no meaningful binary.

4. **`EncryptedContentState` naming change in gateway**
   The gateway currently uses `EncryptedEnvelope` (internal). Renaming to `EncryptedContentState` (public, from PrintPartyKit) requires updating `ContentStateEncryptor` references.
   *Mitigation:* A simple find-and-replace. The type is only referenced in `ContentStateEncryptor.swift` and its tests.

5. **CI / Docker builds**
   If CI builds the gateway on Linux, the `PrintPartyKit` package must be resolvable at `../PrintPartyKit` relative to `gateway/`. This may require adjusting CI checkout or working directory.
   *Mitigation:* Ensure the monorepo root is the CI checkout root. The relative path `../PrintPartyKit` from `gateway/` resolves to `PrintPartyKit/` at the repo root.

---

## Alternative Approaches

1. **Workspace-level Package.swift instead of standalone package:** Place a single `Package.swift` at the repo root that defines `PrintPartyKit` as a library and both server executables as targets. This eliminates relative-path dependencies but makes the Xcode integration more complex and couples the server targets together.

2. **Keep duplication, enforce with tests:** Instead of extracting a package, write cross-validation tests that decode the same JSON with both copies and assert equivalence. Lower risk but doesn't eliminate the drift problem long-term.

3. **Git submodule or subtree:** Host `PrintPartyKit` in a separate repository. Overkill for a monorepo — local paths are simpler and the code is already co-located.

**Recommended: Standalone local package (the plan above).** It's the approach the codebase already anticipates (`gateway/Sources/PrintPartyGateway/Domain/PrintJobState.swift:8` — *"When we add a shared SPM package (PrintPartyKit), this moves there."*) and is the simplest path for a monorepo.
