# Shared Agreements: protocol draft

**Experimental Shared specification for IOU 0.3.0. The normal Release includes acknowledged payments and payment reversals, framed transport, per-character storage, and consent UI; actual client behavior remains unverified.**

This replaces the proposed “Accept Protocol v0.2” design. IOU 0.2 already exists. The pure codec and state engine model explicit acceptance, commitment, decline, withdrawal, retries, and paused recovery. The opt-in service and UI support obligations and acknowledged financial events. See the [development API](shared-development.md) and [player guide](shared-agreements.md). The optional [connection test](connection-test.md) remains available when live delivery testing resumes. Shared backup/import remains future work.

## Scope and trust

The pilot supports one fixed proposer, one recipient, and an immutable gold obligation between two online characters. Either participant may be the debtor. The proposer explicitly offers the displayed terms; the recipient explicitly accepts those same terms. The original proposer also sequences payment and full payment-reversal child offers, each requiring explicit acceptance. Counteroffers, amendments, crafting contracts, and automatic trade inference are deferred.

An acknowledged agreement records the players' stated consent. It does not establish that money changed hands, authenticate an unmodified addon, or provide a cryptographic signature. A fingerprint detects accidental disagreement; it is not proof against a modified client.

The personal ledger remains usable without messaging. Shared records have their own UI and storage. Personal Pay, Settle, Edit, Cancel, and Reverse handlers must reject shared record identifiers.

## Transport gate

Use logged addon `WHISPER` messages for user-authored terms, after verifying the API in the target Forever build. The spike must record the actual send return values, receive event, sender spelling, Unicode round trip, and measured packet lengths. Ordinary chat whispers do not establish addon transport behavior.

Check return values against the available named success enum, including numeric zero. Do not interpret an arbitrary truthy value, missing enum, missing function, or `nil` return as success. Send success is local API acceptance, never a delivery receipt. Missing or unsupported APIs leave the personal ledger available.

Use a distinct versioned shared prefix; never interpret test-prefix traffic as proposals. Register once per session and process only the intended logged event and `WHISPER` channel. Do not silently fall back to an unlogged transport for user terms.

The initial send ceiling is 240 **UTF-8 bytes for the complete message**, subject to the live test. It is a chosen budget, not a claim about the client's absolute limit. Validate before enqueueing. No binary compression or opaque encoding of user-authored text.

Alpha.3 frames up to 4096 bytes of logical text into at most 32 UTF-8-safe packets under `IOU_SHAREDv1`. Each packet has a readable `SW1` transfer/part/count/total header and stays within the chosen 240-byte ceiling. Reassembly is peer scoped, bounded to 8 active/8 cached transfers and 32 KiB, and expires at 45 seconds. Conflicts never reach the engine. Automated checks establish framing behavior; the real client's transport ceiling and event behavior remain unverified. Terms are never truncated.

## Participant identity

Forever's first-name/surname handling must be measured. Do not assume `Name-Realm`, split a name at spaces, strip punctuation, or apply ASCII lowercasing to Unicode names as an identity rule.

Distinguish the user-entered whisper target, local character storage key, displayed name, and received event sender. The event sender is authoritative for which peer sent a packet; a payload's claimed sender is not. Bind an offer to the expected observed peer identifier, using only normalization established by client evidence. An ambiguous name fails closed for acceptance.

Record any realm or GUID information only when the client actually provides it and its stability is established. A peer never supplies a trusted GUID on another player's behalf. Do not accept another character's messages against the current character's ledger.

## Immutable terms and identifiers

Each proposal has `agreementId`, `offerId`, protocol version, and revision `1`. The proposer never changes within an agreement. Editing any term creates a fresh offer ID; in this pilot, replacing an offer requires withdrawing it and creating a new proposal. There is no owner-switching counteroffer transition.

Canonical terms contain these fields, in this order:

| Field | Rule |
| --- | --- |
| `protocol` | Integer `1`, serialized first. |
| `kind` | Literal `GOLD_OBLIGATION`. |
| `proposer`, `recipient` | Both bound participant identifiers. |
| `debtor`, `creditor` | Exactly the two participants, distinct; direction is explicit. |
| `amountCopper` | Positive bounded integer; decimal ASCII, no sign, fraction, exponent, or leading zero. |
| `dueUTC` | Integer `0` means no deadline; otherwise a validated UTC Unix timestamp in canonical integer form. |
| `note` | Valid UTF-8 plain text, within a defined byte limit; no control bytes or WoW formatting escapes. |

The implemented canonical terms format starts with `IOUST1:` and serializes those fields in fixed order as comma-terminated UTF-8 netstrings: `length:value,`. Lengths count bytes. The logical message format uses `IOUSM1:` with the same netstring convention. Reject noncanonical lengths, trailing data, malformed UTF-8, missing fields, and extra fields. Keep the exact canonical bytes; never regenerate accepted terms through display formatting. The review UI uses those parsed bytes, showing both full names, direction, amount, note, and due time before consent, and rechecks the selected terms/state/peer before confirming.

A user-selected due day means **23:59:59 UTC on that day**, explicitly labeled in review. Local-time displays also show the UTC value. Existing personal due dates retain their existing local-day meaning; they must not be silently converted to shared dates.

The pure API requires caller-supplied agreement and offer IDs, rejects any reuse in its store, and generates message and semantic IDs from a local monotonic counter. Incoming IDs are scoped to the exact peer and offer; they are identifiers, not secrets. The service allocates collision-checked agreement/offer IDs from a per-character nonce and persisted counter. Acceptance binds exact canonical term bytes; fingerprints can be added for diagnostics but cannot replace exact comparison. Same offer ID with different bytes is a rejected conflict.

## Payment and correction terms

An event is a fresh offer using the same explicit PROPOSE/ACCEPT/COMMIT/ACK handshake. Its proposer and participants must match the original obligation. Only that original proposer sequences events, including when the proposer is the debtor. Both peers should use 0.3.0; protocol-1 obligation bytes remain unchanged.

Event terms use `protocol=2`, `kind=GOLD_PAYMENT` or `GOLD_CORRECTION`, and the `IOUST2:` header. After the common fields above, exact ordered fields are `parentAgreementId,parentOfferId,parentCommitId,parentTerms,baseRevision,baseChain,reversesId`. `dueUTC` must be zero. The parent IDs, commitment, complete original canonical terms, and participants are checked against retained local consent.

`baseChain` starts with `IOUSC1:` and contains a bounded dense array of flat rows in exact order: `kind,agreementId,offerId,commitId,amountCopper,note,reversesId`. These include all event-specific semantics. Each prior event's complete terms can be reconstructed from its row and preceding prefix; recursive embedding is avoided. A balance alone or a fingerprint cannot replace exact chain comparison. Missing, changed, reordered, or conflicting local evidence rejects an event. The 4096-byte complete logical-message ceiling still applies; terms are never shortened to fit.

The parent and latest event must be acknowledged before the proposer can initiate another event. A recipient includes an event in the derived balance on COMMIT; a proposer includes it only upon the exact ACK. A missing ACK may temporarily leave different displayed balances, with further proposer events blocked. Duplicate delivery reuses retained responses and never applies an amount twice. Only one unresolved child may target a parent; a paused child blocks a successor until explicitly reviewed locally after reconciliation.

A payment is positive integer copper no greater than the remaining amount. A correction requires a nonblank reason, targets one preceding confirmed and unreversed payment by offer ID, and reverses its full amount. Partial reversal, double reversal, and correction of a correction are rejected. Correcting a settlement reopens its amount. The service validates this financial graph on load and before any persistence, while personal totals and backup formats stay separate.

## Logical message schema

This table defines logical semantics, not final packet syntax. The implemented common fields are `version=1`, `kind`, `messageId`, `agreementId`, `offerId`, `revision=1`, and `terms` containing exact canonical terms bytes. A retry reuses its original ID and immutable content.

| Type | Direction | Additional binding and effect |
| --- | --- | --- |
| `PROPOSE` | A to B | Complete canonical terms. Creates an unaccepted inbox item only. |
| `ACCEPT` | B to A | Acceptance ID and exact canonical terms. Created only by B's explicit review action. |
| `COMMIT` | A to B | Acceptance ID, commit ID, exact terms. Created once from A's still-open offer and a valid acceptance. |
| `ACK` | B to A | Matching acceptance ID, commit ID, and term binding. Confirms B processed that commit. |
| `DECLINE` | B to A | Exact offer/term binding; valid only before B accepts. Requests terminal decline. |
| `WITHDRAW` | A to B | `outcomeId`; withdrawal is implicit. A has withdrawn before committing. |
| `OUTCOME` | A to B | Recorded `DECLINED` or `WITHDRAWN` outcome and ID; or the original `COMMIT` when already committed. |
| `STATUS` | Either way | Common fields only: requests the current retained response for a known offer. The reply reuses that proposal, acceptance, commit, acknowledgment, or terminal outcome; never grants consent. |

All term-bearing messages compare the full canonical term bytes. Control messages resolve their binding against the locally retained exact terms; a fingerprint alone cannot introduce or replace terms. Unknown control messages cannot create accepted records. The bounded logical codec and readable packet framing enforce limits before the engine receives a complete message.

## Processing order and idempotency

For each received message, perform these steps in order:

1. Enforce prefix, event, channel, byte ceiling, parser limits, supported version, and sender binding.
2. Look up the scoped offer, immutable content, and processed-message record. A reused message or offer ID with different content is a conflict, not a duplicate.
3. Handle a recognized exact duplicate using its recorded response **before** checking guards for a new transition. Duplicate ACCEPT replays the original COMMIT or terminal OUTCOME. Duplicate COMMIT replays the same ACK. No new history or obligation is created.
4. For a genuinely new message, check role, exact terms, local consent evidence, and current transition guard. Apply the transition and record its immutable response before enqueueing it.
5. Reject malformed, foreign, stale, unexpected, or conflicting input without replacing local terms. Rate-limit error responses; do not reply to arbitrary unknown traffic.

Never make a replacement COMMIT for a duplicate ACCEPT. Do not use a general “must be OFFER_SENT” guard to reject a duplicate of an acceptance already committed.

Deduplicate by semantic IDs as well as message ID: a known acceptance ID, commit ID, or outcome ID must retain its original content even if retransmitted in another envelope. A new acceptance for an already terminal offer cannot create another obligation.

## Agreement state and delivery state

Store the semantic state separately from delivery progress:

| Role | Semantic state | Trigger and next state |
| --- | --- | --- |
| A | `DRAFT` | Explicit Send freezes terms and enters `OFFER_OPEN`. |
| B | `OFFER_RECEIVED` | Explicit Accept records exact local consent and enters `ACCEPT_PENDING`. |
| A | `OFFER_OPEN` | Valid new ACCEPT records consent plus one COMMIT; enters `COMMITTED`. |
| B | `ACCEPT_PENDING` | Matching COMMIT plus retained local ACCEPT enters `COMMITTED`; enqueue ACK. |
| A | `OFFER_OPEN` | Local Withdraw enters `WITHDRAWN`; new ACCEPT is rejected with that outcome. |
| B | `OFFER_RECEIVED` | Explicit Decline enters `DECLINE_PENDING`; terminal outcome makes it `DECLINED`. |
| A | `OFFER_OPEN` | Valid DECLINE enters `DECLINED`; return recorded outcome. |
| Either | Incompatible retained state/content | Reject with an error and leave the input store untouched; explicit reconciliation remains future work. |

A's local reducer serializes new ACCEPT, DECLINE, and local Withdraw. Whichever valid terminal decision it processes first wins. If A committed first, Withdraw is refused and later DECLINE receives the original COMMIT. If withdrawal or decline won first, a later ACCEPT receives the terminal outcome. B cannot unilaterally undo an ACCEPT while waiting; any cancellation of a committed agreement is a future shared process.

An ACCEPT arriving from B when A lacks the original explicitly sent offer cannot create a COMMIT. A COMMIT arriving at B without B's retained matching local acceptance cannot activate it.

Delivery is independently `QUEUED`, `WAITING_FOR_PEER`, `RETRY_PAUSED`, or `PEER_RECEIPT_OBSERVED`, with the receipt's precise meaning recorded. A can know B processed COMMIT after ACK. B knows it received COMMIT, but cannot know A received its last ACK. Do not label both sides globally “fully synced.” A timeout changes delivery state only; it never means declined, withdrawn, paid, or settled.

## Persistence and recovery

Update the local state, consent evidence, history, deduplication response, and outbound record together in memory before sending. SavedVariables survive normal successful reload/logout, as already tested for the personal ledger. There is no guaranteed per-click disk flush or atomic commit across two clients.

On startup, pause all uncommitted handshakes. Reopening one requires explicit review and a fresh offer ID with fresh acceptance; old messages cannot automatically recommit it. A retained committed record may replay its recorded COMMIT/ACK only if its local terms and consent evidence survived. Keep old offer tombstones so delayed traffic resolves to a stale or recorded terminal result.

If a crash rolls either side back behind known peer state, never reconstruct missing local consent from a peer's COMMIT, STATUS, claimed acceptance, or exported log. The implemented engine rejects incompatible input without changing its store. A future explicit reconciliation workflow must retain and explain the mismatch before reconfirming. It must not create a second counted obligation beside an unresolved one. The foundation has no automatic merge or persisted `NEEDS_REVIEW` transition.

The future shared backup format must include local-role and consent evidence and be explicitly separate from personal `IOU1`/`IOU2` exports. Any shared import or restored snapshot pauses all shared queues and enters manual reconciliation, including previously committed records. Do not resume network actions automatically from a backup.

## Storage, limits, and integration

The service uses a separate versioned wrapper under `IOUDB.sharedByCharacter[localCharacterKey]`, containing the pure engine store, closed-paused review markers, a nonce, and an allocation counter. The engine itself performs no I/O. Existing personal schema and exports stay unchanged. Loaded wrapper keys, owner, timestamps, counters, terms, and consent evidence are validated before use; invalid data is left untouched. Network IDs are opaque lookup keys, never Lua paths or table field selectors. Network objects never overwrite local wrapper metadata.

Keep immutable terms, local role, explicit local consent evidence, acceptance/commit/outcome records, append-only history, bounded processed-message responses, tombstones, and a bounded outbox. Storage and UI identifiers must distinguish `personal:<id>` from `shared:<id>`; shared counters do not allocate personal ledger IDs.

Implemented resource budgets: 32 retained offers total, 4 unreviewed proposals per enabled peer, 32 outbound logical messages/128 packets, 240 bytes per packet, and 32 KiB of reassembly storage. Only one explicitly enabled peer is accepted. A 120-token receive bucket refills at two tokens per second before packet parsing. Other senders produce no inbox or auto-popup. The paged list shows an offer count; it never auto-accepts or interrupts gameplay with incoming popups.

IOU uses explicit Retry only, with the same retained immutable payload/IDs and a one-packet-per-second queue. Duplicate processing may replay an existing response but never creates another decision; queue limits and receive rate limits bound those responses. Queue saturation gives visible feedback before state replacement. An unexpected enqueue failure after saving returns the saved offer for Retry instead of inviting a second proposal. Any future automatic retry policy must remain bounded and must not reinterpret timeout as a semantic outcome.

Retain terminal tombstones while corresponding records exist. A compaction policy may keep compact outcomes instead of full dedupe records; it must never turn an unknown ACCEPT/COMMIT into permission to recreate an agreement. When capacity is reached, pause new proposals and offer explicit archival rather than silently evicting live consent or outcomes.

Do not count drafts or pending offers as debt. Shared balances are displayed separately from personal totals. Future conversion from personal to shared must explicitly link and archive the personal entry after confirmed acceptance so the same obligation is counted once. A failed proposal leaves the personal record untouched.

## Validation plan and remaining evidence

1. **Connection experiment:** two actual clients, exact observed names, ASCII/Unicode and measured-size echo reports, API result handling, blocked/offline behavior, and stopping after reload. A self-test is local preflight only.
2. **Protocol implementation:** a pure state reducer and strict codec, deterministic two-peer simulator, validated storage loading, bounded transport, and invariant tests. IOU 0.3.0 implements this path with conservative framing; real client transport behavior remains unverified.
3. **Failure simulation:** drop, duplicate, delay, reorder, and corrupt every handshake message; inject foreign senders, changed terms under reused IDs, unknown IDs, saturated queues, malformed UTF-8, and missing success enums. Exercise withdrawal/accept races in both orders.
4. **Recovery simulation:** reload and simulated loss of unsaved state after each step, plus restoring old backups. Verify missing consent never activates, duplicates never create debt, and pending UI never claims delivery.
5. **Opt-in two-player pilot:** explicit review, accept/decline/withdraw, matching terms on both clients, readable delivery progress, normal reload/logout, character isolation, and unchanged personal records. Record real outcomes when live testing resumes; simulation results do not establish client compatibility.
6. **Payment foundation:** IOU 0.3.0 includes mutually acknowledged payments and full payment-reversal events with derived balances, exact historical binding, and simulation coverage. Shared payment UI distinguishes player acknowledgment from independently verified transfer. Dedicated shared backup/reconciliation, amendments, trade assistance, and crafting remain later work. Live testing is deferred. Normal Release distribution does not change the recorded evidence: actual client delivery, rendering, and shared persistence remain unverified.

## Client reference pointers

These pinned client sources guide the experiment; their presence alone does not establish live transport behavior:

- [ChatInfo API declarations](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatInfoDocumentation.lua).
- [Chat result enums](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatConstantsDocumentation.lua).
- [Forever naming utilities](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_FrameXMLUtil/Camelot/NameUtil.lua).
