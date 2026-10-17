# Shared IOU development — 1.0

Shared gold and item agreements use immutable terms and the retained PROPOSE/ACCEPT/COMMIT/ACK state machine. The 1.0 coordinator links accepted agreements to ordinary personal IOUs, observes personal repayment changes, and handles background delivery. Original loans always require local recipient acceptance.

The pure codec, engine, and payment modules perform no network, UI, saved-data, or clock access. Callers provide timestamps. The service validates and stages records; the coordinator connects them to the existing personal ledger. See the [protocol](shared-agreements-protocol.md), [player guide](shared-agreements.md), and [testing guide](manual-testing.md).

## Modules and boundaries

| Module | Responsibility |
| --- | --- |
| `shared_codec.lua` | Strict canonical gold/item terms, financial chains, logical messages, and synchronization hints. |
| `shared.lua` | Pure consent state transitions, retained responses, duplicate handling, Pause/Resume, and snapshots. |
| `shared_payments.lua` | Exact original/commit/chain binding, derived balances, payment and full-reversal construction. |
| `shared_wire.lua` | Printable UTF-8 framing, logged WHISPER transport, bounded queues/reassembly/rate limits. |
| `shared_service.lua` | Character storage, staged mutation, transient background invitations, queue-before-commit preflight, recovery gates. |
| `sharing.lua` | Personal links, deliberate legacy adoption, observed repayments, exact-baseline hints, bounded delivery retries. |
| `shared_view.lua` | Detached projection for compact Requests; presentation never grants consent. |

## Pure API

`Shared.New(name)` creates an empty store; `Validate` checks it; `Snapshot` returns a detached copy. `Propose`, `Receive`, `Accept`, `Decline`, `Withdraw`, `Pause`, `Resume`, and `Retry` return `newStore, actions` or `nil, error` without modifying the input. Actions are `{target=fullName,message=logicalMessage}`. Callers persist before enqueueing.

`Resume` restores only the exact pending state whose terms, role, consent, and messages are already retained. It cannot create an acceptance. `Retry` reuses the retained response. Unknown COMMIT/ACCEPT traffic cannot restore missing consent.

`SharedCodec.IsObligation`, `IsPayment`, `IsCorrection`, and `Asset(terms)` hide gold/item kind differences. Asset results are `{kind="money"|"item",label,itemKey?,itemID?,amount}`. `CanonicalItem(link)` validates the numeric native item payload; item identity is not inferred from a display name.

`SharedPayments.View/Views` derives acknowledged balances. Legacy `originalCopper`, `paidCopper`, and `remainingCopper` fields remain for compatibility; for item terms these are integer quantities, never copper. Item views also expose amount/asset metadata. UI code must format through the asset kind.

## Service and coordinator

`SharedService` retains existing manual `Enable(peer)` behavior and adds `EnableBackground`, `IsBackground`, `SelectPeer`, and `Resume`. `GetStore` returns saved consent history only. `GetOffer`, `List`, and `GetOverview` also expose unaccepted transient background invitations without pretending they are saved or acknowledged balances.

Background original proposals use a session inbox limited to **16 total, 12 per sender, and 300 seconds**. Exact duplicates keep the same request and do not extend its lifetime. Conflicts cannot replace it. Accept stages original Receive plus explicit Accept in one saved candidate before enqueueing. Queue preflight failure leaves no saved request or consent. An enqueue failure after persistence returns the saved offer for Retry. Temporary Decline/withdraw/outcome previews do not consume permanent history. Unknown financial events cannot enter this invitation inbox.

The saved Shared wrapper remains `{version=1,store,closedPaused,nonce,counter}` under `IOUDB.sharedByCharacter[character]`. Existing personal schemas and `IOU1`/`IOU2`/`IOUS1` formats remain unchanged. Optional `sharingByCharacter` links bind personal record identity, the original offer/terms, and repayment baselines; they do not rewrite the old Shared graph or create peer consent.

`Sharing.Connect(peer)` selects delivery without requiring a second manual setup flow. `PrepareOffer(id)` checks the exact record and prepares its peer before a UI decision. `Share(personalID)` proposes the open balance of an ordinary IOU. New confirmed originals can be linked into the personal ledger once; pre-1.0 records require explicit `Adopt(offerID)` to avoid duplicating old personal notes. Personal imports suspend stale links rather than automatically treating matching numeric IDs as the same history.

`Sharing.OnPersonalChanged` compares valid linked personal balances with acknowledged Shared balances. The original proposer remains the financial event sequencer. A recipient can send an exact-original/exact-chain SYNC hint about its locally observed state; the hint does not directly mutate a balance or supply acceptance. Compatible observed evidence can complete routine acknowledgment; ambiguous, conflicting, or unsupported corrections remain for review. Successful outgoing mail changes the sender's personal balance independently of Shared acknowledgment.

## Limits and recovery

- Permanent engine capacity: **128 offers**, including originals and financial events. Existing history is never silently evicted.
- Canonical logical message: **4096 bytes**; names **96 bytes**, notes **512 bytes**, identifiers **64 ASCII bytes**, financial chain **31 rows**. Complete handshake size can impose an earlier limit; terms are never truncated.
- Native packet budget: **240 UTF-8 bytes**; at most **32 parts** per logical message.
- Outbox: **32 logical messages / 128 packets**, paced at one packet per second.
- Receive assemblies: bounded per sender and across background senders, **45-second expiry**, with a **120-token bucket / two tokens per second** before parsing. Exact event sender and channel establish the peer, not a payload assertion.
- Coordinator delivery retries are bounded and reuse retained IDs/terms. Timeouts never mean paid, declined, or accepted.

Staged Shared recovery stops messaging and keeps a persistent review gate. Only the same character's own validated snapshot can supply retained local evidence. Restore adds compatible missing history; it does not overwrite conflicting records, remove current history, or invent missing consent. Backups and diagnostics remain advanced tools, not ordinary-use prerequisites.

## Evidence

The 0.3.2 live pilot demonstrated exact diagnostic round trips and acknowledged gold payment/correction/settlement. Personal/Shared tooltip and trade reminders were reported working in 0.6.0. **New trade/mail observation, compact 0.7+ presentation, item sharing, and 1.0 background synchronization still need live verification.** Regression simulations establish internal invariants, not native client timing, rendering, or taint behavior.
