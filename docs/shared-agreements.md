# Shared IOUs

Sharing lets both players acknowledge the same gold or item IOU. Personal IOUs work without sharing or the other player installing the addon.

## Send and accept

1. Create an ordinary IOU and enable **Share with player**, or select an open record and click **Share IOU**.
2. The recipient opens **Requests**, checks the player, direction, amount/item, and any note, then chooses **Accept** or **Decline**.
3. After the exchange completes, the accepted IOU appears in the ordinary ledger on both clients. Linked copies count once in reminders.

Both players need **1.0.0** and **Options → Requests: on**. There is no routine Listen test or repeated pairing. Requests also offers **+ Share IOU** for a new gold/item proposal. The sender sees Sent while the recipient sees Requests; that is the same offer awaiting a decision.

A new loan is never accepted automatically. Closing Requests or a review does not accept terms and does not interrupt routine background delivery. Incoming messages do not open windows or take focus.

## Repay normally

Complete a trade, successfully send mail, or collect matching player mail. Clear personal repayments apply locally; linked IOUs exchange acknowledged payment updates in the background. If both local observations and the proposal agree, routine confirmation can complete automatically. An unclear match or conflicting state remains for review.

A successful outgoing mail payment counts in the sender's personal ledger immediately, without waiting for collection or the other player being online. That local event and peer acknowledgment remain separate facts. A pending sync does not mean the gold is unpaid locally or that a packet was delivered.

Use **Activity → Undo** for an observed repayment mistake. Payment history is retained. **Requests → More** keeps manual adjustments, settlement, and full-payment correction available for exceptions; these controls never move gold or items themselves. Only one payment/correction can be unfinished for an agreement.

## Keep the screen simple

The normal view shows the player, direction, remaining amount, useful note, and short status. **Details** expands exact retained terms/history. **More** holds secondary actions and advanced Connection controls.

| View | Contents |
| --- | --- |
| Requests | Incoming decisions and interrupted records requiring attention. |
| Active | Accepted original debts that still have a balance or unfinished event. |
| Sent | Requests or decisions awaiting the other client. |
| History | Settled debts, financial events, declines, withdrawals, and locally closed records. |

Unaccepted background invitations are temporary: up to 16 total and 12 from one player, expiring after five minutes. They do not fill permanent consent history. The sender can retry the same retained offer if an invitation expires. Accepted records and existing history are never silently evicted.

## Existing records and exceptions

Older Shared records are retained without silently creating matching personal debts. Select a confirmed original and use **More → Add to ledger** when you want to link it. If an existing personal record cannot be matched safely, review the records before creating another.

Background delivery resumes only exact retained decisions and uses bounded retries. Offline peers, conflicts, capacity, recovery gates, or unavailable native messaging can leave a short pending/review status. **Retry delivery** resends existing terms and decisions; it does not create another loan. An unresolved interrupted record should be reconciled before replacement. Advanced local closure retains its evidence and does not accept it.

Optional Shared recovery is available through **Options → Backups** using `IOUS1:`. Personal `IOU2:` imports do not restore Shared consent. See [Shared backups](shared-backups.md) only when needed.

Commands: `/iou shared [full name]` opens Requests without sending. Requests can be turned off in Options. See [Testing](manual-testing.md), the [protocol](shared-agreements-protocol.md), and the [development guide](shared-development.md) for implementation details and current verification limits.
