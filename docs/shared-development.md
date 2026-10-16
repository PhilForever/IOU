# Shared Agreements development

Version **0.3.0** includes `IOU.SharedCodec`, `IOU.Shared`, and `IOU.SharedPayments`, plus the wire, persistence service, and opt-in consent/payment UI developed in the preceding prereleases. The pure modules perform no network traffic, file access, UI work, or `IOUDB` access. They obtain no clock values: callers supply integer timestamps.

The personal ledger remains separate. See the [player guide](shared-agreements.md) for the current experimental UI and the [protocol specification](shared-agreements-protocol.md) for invariants and remaining work. Live client behavior remains unverified.

## State API

| Function | Result |
| --- | --- |
| `Shared.New(localName)` | New empty store, or `nil, error`. |
| `Shared.Validate(store)` | `true`, or `nil, error`. Does not modify the store. |
| `Shared.Propose(store, terms, agreementId, offerId, now)` | Record the local proposer's explicit offer. |
| `Shared.Receive(store, sender, message, now)` | Validate and process an exact peer's logical message. |
| `Shared.Accept(store, offerId, now)` | Record the recipient's explicit consent to the retained terms. |
| `Shared.Decline(store, offerId, now)` | Decline a received offer before accepting. |
| `Shared.Withdraw(store, offerId, now)` | Withdraw a local proposal before commitment. |
| `Shared.Pause(store, now)` | Pause all uncommitted handshakes; retain committed and terminal records. |
| `Shared.Retry(store, offerId, now)` | Return the retained response without inventing a new consent or message ID. |
| `Shared.Snapshot(store[, offerId])` | Independent copy of the whole store or one offer, or `nil, error`. |

Every mutation returns **`newStore, actions`** on success, or **`nil, error`** on rejection. It leaves the input store untouched in either case. Actions form an array of `{target=fullName, message=logicalMessage}`; an empty array is valid. Actions and received messages do not alias retained records. Callers must replace their store only after success.

No action is sent automatically. `Receive` must eventually receive the sender established by the client event, rather than a sender asserted inside a payload. This offline API uses exact participant bytes; transport identity normalization is still subject to live evidence.

Stores hold at most **32 retained offers**. Reaching capacity rejects new work without evicting history. Agreement and offer IDs are caller supplied, 1–64 ASCII letters, digits, underscores, or hyphens, and cannot be reused within a store. Message, acceptance, commit, and outcome IDs use the store's monotonic counter. Received message and semantic IDs are bound to their peer and offer; they are not authentication tokens.

Offer states are `OFFER_OPEN`, `OFFER_RECEIVED`, `ACCEPT_PENDING`, `DECLINE_PENDING`, `COMMITTED`, `DECLINED`, `WITHDRAWN`, and `PAUSED`. Delivery progress is a separate field. An acknowledgment tells the proposer that the recipient processed its commit; it does not establish that money changed hands.

The service calls `Pause` on startup and disconnect before allowing shared work to resume. Paused offers cannot automatically retry or accept. Local reviewed-offer tombstones preserve old evidence, and unresolved paused offers block replacements with the same peer. A peer message never restores missing local consent. Shared backup/import remains unimplemented.

## Codec API

| Function | Result |
| --- | --- |
| `SharedCodec.ValidateTerms(terms)` | `true`, or `nil, error`. |
| `SharedCodec.CanonicalTerms(terms)` | Exact canonical bytes, or `nil, error`. |
| `SharedCodec.ParseTerms(bytes)` | Validated terms table, or `nil, error`. |
| `SharedCodec.ValidateMessage(message)` | `true`, or `nil, error`. |
| `SharedCodec.Encode(message)` | Logical message bytes, or `nil, error`. |
| `SharedCodec.Decode(bytes)` | Validated logical message, or `nil, error`. |

Terms have exactly `protocol=1`, `kind="GOLD_OBLIGATION"`, `proposer`, `recipient`, `debtor`, `creditor`, `amountCopper`, `dueUTC`, and `note`. The debtor and creditor are the two distinct exact participants. `dueUTC=0` means no deadline; other supported values are UTC Unix timestamps. Names and notes must be valid plain UTF-8. The codec rejects extra fields, control text, malformed UTF-8, fractional money, and noncanonical encodings.

The readable netstring formats start with `IOUST1:` for terms and `IOUSM1:` for logical messages, using comma-terminated `length:value,` fields. Logical data is bounded to 4096 bytes; names to 96 bytes and notes to 512 bytes. `SharedWire` frames that logical text into separate packets of at most 240 bytes without splitting UTF-8 codepoints.

## Wire and service

`SharedWire.Enable(peer, receiver)` explicitly enables one exact full name; `Disable()` clears pending packets and incomplete transfers. `CanQueue(actions)` validates capacity without sending, and `Send(actions)` only enqueues. A driver sends at most one packet per second through `SendAddonMessageLogged`/`WHISPER` and receives only the matching logged event and prefix `IOU_SHAREDv1`.

Version 0.3.1 treats `AreOutgoingAddonChatMessagesRestricted` as diagnostic context, not a blanket veto on the logged API. The flag is not a reliable availability check on Forever; [primary beta test notes](https://github.com/Vikquick/Campkeeper/blob/main/docs/testing/beta-checklist.md) record working addon round trips while it was true. The [70425 API declarations](https://github.com/Gethe/wow-ui-source/blob/b401e0332adfbf0460d319b06d8ea29279a941f1/Interface/AddOns/Blizzard_APIDocumentationGenerated/ChatInfoDocumentation.lua) describe the ordinary logged API separately from tournament-only commentator messaging. IOU keeps `InChatMessagingLockdown` and actual native return/error enforcement, without a fallback API. Those sources do not establish logged-whisper delivery on this build; exact peer echoes remain required evidence. Diagnostic reports capture both flags and failed explicit attempts without registering or sending from `GetReport`.

Packets have readable `SW1 <transferId> <part>/<count> <totalBytes>:<text>` headers. Parts use two-digit indices. Limits are 32 parts per 4096-byte logical message, 8 incomplete plus 8 cached transfers, 32 KiB receive storage, a 45-second expiry, and 32 logical/128 packet outbound capacity. Incoming exact-peer traffic passes a 120-token bucket with two tokens replenished per second. Conflicting fragments are rejected; no partial message reaches the engine. There are no automatic retries.

`SharedService` provides `Initialize`, `Enable(peer)`, `Disable`, `IsEnabled`, `GetPeer`, `GetStatus`, `List`, `GetOffer`, `GetStore`, `Propose`, `Accept`, `Decline`, `Withdraw`, `Retry`, and `ClosePaused`. Propose fields are `{peer, direction="owed"|"owe", amountCopper, dueUTC, note}`. Mutations return a detached offer snapshot or `nil,error`. An unexpected failure after saving also returns the saved offer as a third result; callers must offer Retry instead of creating another proposal.

The per-character wrapper is `{version=1, store, closedPaused, nonce, counter}` under `IOUDB.sharedByCharacter[IOU.Character()]`. The existing personal key stays unchanged. Exact owner, schema, bounded timestamps, counters, engine evidence, and local review markers are validated before use. Queue capacity is checked before replacing the stored candidate; local consent is saved in memory before packets are enqueued. Native send errors cannot erase that consent.

Only one peer is enabled per session; receiving a proposal never accepts it or opens a popup. The inbox permits at most four unreviewed proposals from the peer and 32 retained offers overall. Startup never enables the wire or replays a queue. Unexpected transport stops require paused recovery before reconnecting. If the wall clock is temporarily unusable, recovery stays blocked until a valid timestamp is available; no history time or consent is invented.

## Small simulation

This example assumes the addon modules have been loaded into the same `IOU` namespace. The test harness creates isolated namespaces and does not require WoW.

```lua
local S = IOU.Shared
local a = assert(S.New("Ada Ash"))
local b = assert(S.New("Ben Birch"))
local terms = {
    protocol=1, kind="GOLD_OBLIGATION",
    proposer="Ada Ash", recipient="Ben Birch",
    debtor="Ben Birch", creditor="Ada Ash",
    amountCopper=250000, dueUTC=0, note="Mount training",
}
local function must(store, actionsOrError)
    assert(store, actionsOrError)
    return store, actionsOrError
end
local actions
a, actions = must(S.Propose(a, terms, "demo_agreement", "demo_offer", 1))
b = must(S.Receive(b, "Ada Ash", actions[1].message, 2))
b, actions = must(S.Accept(b, "demo_offer", 3))
a, actions = must(S.Receive(a, "Ben Birch", actions[1].message, 4))
b, actions = must(S.Receive(b, "Ada Ash", actions[1].message, 5))
a = must(S.Receive(a, "Ben Birch", actions[1].message, 6))
assert(a.offers.demo_offer.state == "COMMITTED")
assert(b.offers.demo_offer.state == "COMMITTED")
```

The returned stores are caller-owned snapshots. Modifying one does not modify an older store, but callers should use the API and `Validate` instead of editing internal consent or history fields.

## Run the simulator

From the repository root, with Python and the development dependency installed:

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
```

`tools/test_shared.lua` covers the codec and two independent stores, dropped and duplicated messages, reordered terminal outcomes, spoofed roles and senders, changed terms, bounded records, and loss of local consent. It also verifies that the foundation cannot invoke network or game APIs and that input stores remain unchanged on rejection.

Next work includes dedicated shared backup/reconciliation, followed by broader agreement kinds. Actual logged-whisper delivery, Forever sender identity, rendering, and client persistence remain unverified; record live evidence separately from simulations when testing resumes.

## Shared payment domain

`SharedPayments.View(store,parentId,closedPaused)` derives `{originalCopper,paidCopper,remainingCopper,state,events,pendingOfferId,awaitingAck,canPropose,blockReason,baseChain,baseRevision}`. `Validate(store,closedPaused)` validates cross-record financial invariants. `BuildPayment(store,parentId,amount,note,closedPaused)` and `BuildCorrection(store,parentId,paymentId,reason,closedPaused)` build exact protocol-2 terms; they do not mutate stores. The service exposes `GetBalance(parentId)`, `ProposePayment(parentId,amount,note)`, and `ProposeCorrection(parentId,paymentId,reason)` with the same detached-result/third-saved-offer failure contract as `Propose`.

The existing handshake handles payment and correction child offers. Only the original parent proposer initiates them. The parent's commitment and latest event must be acknowledged before the next event. A proposer includes an event only after `PEER_RECEIPT_OBSERVED`; a recipient includes it on `COMMITTED`. Thus a lost ACK deliberately leaves temporary balance asymmetry. Exact duplicate commits and acknowledgments validate their historical prefix and cannot count twice. One unresolved child, including an unreviewed paused child, blocks a successor.

Legacy protocol-1 `GOLD_OBLIGATION` terms remain byte-identical. Protocol-2 `GOLD_PAYMENT`/`GOLD_CORRECTION` terms use `IOUST2:` and append `parentAgreementId,parentOfferId,parentCommitId,parentTerms,baseRevision,baseChain,reversesId` after the existing common term fields. `dueUTC` is zero. `baseChain` uses `IOUSC1:` and flat canonical rows `{kind,agreementId,offerId,commitId,amountCopper,note,reversesId}`; `CanonicalChain`/`ParseChain`/`ValidateChain` expose that codec. Prior terms can be reconstructed exactly from these rows and their prefixes without recursively embedding old terms. Full logical messages remain bounded to 4096 bytes.

Payments must not exceed remaining copper. Corrections require a nonblank reason, target one locally confirmed and unreversed payment, and reverse its entire amount. Reversing a correction or the same payment twice is invalid. Capacity checks reserve enough space for all handshake envelopes, including future consent/commit IDs, before an event is retained. The service validates the whole financial graph on load and every staged mutation before persistence. No personal or shared wrapper schema migration is needed. Alpha.3 clients reject event terms; both peers should use 0.3.0.

`shared_payment_ui.lua` binds drafts to exact parent terms, peer, and canonical base; correction drafts additionally bind an explicitly selected payment's terms. Review displays the full original terms and exact prior chain. Tests cover this with `test_shared_payment_codec.lua`, `test_shared_payments.lua`, `test_shared_payment_integration.lua`, and mocked UI interactions.
