# IOU 1.0 and the road ahead

The goal is to record a loan in seconds, play normally, and let IOU keep the remaining balance current. Gold and crafting materials are the main use cases. Manual actions handle exceptions; ordinary repayment should not require bookkeeping.

**1.0.0 implements that planned feature set. Live verification of the changes from 0.7 onward remains pending.** A version number and passing simulations do not establish native client behavior. Releases use regular GitHub tags and CurseForge **Release** files.

## Delivered scope

| Version | Scope | Player outcome |
| --- | --- | --- |
| 0.7 | Compact rows and summaries, optional fields/history collapsed, secondary actions under More, Requests in the main header. | Less reading during ordinary use. |
| 0.8 | Completed trade observation, exact personal repayment matching, partial payments, allocation review, and Undo. | Clear trade repayments update existing debts. |
| 0.9 | Successful outgoing mail, confirmed incoming collection, Activity, and Track as IOU. | Mail repayments update balances and recent transfers can become deliberate loans. |
| 1.0 | Integrated optional gold/item sharing, compact Accept/Decline, background delivery/reconciliation, bag/stack/material bundles, Track all, and upgrade protections. | Shared is part of the ordinary ledger; crafting materials need less typing. |

The former 0.10 and 0.11 milestones are included in 1.0.0 rather than separate releases. The [testing guide](manual-testing.md) provides the short live pass for the combined changes.

## Rules that remain fixed

- Exact player, direction, and asset identity determine repayment eligibility. Opposite-direction debts remain separate.
- A clearly matched transfer pays an existing balance once. Partial amounts leave a remainder; excess stays unassigned.
- Ambiguous matches ask for a choice instead of guessing.
- Automatic changes retain history and offer Undo. An explicitly captured loan remains an ordinary IOU.
- Gifts, purchases, and unmatched crafting exchanges never become new debts automatically. Track as IOU and Track all require a deliberate click.
- Successfully mailing 5g to someone you owe counts in your own ledger after send success, without waiting for collection or acknowledgment. Postage and COD are excluded.
- Incoming mail counts after confirmed collection. Reading a message is not a repayment.
- Every new Shared loan requires recipient acceptance of the exact terms. Background retries reuse retained decisions; they do not manufacture consent.
- Local transfer evidence and acknowledged Shared state are distinct. Unclear or conflicting synchronization remains for review.
- Existing personal/Shared records survive updates. Old confirmed Shared records require deliberate Add to ledger before conversion; no silent duplicate is created.
- Backups and diagnostics remain optional and secondary.

## After the first live pass

Prioritize 1.0.x fixes for the actual trade/mail event order, missing or duplicate repayments, synchronization interruptions, input focus, UI scaling, and compatibility with common mailbox/trade addons. Keep normal operation quiet and reduce exceptions only when real client evidence supports it.

Future expansion should earn its place through ordinary play feedback. Clear balances, reliable history, and less typing take priority over more screens, crafting contracts, or a broader social system.
