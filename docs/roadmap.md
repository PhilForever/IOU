# Toward IOU 1.0

The goal is to record a loan in seconds, play normally, and let IOU keep the remaining balance current. Gold and crafting materials are the main use cases. Manual actions remain available for exceptions and corrections, but should not dominate ordinary use.

This is the development direction, not a claim that future features already work. Milestone numbers can change as client behavior is verified. Releases use the regular CurseForge **Release** channel.

## Milestones

| Milestone | Scope | Player outcome |
| --- | --- | --- |
| 0.7 — Simplify | Compact amounts, rows, and record details; collapse optional inputs and history; move secondary actions under More; expose Requests in the main window. | Less reading and fewer controls in the ordinary flow. |
| 0.8 — Trade automation | Observe completed transfers; distinguish cancellation/failure from success; prevent duplicate events; match exact players and items; handle partial repayments, ambiguity, and Undo. | Straightforward trade repayments update existing debts automatically. |
| 0.9 — Mail and Activity | Match successful outgoing mail and confirmed incoming collection; correlate exact recipients/senders, money, and attachments; add a quiet recent-transfer list and Track as IOU. | Mail repayments update balances; making a new loan from a recent transfer needs one click. |
| 0.10 — Shared redesign | Integrate sharing into an ordinary IOU; support items; provide compact Accept/Decline requests and background synchronization with bounded reconnect behavior. | Shared is an optional part of the ledger rather than a second bookkeeping application. |
| 0.11 — Crafting and polish | Improve item selection, stacks, quantities, and material bundles; refine multiple-debt matching and player shortcuts. | Lending crafting materials is as convenient as lending gold. |
| 1.0 — Reliability | Finish upgrade/reload/disconnect handling, duplicate-event protection, mixed trades, mail failure paths, Shared reconciliation, performance, UI scaling, and concise onboarding. | Dependable tracking during ordinary play. |

Version 0.7 changes presentation only. It does not implement automatic trade or mail repayments, migrate financial records, or change Shared consent.

## Automatic repayment rules

Automatic matching uses an existing open debt, an exact player, the direction, and the observed money or item identity. Opposite-direction balances stay separate. Personal and Shared copies of a possible real-world loan must never be silently added together or paid twice.

- A clearly matched transfer reduces the existing balance. Partial repayments leave the remainder open.
- An amount beyond the matched balance settles only that balance; excess stays unassigned.
- An ambiguous match produces one compact allocation choice rather than a guessed payment.
- Every automatic adjustment is recorded once, is explainable in history, and offers Undo.
- Gifts, purchases, unmatched crafting exchanges, and other unmatched transfers do not automatically become loans. A quiet Activity entry can offer **Track as IOU** with player and contents already filled.
- Existing manual entries, history, and corrections remain usable. A manual adjustment is an exception path, not a required step after each straightforward transfer.

### Sending mail

If you owe a player 5g and successfully mail that exact player 5g, **your own personal ledger counts it as repayment immediately after `MAIL_SEND_SUCCESS`**. It does not wait for the recipient to collect the mail, be online, use IOU, or acknowledge a message. The repayment records the successful send, not proof of collection.

The observer must retain the intended recipient and exact contents until the client confirms the send. Clicking Send, an insufficient-funds error, a failed send, or a duplicate success notification must not create a repayment. Postage is not part of the transferred gold. COD is excluded from ordinary automatic repayment matching. Unmatched sends never create new debts automatically.

### Receiving mail

An incoming repayment counts when this client confirms taking the matching money or attachments from the exact sender. Merely seeing a mail message is not collection. Partial attachment collection, moving inbox indices, full bags, failures, duplicate events, auction/system mail, returned mail, and COD need explicit handling before this ships.

No sender-side collection confirmation is required or assumed. Outgoing success and incoming collection are separate local observations.

### Shared balances

Current Shared balances retain their explicit consent and acknowledgment rules. A successful mail send must not be mislabeled as a peer-confirmed Shared repayment. The future Shared redesign will distinguish local transfer evidence from the shared agreed state, automate the routine exchange under clearly chosen rules, and show a short pending status when synchronization is unfinished.

## Interface direction

The main window should focus on **Add IOU**, **Requests**, search, and open balances. A row should identify the player and what remains. An opened record should show its direction, original/paid/remaining amounts, and any useful note. History and technical details should be expandable.

Sharing should be an optional **Share with player** action on an IOU. A recipient needs a readable request and Accept/Decline, without navigating protocol identifiers or recovery terminology during ordinary play. Closing a window should not interrupt normal delivery. Diagnostics and backups stay available in Options.

## 1.0 acceptance criteria

- A basic IOU takes only a few clicks, with names and observed contents filled whenever available.
- Gold and crafting items work equally well.
- Routine repayments require no bookkeeping.
- Automatic changes are understandable and reversible.
- Shared use adds little friction and never invents consent.
- Essential information is readable at a glance in the ledger, player tooltip, and trade reminder.
- Existing history survives updates without double-counting or silent deletion.
