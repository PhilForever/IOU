# Shared gold agreements

Open **Requests** from the main ledger when both players want to acknowledge a gold debt. Personal IOUs work without sharing or the other player having the addon.

## Send or accept

1. Both players open Requests, choose each other's full name with **Use target** or by typing, and click **Connect**.
2. One clicks **+ Propose gold**, chooses who owes whom, enters the amount, and sends. Notes and due dates are optional.
3. The sender finds it under **Sent**. The recipient finds it under **Requests**, opens **Review**, checks the terms, and clicks **Accept these terms**.

Once the commitment and acknowledgment arrive, the original appears under **Active**. A sent proposal is not an accepted debt. Incoming notices never accept or open a window automatically.

You can close the board and continue playing: an explicitly connected session stays enabled. **Disconnect**, logout, or reload stops sharing and pauses unfinished requests. Closing a review never accepts it.

## Read a record

The ordinary view shows the player, who owes whom, the amount remaining, and a short status. Expand **Details** for retained terms and history. Secondary actions are under **More**.

| View | Contents |
| --- | --- |
| Requests | Incoming requests and interrupted requests needing a local decision. |
| Active | Accepted original debts with a remaining balance or an unfinished event. |
| Sent | Requests or decisions waiting for the other client. |
| History | Settled debts, completed payments/corrections, declined/withdrawn requests, and closed interrupted requests. |
| All requests | Every retained original, payment, and correction. |

Search narrows the list; counts still describe all records. Opening records, switching views, or expanding Details sends nothing. Incoming messages preserve your chosen view, focus, and scroll.

**Requests (N)** and the minimap badge show work needing attention. **Shift-left-click** on the minimap opens review. A recovery notice shows `!` and opens the recovery review instead.

## Payments and mistakes

Repayments are **manual in 0.7.0**. Trade and mail automation are on the [roadmap](roadmap.md).

The original proposer records Shared payments and corrections, regardless of who owes the gold. Select the original agreement and open **More → Adjust payment** or **Mark paid**. Send the amount for the other player's review. For a mistake, use **More → Undo payment** and select the confirmed payment to reverse. Reasons are optional.

Payment review retains the original terms, prior payments, and proposed resulting balance. A correction reverses a whole confirmed payment; it does not move gold or delete history. Only one payment/correction can be unfinished for an agreement.

The recipient includes a payment when commitment arrives; the proposer includes it after acknowledgment. A lost acknowledgment can temporarily leave different balances. **Retry** resends the retained decision without creating a new payment. No API send success alone counts as peer confirmation.

## Interrupted requests

An interrupted request is **Paused**, not accepted or cancelled. Closing the board alone no longer causes this; Disconnect, reload, logout, or a transport failure can.

Before replacing an interrupted request, compare it with the other player: their client may have received more of the exchange. With sharing disconnected, select it and use **Close locally**. A local close preserves the record, blocks delayed reopening, and records no payment or acceptance. After reconciling the old request, a new proposal needs fresh acceptance.

The old 0.5.0 close-window behavior may have left paused records. The current release retains those records; it does not automatically resume or accept them.

## Scope and advanced information

Shared currently supports gold with one explicitly connected player. Either participant can propose a debt in either direction. Shared items, simpler background synchronization, and integration into an ordinary IOU are future work. Personal and Shared balances stay separate in tooltip and trade reminders to avoid double-counting.

Shared records and history survive normal successful reload/logout. Optional recovery is under **Options → Backups** and uses a separate `IOUS1:` snapshot. Personal `IOU1:`/`IOU2:` imports do not change Shared records. See [Shared backups](shared-backups.md) only when you need recovery.

Commands: `/iou shared [full player name]` opens without sending; `/iou shared off` disconnects.

For implementation rules and capacity limits, see the [protocol specification](shared-agreements-protocol.md), [development guide](shared-development.md), and [testing guide](manual-testing.md).
