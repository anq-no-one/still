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
| A lost device that still holds old key material | Revocation rotates the account key and every project key and re-seals the local Library, so later records open only with the new keys | `aRevokedDeviceCannotReadAnythingWrittenAfterwards`, `aRevokedMacCannotReadWhatIsRecordedAfterTheRevocation` |
| A replayed or duplicated sync change | Merge is order-independent and idempotent over field values | `duplicateAndReorderedDeliveryReachTheSameResult` |
| Concurrent edits on two devices | Generated content follows the newer pass; user-authored text is unioned, never dropped | `threeDevicesConvergeOnTheSameRecording` |
| A deletion arriving before an older copy | Tombstones match on every stored Recording, so an older copy merges into the deletion | `aDeletionIsNotResurrectedByAnOlderCopy` |
| Readable leftovers after deletion | Purge removes the record and its chunks; orphan audio is swept on unlock | `purgedContentLeavesNothingReadableBehind` |
| A killed process mid-write | Chunks are written atomically and authenticated, so a damaged tail is dropped rather than read | `anInterruptedAudioTransferLeavesNoHalfWrittenChunk` |
| A revocation interrupted part way | The replacement key is written beside the old one and only promoted once every Recording and chunk is re-sealed | `RotationSafetyTests` |
| A Mac that excludes a project | Each project, and No Project, has its own random key. Recording payloads and synced audio are sealed with it, so the account key alone opens only project names and colors. A device downloads payloads only for the projects it holds | `anExcludedMacReceivesNothingOfAProject` |
| A forged or replayed key grant | Grants use HPKE in authenticated mode, bound to the recipient and project. A device accepts a project key only from a device the account vouches for | `aTamperedGrantIsRejected`, `aGrantFromAnUntrustedDeviceIsIgnored` |
| A new device joining the wrong account | Both screens show a nine-digit code derived from both device keys, and both users confirm it before any key moves | `bothScreensShowTheSameCodeBeforeJoining` |
| A project turned off before its only copy left the Mac | The Mac keeps the project's recordings and key until another device holds the project and the cloud has every confirmed copy. No deletion is ever pushed | `aProjectLeavesAMacOnlyAfterAnotherDeviceHasEveryCopy`, `aLoneHolderNeverDropsItsOnlyCopy` |
| A generated statement with no evidence | Extracted decisions, facts and tasks are kept only when every cited segment exists and its words support the statement; the rest are withheld and only counted. They are sealed inside the Recording and stay marked automatically extracted until the user confirms them | `ProvenanceTests`, `MemoryExtractionTests` |
| A reprocessed or synced Recording erasing a user's review | Each extracted item has a stable identity; reviews and edits merge field by field by their own timestamps and survive a newer extraction pass | `aUserEditSurvivesReprocessing`, `aRegeneratedRunFromAnotherDeviceKeepsTheUsersDecisions` |
| Content leaking through diagnostics | Reports have no free-text field; the event name comes from a closed set | `DiagnosticsTests` |
| Unnoticed network use | A test names every file allowed to reach the network and fails on any other | `NetworkBoundaryTests` |

## Residual risks

- **Metadata is not encrypted.** Creation time, duration, and the existence of a Recording are
  stored and synced in the clear. Someone with the CloudKit records learns when and how long you
  recorded, never what was said.
- **Merge preserves text by joining it.** Two devices that rename the same Recording produce a
  title holding both names. Nothing is lost, but the result needs a human to tidy.
- **Revocation rotates the Library key, not the device key.** What locks a lost device out is that
  everything is re-sealed under a key it never held. Replacing this device's own keychain key would
  add nothing and, done first, would have destroyed the Library if the rotation were interrupted.
- **Revocation is not retroactive.** A device that copied ciphertext before revocation keeps
  whatever it already had. Rotation protects everything written afterwards, not the past.
- **Device and project ids are not encrypted.** A device record lists its kind (Mac, iPhone, iPad),
  its public key, and the random ids of the projects it requests and holds. Names stay sealed.
- **The join code has no commitment round.** Someone who controls the iCloud records could try to
  grind device keys until a nine-digit code matches. The code passes through 400,000 rounds of
  PBKDF2, so each guess costs a key pair plus that work, which puts a match out of practical reach
  without making it impossible.
- **Revocation does not reach the past.** A revoked device keeps whatever it already downloaded.
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
