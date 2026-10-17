# Shared IOU protocol — 1.0

This specification describes immutable gold/item agreements, acknowledged financial events, background invitations, and personal-ledger synchronization in IOU 1.0. Existing gold terms and saved records remain compatible. Both players should use 1.0.0 for item terms and background synchronization.

An agreement records player acknowledgment. It does not move gold/items, authenticate an unmodified addon, or prove collection of a mail message. Exact identifiers and term binding prevent accidental or stale mutations; they are not cryptographic authentication.

## Terms and identity

Participants use full character names, preserving surnames, hyphens, and punctuation. Never guess a first name, strip a surname, or trust a GUID supplied by a peer. The native logged event sender establishes the sender. Shared engine participant bindings use exact canonical bytes.

All terms contain ordered `protocol,kind,proposer,recipient,debtor,creditor,amountCopper,dueUTC,note` fields. Debtor and creditor are the two distinct participants. `dueUTC=0` means no deadline; explicit Shared due days use 23:59:59 UTC. Personal due-day semantics are retained when personal records are shared.

| Protocol | Kinds | Additional fields |
| --- | --- | --- |
| 1 | `GOLD_OBLIGATION` | None; amountCopper is positive integer copper. |
| 2 | `GOLD_PAYMENT`, `GOLD_CORRECTION` | Exact original/commit/financial-chain binding below. |
| 3 | `ITEM_OBLIGATION` | `itemKey,itemName`; amountCopper is an integer item quantity. |
| 4 | `ITEM_PAYMENT`, `ITEM_CORRECTION` | Financial binding plus exact itemKey/itemName. |

`itemKey` is the canonical numeric native item payload, not a display-name lookup. Populated variant fields remain part of its identity. UI names are presentation; item quantities must never be formatted as gold. Asset helpers provide a common interface without changing legacy field names.

Repayment comparison ignores only the native payload's viewer-level and specialization fields (positions 9 and 10). Enchantments, gems, suffixes, unique IDs, upgrade/difficulty, bonuses, and every other populated field remain distinct. This comparison does not rewrite stored links, receipt keys, or immutable Shared terms.

A payment/correction contains `parentAgreementId,parentOfferId,parentCommitId,parentTerms,baseRevision,baseChain,reversesId`. The exact original canonical terms, participants, commitment, and complete prior event chain must match retained local evidence. Events keep the original proposer as sequencer. A payment cannot exceed the remaining amount; a correction reverses one confirmed, unreversed payment in full. `dueUTC` is zero for financial events. Blank correction reasons become the existing optional default before consent.

The flat `IOUSC1:` chain records event kind, agreement/offer/commit IDs, amount, note, and reversal target in order. Previous exact event terms are reconstructable from the row and prior prefix. A balance alone, claimed revision, or fingerprint cannot replace that chain.

## Encoding and transport

Terms use protocol-specific `IOUST1:` through `IOUST4:` headers, and logical messages use `IOUSM1:`. Ordered UTF-8 netstrings are `byteLength:value,`. Reject noncanonical integer/length encodings, trailing or extra fields, control text, invalid UTF-8, fractional quantities, and unsupported versions. Retain exact canonical bytes rather than rebuilding consent from display text.

Messages use common `version=1,kind,messageId,agreementId,offerId,revision=1,terms` fields.

| Kind | Binding and effect |
| --- | --- |
| PROPOSE | Exact original or financial terms. A new original has no recipient consent. |
| ACCEPT | Recipient acceptance ID bound to the retained exact offer. |
| COMMIT | Matching acceptance and commit IDs; requires the original offer and acceptance. |
| ACK | Matching acceptance/commit IDs; confirms processing of that commit. |
| DECLINE | Exact terms; valid before recipient acceptance. |
| WITHDRAW | Recorded proposer withdrawal before commitment. |
| OUTCOME | Retained decline/withdrawal outcome, or retained COMMIT if commitment already won the race. |
| STATUS | Requests a retained response; never creates consent. |
| SYNC | Original terms plus `paidAmount,baseRevision,baseChain`; an exact-baseline reconciliation hint, not a financial commitment or acceptance. |

Logged addon WHISPER uses prefix `IOU_SHAREDv1`. Logical data is framed into readable `SW1 <transferId> <part>/<count> <totalBytes>:<text>` packets, each at most 240 UTF-8 bytes without splitting a codepoint. This is a conservative wire budget, not a measurement of the absolute client maximum. A send API success means local submission, never delivery.

The receiver validates event, prefix, channel, sender, size, framing, rate limits, codec, and exact offer/term binding before domain mutation. No partial logical message reaches the engine. There is no unlogged fallback. Actual native lockdown/send errors stop traffic without erasing saved consent.

## Consent, duplicates, and background work

The proposer explicitly sends immutable terms; the recipient explicitly accepts each new original IOU. The normal handshake is PROPOSE → ACCEPT → COMMIT → ACK. A recipient includes an acknowledged financial event on COMMIT; the proposer includes it after exact ACK. Delivery uncertainty can temporarily leave different Shared views.

Process exact and semantic duplicates before new-transition guards. Replay the retained response and IDs; never create a second payment or decision. Reused IDs with changed terms, participants, amounts, or outcomes are conflicts. Unknown ACCEPT/COMMIT traffic cannot reconstruct missing local consent.

Background original proposals first enter a **session-only inbox: 16 total, 12 per sender, five-minute lifetime**. Exact retransmission does not extend expiry. Unaccepted invitations and declined/withdrawn previews cannot fill permanent history. Accept atomically stages original receipt and explicit local acceptance into the saved store before enqueueing. No queue capacity means no promotion or consent. Reload can discard an unaccepted invitation; the sender may retry the same original. Accepted and existing records are never evicted to make room.

Closing windows changes no semantic decision or delivery session. Startup initially pauses unfinished engine records; the coordinator can resume only their exact retained state, consent, terms, and messages. Resume does not accept an undecided original. Automatic retries are bounded and reuse retained payloads. A timeout changes no financial outcome.

SYNC hints are routed separately from consent transitions. A validated hint must refer to an existing acknowledged original, exact terms, exact participant, and current exact chain/revision. It can request a normal sequenced payment/correction exchange; it cannot overwrite a balance. Local observed evidence or deliberate review remains necessary for the resulting decision. A mail send can be a local repayment before collection or peer acknowledgment.

## Personal links and persistence

The pure Shared store remains separate from the personal ledger. A validated sidecar links an accepted original to its ordinary personal record and baseline. Linked reminders/counts avoid counting the same debt twice. New accepted records can be adopted once; older Shared records require deliberate Add to ledger, with safe matching rather than silent duplication. Unlinked or conflicting legacy records remain visible for review. Personal imports must not reuse stale links solely because numeric IDs happen to match.

Local candidate validation and queue preflight precede state replacement. Consent and retained responses are committed in memory before enqueueing. An unexpected enqueue failure returns the saved decision for Retry. Successful reload/logout writes SavedVariables; no per-click disk flush or cross-client atomic commit is promised.

`IOUS1:` recovery retains same-owner/same-character evidence. Staging stops traffic and creates a persistent review gate. Restore adds compatible missing history while retaining existing, current-only, and closed-offer records. Conflicts remain for comparison; a peer message, backup from another character, or claimed acceptance cannot manufacture local consent. Personal `IOU1`/`IOU2` imports remain separate from Shared consent.

## Resource limits

Permanent history holds **128 offers**, including originals and financial events. Limits also include 4096-byte logical messages, 31 prior chain rows, 64-byte identifiers, 96-byte names, 512-byte notes, 32 parts, 32 outbound logical messages/128 packets, one-second send pacing, bounded sender-scoped reassembly, 45-second assembly expiry, and a 120-token/two-per-second receive budget. The complete acceptance envelope must fit before a proposal is admitted. Reaching a limit rejects new work without shortening terms or deleting retained consent.

## Verification status

The 0.3.2 live pilot demonstrated four exact ASCII/UTF-8 diagnostic echoes through 240 bytes and acknowledged gold payment/correction/settlement. The 0.6.0 player report confirmed personal and Shared tooltip/trade reminders. **1.0 item terms, background synchronization, and 0.8/0.9 trade/mail observers remain pending live testing.** Deterministic tests cover drop/duplicate/reorder/conflict cases, queue failures, recovery, transient spam bounds, exact item identity, and UI decisions; they do not establish native delivery or rendering.

See the [development guide](shared-development.md), [player guide](shared-agreements.md), and [short testing guide](manual-testing.md).
