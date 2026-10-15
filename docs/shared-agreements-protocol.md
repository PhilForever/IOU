# Shared Agreements: protocol draft

**DRAFT for the 0.3 development cycle. Not implemented by the connection-test build.**

This replaces the proposed “Accept Protocol v0.2” design. IOU 0.2 already exists. The immediate deliverable is the [connection test](connection-test.md); shared agreements require a separate implementation, simulation, and two-player pilot.

## Scope and trust

The first pilot supports one fixed proposer, one recipient, and an immutable gold obligation between two online characters. Either participant may be the debtor. The proposer explicitly offers the displayed terms; the recipient explicitly accepts those same terms. Counteroffers, shared repayments, amendments, crafting contracts, and automatic trade inference are deferred.

An acknowledged agreement records the players' stated consent. It does not establish that money changed hands, authenticate an unmodified addon, or provide a cryptographic signature. A fingerprint detects accidental disagreement; it is not proof against a modified client.

The personal ledger remains usable without messaging. Shared records have their own UI and storage. Personal Pay, Settle, Edit, Cancel, and Reverse handlers must reject shared record identifiers.

## Transport gate

Use logged addon `WHISPER` messages for user-authored terms, after verifying the API in the target Forever build. The spike must record the actual send return values, receive event, sender spelling, Unicode round trip, and measured packet lengths. Ordinary chat whispers do not establish addon transport behavior.

Check return values against the available named success enum, including numeric zero. Do not interpret an arbitrary truthy value, missing enum, missing function, or `nil` return as success. Send success is local API acceptance, never a delivery receipt. Missing or unsupported APIs leave the personal ledger available.

Use a distinct versioned shared prefix; never interpret test-prefix traffic as proposals. Register once per session and process only the intended logged event and `WHISPER` channel. Do not silently fall back to an unlogged transport for user terms.

The initial send ceiling is 240 **UTF-8 bytes for the complete message**, subject to the live test. It is a chosen budget, not a claim about the client's absolute limit. Validate before enqueueing. No binary compression or opaque encoding of user-authored text.

If complete terms do not fit the verified budget, the first pilot must either reject with an understandable limit before proposing, or implement and test bounded framing separately. Never truncate terms or silently accept a partial proposal. Define framing and field budgets before calling this specification wire-ready.

## Participant identity

Forever's first-name/surname handling must be measured. Do not assume `Name-Realm`, split a name at spaces, strip punctuation, or apply ASCII lowercasing to Unicode names as an identity rule.

Distinguish the user-entered whisper target, local character storage key, displayed name, and received event sender. The event sender is authoritative for which peer sent a packet; a payload's claimed sender is not. Bind an offer to the expected observed peer identifier, using only normalization established by client evidence. An ambiguous name fails closed for acceptance.

Record any realm or GUID information only when the client actually provides it and its stability is established. A peer never supplies a trusted GUID on another player's behalf. Do not accept another character's messages against the current character's ledger.

## Immutable terms and identifiers

Each proposal has `agreementId`, `offerId`, protocol version, and revision `1`. The proposer never changes within an agreement. Editing any term creates a fresh offer ID; in this pilot, replacing an offer requires withdrawing it and creating a new proposal. There is no owner-switching counteroffer transition.

Canonical terms contain these fields, in this order:

| Field | Rule |
| --- | --- |
| `kind` | Literal `GOLD_OBLIGATION`. |
| `proposer`, `recipient` | Both bound participant identifiers. |
| `debtor`, `creditor` | Exactly the two participants, distinct; direction is explicit. |
| `amountCopper` | Positive bounded integer; decimal ASCII, no sign, fraction, exponent, or leading zero. |
| `dueUTC` | Empty, or a validated UTC Unix timestamp in canonical integer form. |
| `note` | Valid UTF-8 plain text, within a defined byte limit; no control bytes or WoW formatting escapes. |

Serialize fields as UTF-8 byte-length-prefixed text in fixed order: `length:value`. Reject noncanonical lengths, trailing data, malformed UTF-8, missing fields, and extra fields. Keep the exact canonical bytes; never regenerate accepted terms through display formatting. The review UI uses those parsed bytes, showing both full names, direction, amount, note, and due time before consent.

A user-selected due day means **23:59:59 UTC on that day**, explicitly labeled in review. Local-time displays also show the UTC value. Existing personal due dates retain their existing local-day meaning; they must not be silently converted to shared dates.

Use locally collision-checked IDs with a session nonce and monotonic counter. They are identifiers, not secrets. Store a fingerprint and byte length for diagnostics, but an acceptance binds exact canonical term bytes. Same ID with different bytes is a conflict even if fingerprints match.

## Logical message schema

This table defines semantics, not final packet syntax. Every message includes version, type, message ID, agreement ID, offer ID, and revision. A retry reuses its original ID and immutable content.

| Type | Direction | Additional binding and effect |
| --- | --- | --- |
| `PROPOSE` | A to B | Complete canonical terms. Creates an unaccepted inbox item only. |
| `ACCEPT` | B to A | Acceptance ID and exact canonical terms. Created only by B's explicit review action. |
| `COMMIT` | A to B | Acceptance ID, commit ID, exact terms. Created once from A's still-open offer and a valid acceptance. |
| `ACK` | B to A | Matching acceptance ID, commit ID, and term binding. Confirms B processed that commit. |
| `DECLINE` | B to A | Exact offer/term binding; valid only before B accepts. Requests terminal decline. |
| `WITHDRAW` | A to B | Exact offer/term binding and outcome ID. A has withdrawn before committing. |
| `OUTCOME` | A to B | Recorded `DECLINED` or `WITHDRAWN` outcome and ID; or the original `COMMIT` when already committed. |
| `STATUS` | Either way | Bounded request/reply with known identifiers and terminal outcome summary; never grants consent. |

All term-bearing messages must compare the full canonical term bytes. Control messages must resolve their binding against the locally retained exact terms; a fingerprint alone cannot introduce or replace terms. Unknown control messages cannot create accepted records. Exact framing, field limits, and readable handling of terms exceeding one packet are required implementation prerequisites.

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
| Either | Any incompatible retained state/content | Enter `NEEDS_REVIEW`; preserve both records for inspection. |

A's local reducer serializes new ACCEPT, DECLINE, and local Withdraw. Whichever valid terminal decision it processes first wins. If A committed first, Withdraw is refused and later DECLINE receives the original COMMIT. If withdrawal or decline won first, a later ACCEPT receives the terminal outcome. B cannot unilaterally undo an ACCEPT while waiting; any cancellation of a committed agreement is a future shared process.

An ACCEPT arriving from B when A lacks the original explicitly sent offer cannot create a COMMIT. A COMMIT arriving at B without B's retained matching local acceptance cannot activate it.

Delivery is independently `QUEUED`, `WAITING_FOR_PEER`, `RETRY_PAUSED`, or `PEER_RECEIPT_OBSERVED`, with the receipt's precise meaning recorded. A can know B processed COMMIT after ACK. B knows it received COMMIT, but cannot know A received its last ACK. Do not label both sides globally “fully synced.” A timeout changes delivery state only; it never means declined, withdrawn, paid, or settled.

## Persistence and recovery

Update the local state, consent evidence, history, deduplication response, and outbound record together in memory before sending. SavedVariables survive normal successful reload/logout, as already tested for the personal ledger. There is no guaranteed per-click disk flush or atomic commit across two clients.

On startup, pause all uncommitted handshakes. Reopening one requires explicit review and a fresh offer ID with fresh acceptance; old messages cannot automatically recommit it. A retained committed record may replay its recorded COMMIT/ACK only if its local terms and consent evidence survived. Keep old offer tombstones so delayed traffic resolves to a stale or recorded terminal result.

If a crash rolls either side back behind known peer state, preserve the mismatch as `NEEDS_REVIEW`. Never reconstruct missing local consent from a peer's COMMIT, STATUS, claimed acceptance, or exported log. Reconfirmation creates a new offer after showing what each side reports; it must not create a second counted obligation beside an unresolved one.

The future shared backup format must include local-role and consent evidence and be explicitly separate from personal `IOU1`/`IOU2` exports. Any shared import or restored snapshot pauses all shared queues and enters manual reconciliation, including previously committed records. Do not resume network actions automatically from a backup.

## Storage, limits, and integration

Use a separate versioned `IOUDB.sharedByCharacter[localCharacterKey]` store. Preserve the existing personal schema and exports. Validate all loaded keys and shapes before use; network IDs are opaque lookup keys, never Lua paths or table field selectors. Do not import network objects directly into database tables or allow unknown keys to overwrite local metadata.

Keep immutable terms, local role, explicit local consent evidence, acceptance/commit/outcome records, append-only history, bounded processed-message responses, tombstones, and a bounded outbox. Storage and UI identifiers must distinguish `personal:<id>` from `shared:<id>`; shared counters do not allocate personal ledger IDs.

Initial resource budgets: 32 pending inbox offers total, 4 per peer, 32 outbound messages total, 240 bytes per packet, and a 64 KiB in-progress framing budget only if framing is later approved. Cap incoming packet frequency per peer and globally before expensive parsing. Blocked peers produce no inbox or auto-popup. Show an inbox count; never auto-accept or repeatedly interrupt gameplay.

Retry only the same immutable payload, no faster than a shared rate-limited queue permits: at most three automatic retries, approximately 3, 10, and 30 seconds after the initial attempt. Then pause for explicit retry or reconciliation. Bound response replay too, so duplicates cannot cause amplification. Queue saturation gives visible feedback and does not discard consent/history.

Retain terminal tombstones while corresponding records exist. A compaction policy may keep compact outcomes instead of full dedupe records; it must never turn an unknown ACCEPT/COMMIT into permission to recreate an agreement. When capacity is reached, pause new proposals and offer explicit archival rather than silently evicting live consent or outcomes.

Do not count drafts or pending offers as debt. Shared accepted balances must be displayed separately until the first shared-balance rules ship. Future conversion from personal to shared must explicitly link and archive the personal entry after confirmed acceptance so the same obligation is counted once. A failed proposal leaves the personal record untouched.

## Release gates

1. **Connection experiment:** two actual clients, exact observed names, ASCII/Unicode and measured-size echo reports, API result handling, blocked/offline behavior, and stopping after reload. A self-test is local preflight only.
2. **Protocol implementation:** a pure state reducer and strict codec, deterministic two-peer simulator, validated storage loading, bounded transport, and invariant tests. Finalize framing after probe evidence.
3. **Failure simulation:** drop, duplicate, delay, reorder, and corrupt every handshake message; inject foreign senders, changed terms under reused IDs, unknown IDs, saturated queues, malformed UTF-8, and missing success enums. Exercise withdrawal/accept races in both orders.
4. **Recovery simulation:** reload and simulated loss of unsaved state after each step, plus restoring old backups. Verify missing consent never activates, duplicates never create debt, and pending UI never claims delivery.
5. **Opt-in two-player pilot:** explicit review, accept/decline/withdraw, matching terms on both clients, readable delivery progress, normal reload/logout, character isolation, and unchanged personal records. Record real outcomes before a public shared-agreement release.
6. **Later work:** mutually acknowledged payments and correction events determine a shared balance. Add amendments, trade assistance, and crafting only after that foundation is tested. Shared payment UI must distinguish player acknowledgment from independently verified transfer.

## Client reference pointers

These pinned client sources guide the experiment; their presence alone does not establish live transport behavior:

- [ChatInfo API declarations](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatInfoDocumentation.lua).
- [Chat result enums](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatConstantsDocumentation.lua).
- [Forever naming utilities](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_FrameXMLUtil/Camelot/NameUtil.lua).
