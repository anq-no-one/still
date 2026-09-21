# Security review

Scope: the encrypted Library, recovery and revocation, iCloud and nearby synchronization,
retention, and deletion. It records what Still defends against, how, and what it does not defend
against.

## Threats and mitigations

| Threat | Mitigation | Verified by |
|---|---|---|
| App files copied off a device | Structured content and audio are sealed with AES-GCM under a master key the file system does not hold | `EncryptedRecordingRepositoryTests`, `AudioChunkStoreTests` |
| Someone picking up an unlocked device | The master key is wrapped by a Keychain device key released through Face ID or Touch ID | `LibraryKeyRingTests` |
| Wrong key or tampered ciphertext | AES-GCM authentication fails closed; stored records are untouched | `LibraryCipherTests`, `SecurityAndSyncGateTests` |
| Apple, or anyone with the CloudKit records | Only sealed payloads and ordering metadata are pushed | `noTransportEverCarriesPlaintext` |
| A lost device that still holds old key material | Revocation rotates the key and re-seals everything | `aRevokedDeviceCannotReadAnythingWrittenAfterwards` |
| A replayed or duplicated sync change | Merge is order-independent and idempotent over field values | `duplicateAndReorderedDeliveryReachTheSameResult` |
| Concurrent edits on two devices | Generated content follows the newer pass; user-authored text is unioned, never dropped | `threeDevicesConvergeOnTheSameRecording` |
| A deletion arriving before an older copy | Tombstones match on every stored Recording, so an older copy merges into the deletion | `aDeletionIsNotResurrectedByAnOlderCopy` |
| Readable leftovers after deletion | Purge removes the record and its chunks; orphan audio is swept on unlock | `purgedContentLeavesNothingReadableBehind` |
| A killed process mid-write | Chunks are written atomically and authenticated, so a damaged tail is dropped rather than read | `anInterruptedAudioTransferLeavesNoHalfWrittenChunk` |
| Content leaking through diagnostics | Reports have no free-text field; the event name comes from a closed set | `DiagnosticsTests` |
| Unnoticed network use | A test names every file allowed to reach the network and fails on any other | `NetworkBoundaryTests` |

## Residual risks

- **Metadata is not encrypted.** Creation time, duration, and the existence of a Recording are
  stored and synced in the clear. Someone with the CloudKit records learns when and how long you
  recorded, never what was said.
- **Merge preserves text by joining it.** Two devices that rename the same Recording produce a
  title holding both names. Nothing is lost, but the result needs a human to tidy.
- **Revocation is not retroactive.** A device that copied ciphertext before revocation keeps
  whatever it already had. Rotation protects everything written afterwards, not the past.
- **A recovery code is the whole key.** Anyone holding it can open the Library, and Still cannot
  tell whether it was written down safely.
- **The device key rests on Keychain and biometric enforcement.** A jailbroken or compromised OS
  breaks that boundary, and no application-level design can restore it.

## Recovery boundaries

- The recovery code is shown once and never stored in readable form. Losing it with no other
  unlocked device means the Library cannot be opened. There is no back door, and Still says so
  instead of implying a recovery path it does not have.
- A deleted Recording stays restorable for thirty days, the same window on every device, and is
  then purged with its audio.

## Not verified here

These need physical devices or an Apple Developer team and are open:

- A CloudKit capture from a provisioned container, rather than the transport seam.
- Keychain and LocalAuthentication behavior on real hardware, including a wiped biometric enrolment.
- Nearby sync between two machines over Network.framework.
