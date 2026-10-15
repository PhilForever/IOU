# Offline Shared Agreements foundation

Version **0.3.0-alpha.2** adds `IOU.SharedCodec` and `IOU.Shared`. These modules model a gold agreement between two characters and simulate the acceptance protocol. They perform no network traffic, file access, UI work, or `IOUDB` access. They obtain no clock values: callers supply integer timestamps.

The personal ledger remains separate. There is no shared agreement creation or acceptance UI in this build. The [protocol draft](shared-agreements-protocol.md) describes the later live implementation.

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

On any future reload or restore integration, call `Pause` before allowing shared work to resume. Paused offers cannot automatically retry or accept. Fresh agreement and offer IDs require fresh explicit review; a future reconciliation UI must prevent unresolved copies from being counted twice. A peer message never restores missing local consent.

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

The readable netstring formats start with `IOUST1:` for terms and `IOUSM1:` for logical messages, using comma-terminated `length:value,` fields. Logical data is bounded to 4096 bytes; names to 96 bytes and notes to 512 bytes. **This is not the 240-byte logged-whisper packet format.** Packet framing and reassembly remain separate future work.

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

The next implementation step is to design and test bounded framing and explicit persistence/reconciliation around this engine, then add the consent UI. Actual logged-whisper delivery and Forever sender identity remain unverified; record that live evidence separately from the offline simulations when testing resumes.
