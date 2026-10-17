# Shared gold agreements

For a quick record of gold or crafting items, use **+ New IOU** in the main ledger. The other player does not need the addon. Player tooltips and trade reminders show these records during normal play.

Use **Settings → Shared agreements** or `/iou shared` when both players want to acknowledge a gold agreement. In **0.6.0**, closing this board leaves your explicitly enabled session running; you can return to the game while the other player reviews. There is no need to keep the board open. Sharing still stops at Disconnect, logout, or reload, and accepting always requires your click.

Both players need IOU for Shared. Existing gold agreements are retained; items remain personal records for now. IOU uses the normal Release channel. New tooltip, trade, and window-close behavior await live verification.

## Send an agreement

1. Both players open Shared, fill each other's full name with **Use target** or by typing, and click **Connect**.
2. One clicks **+ Propose gold**, chooses who owes whom, enters the amount, and sends. Notes and due dates are optional.
3. The sender sees the proposal under **Sent**. The other player sees it under **Needs review**: select it, click **Review / accept**, read the terms, then click **Accept these terms**.

After the acknowledgment arrives, both find the accepted original under **Agreements**. The review count/minimap notice helps the recipient find incoming work; it does not open a popup. Closing the board or the review does not accept anything. Use **Disconnect** when you want to stop the selected session.

**Sent on one client and Needs review on the other is expected.** The sender is waiting for a decision; the recipient has a decision to make. An unaccepted proposal does not count as an agreed debt.

## Find offers and agreements

| View | What appears |
| --- | --- |
| Needs review | Incoming proposals and unreviewed interrupted offers, including your own paused offers. |
| Agreements | Acknowledged original agreements with an open balance or an unfinished payment/correction. |
| Sent | Sent proposals, acceptance/decline in progress, and commitments still awaiting peer acknowledgment. |
| History | Settled originals without unfinished events, completed payment/correction offers, declined/withdrawn offers, and locally reviewed paused offers. |
| All offers | Every retained offer, including original agreements and individual financial events. |

The first opening chooses a useful nonempty view. After you choose a view or type, incoming traffic preserves that choice, selection, focus, and detail scroll. Tab counts cover all records; search narrows the visible results without hiding review notices. Search is literal across full participants, notes, and agreement/event types. ASCII case is ignored; Unicode text matches its exact bytes.

Original agreement rows show the current acknowledged **Remaining** amount. Payment and correction rows show their own **Amount**. Details retain full terms and history. New proposals and financial events are selected in their appropriate view after you send them; browsing never sends or accepts.

When work needs attention, the main **Shared (N)** button and minimap badge show the review count. Otherwise Shared is available in Settings. **Shift-left-click** the minimap opens the review view. A pending recovery shows `!` and opens its recovery review. These are passive notices; there are no automatic popups, connections, or acceptances.

## Propose and accept

1. Both players open **Shared**, enter each other's exact full first name and surname, then click **Connect**. **Use target** can fill the name in. When disconnected, **Connect selected player** uses a retained offer's exact participant after a separate click. It never switches an already connected player; disconnect first. You may close the board after connecting. Connected status describes your local choice, not proof that the other player is online or ready.
2. The proposer clicks **+ Propose gold**, chooses who will owe whom, and enters coins, an optional due day, and a note. **Send proposal** sends those terms to the enabled player.
3. The recipient selects the received offer under **Needs review** and clicks **Review / accept**. A separate review shows both participants, debtor, creditor, amount, the full note, and the UTC deadline. **Accept these terms** records consent to those exact terms. Once accepted, the offer leaves Needs review; follow it under Sent and then Agreements or History.
4. IOU exchanges the commitment and acknowledgment. The status distinguishes an agreed record from observed peer acknowledgment. A successful API send alone is not a receipt.

Either player can propose an obligation in either direction. A pending proposal is not an accepted debt. Acceptance records the players' stated agreement; it does not transfer or verify gold. Shared records appear separately from personal ledger balances. Amendments remain future work.

The recipient can **Decline** before acceptance. The proposer can **Withdraw** before commitment. Both actions require a separate review. A timeout or disconnect never implies decline, cancellation, or payment.

## Payments, settlement, and corrections

The **original agreement proposer** records events, regardless of which participant owes the gold. The other participant reviews and accepts each event. A recipient who wants to record a payment should ask the proposer to enter it; there is no automatic payment-request flow.

Select an agreed gold obligation and use **Record payment** for a partial amount or **Settle balance** for its full remaining balance. The latter captures the current amount; a later balance change invalidates the draft. Add an optional note, then **Send for acknowledgment**. The recipient selects the new payment offer and uses **Review / accept**. Review includes the original obligation, the exact prior event history, and the proposed resulting balance.

The recipient includes a payment in its balance when it receives the commitment. The proposer includes it only after observing the recipient's acknowledgment. A lost acknowledgment can temporarily leave different balances; **Retry** resends the retained decision. The proposer cannot create another event until the latest acknowledgment is observed. Pending proposals and local API submission never count as payment.

For a mistake, choose **Correct payment**, explicitly select one confirmed payment, and optionally enter a reason. Blank text becomes "No reason provided" in the exact terms the other player reviews. This proposes a full reversal requiring their acceptance. The original payment and correction remain visible. Reversing a settlement reopens its amount. Partial reversals, correction of a correction, and reversing the same payment twice are rejected. A correction records bookkeeping; it does not move gold.

Only one unfinished payment/correction can target an obligation. Every event binds the exact original terms, parent commitment, and full prior acknowledged event chain. Missing or different history rejects the event instead of guessing from the balance. Reaching the 4096-byte message budget or 32 retained-offer limit rejects new work without truncating terms or deleting history.

## Delivery and interrupted offers

**Retry** resends the same retained protocol decision for the selected offer; it does not create another acceptance or agreement. Communication is paced and bounded. Queue, account restrictions, unsupported APIs, and exact-name mismatches produce status messages. Messages use logged addon whispers with readable text; there is no ordinary-chat fallback or automatic acceptance.

Closing the Shared window, including Escape in its name box, hides the board and leaves the selected session enabled. The wire can continue delivering the retained proposal or acknowledgment; it cannot create consent. The connection test is separate: closing its window still stops diagnostic listening.

**Disconnect**, `/iou shared off`, logout, reload, or an actual transport stop disables sharing. Unfinished handshakes become **Paused**; queued traffic is discarded and nothing resumes automatically at login. Agreed records remain agreed and retain their history. There is no short review countdown that requires keeping the board open.

An old offer may have progressed further on the other player's client. Reconcile it with them before replacing it. With sharing off, select a paused offer and choose **Close interrupted request**. Read its retained terms, optionally enter a reason, and choose **Close request locally**. This preserves the old record and a local review marker. It does not accept the request, record a payment, or cancel or settle the other player's record. Delayed messages cannot reopen the locally closed request.

An unresolved paused offer blocks a replacement proposal with that same player. After both players have reconciled their old records, a fresh proposal uses fresh identifiers and requires fresh acceptance. Records are retained; reaching the 32-offer storage cap rejects new offers rather than evicting history. Older offers paused by closing the board on 0.5.0 stay paused until reviewed; the new close behavior does not resume them.

## Saved data and scope

Shared data is stored separately under `IOUDB.sharedByCharacter`, keyed by the existing character ledger identity. It survives normal successful logout/reload. As with other SavedVariables, a crash can lose changes made since the last save. Loading validates the current character's wrapper, exact owner, engine records, and review markers. Invalid shared data is left untouched; personal bookkeeping remains available.

Personal backup/import (`IOU1`/`IOU2`) includes only the personal ledger. It does not export, replace, resume, or merge shared agreements. Use **Shared backups** for the separate `IOUS1:` format. Preview shows differences and balances; staging disconnects sharing and requires a decision even after reload. Restore adds missing history, preserves current versions and review markers, and rejects incompatible combined histories. It does not resolve peer disagreements or create new acceptance. See the [Shared backup guide](shared-backups.md).

## Commands

| Command | Action |
| --- | --- |
| `/iou shared` | Open this character's shared view. Sends nothing. |
| `/iou shared Amber Stone` | Open with the other player's full name filled in. Sends nothing. |
| `/iou shared off` | Disconnect and pause unfinished offers. |

The [protocol specification](shared-agreements-protocol.md) and [development guide](shared-development.md) describe the engine and framing. Live testing remains separate from the automated evidence.
