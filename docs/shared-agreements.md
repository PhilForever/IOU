# Shared gold agreements (experimental)

Version **0.3.0-alpha.3** adds an opt-in agreement view under **Shared** or `/iou shared`. Both characters need this version or a compatible newer build. This is an experimental alpha: automated two-client simulations pass, while actual Forever addon-message delivery and rendering remain unverified.

## Propose and accept

1. Both players open **Shared**, enter each other's exact full first name and surname, then click **Enable for player**. **Use target** can fill the name in. Keep both shared windows open.
2. The proposer clicks **+ Propose gold**, chooses who will owe whom, and enters coins, an optional due day, and a note. **Send proposal** sends those terms to the enabled player.
3. The recipient selects the received offer and clicks **Review / accept**. A separate review shows both participants, debtor, creditor, amount, the full note, and the UTC deadline. **Accept these terms** records consent to those exact terms.
4. IOU exchanges the commitment and acknowledgment. The status distinguishes an agreed record from observed peer acknowledgment. A successful API send alone is not a receipt.

Either player can propose an obligation in either direction. A pending proposal is not an accepted debt. Acceptance records the players' stated agreement; it does not transfer or verify gold. Shared records appear separately from personal ledger balances. Shared repayments and amendments are not available in this alpha.

The recipient can **Decline** before acceptance. The proposer can **Withdraw** before commitment. Both actions require a separate review. A timeout or disconnect never implies decline, cancellation, or payment.

## Delivery and interrupted offers

**Retry** resends the same retained protocol decision for the selected offer; it does not create another acceptance or agreement. Communication is paced and bounded. Queue, account restrictions, unsupported APIs, and exact-name mismatches produce status messages. Messages use logged addon whispers with readable text; there is no ordinary-chat fallback or automatic acceptance.

Closing the Shared window, pressing Escape in its name box, `/iou shared off`, or reloading disables sharing. Unfinished handshakes become **Paused**. Queued traffic is discarded, and nothing resumes automatically on the next login. Agreed records remain agreed and retain their history.

An old offer may have progressed further on the other player's client. Reconcile it with them before replacing it. With sharing off, select a paused offer and choose **Review paused offer**. Read its retained terms, enter a reason, and choose **Mark reviewed locally**. This preserves the old record and a local review marker. It does not cancel or settle the other player's record. Delayed messages cannot reopen the locally reviewed offer.

An unresolved paused offer blocks a replacement proposal with that same player. After both players have reconciled their old records, a fresh proposal uses fresh identifiers and requires fresh acceptance. Records are retained; reaching the 32-offer storage cap rejects new offers rather than evicting history.

## Saved data and scope

Shared data is stored separately under `IOUDB.sharedByCharacter`, keyed by the existing character ledger identity. It survives normal successful logout/reload. As with other SavedVariables, a crash can lose changes made since the last save. Loading validates the current character's wrapper, exact owner, engine records, and review markers. Invalid shared data is left untouched; personal bookkeeping remains available.

Personal backup/import (`IOU1`/`IOU2`) includes only the personal ledger. It does not export, replace, resume, or merge shared agreements. A dedicated shared backup/reconciliation flow is future work. Do not use a personal import as a way to repair a shared mismatch.

## Commands

| Command | Action |
| --- | --- |
| `/iou shared` | Open this character's shared view. Sends nothing. |
| `/iou shared Amber Stone` | Open with the other player's full name filled in. Sends nothing. |
| `/iou shared off` | Disconnect and pause unfinished offers. |

The [protocol specification](shared-agreements-protocol.md) and [development guide](shared-development.md) describe the engine and framing. Live testing remains separate from the automated evidence and can be resumed later.
