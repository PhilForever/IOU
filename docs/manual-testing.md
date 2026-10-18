# Testing IOU 1.0

**Use 1.0.1 for the next pass.** The first 1.0.0 live pass confirmed a gold repayment and Undo, then exposed item-link, bag-picker, and missing-trade issues. Those fixes still need verification; mail and the new confirmation flow have not been tested live. Updating from 1.0.0 only needs `/reload`; updating from an older release needs a full restart.

Retest these first:

1. **Choose from bags** should list carried items with an empty search and find Linen Cloth when searched. Shift-clicked cloth should display its name without color-token fragments.
2. With a known remaining balance of **5 Linen Cloth**, receive **2**, then **2** again: expect **3**, then **1**, with both transfers in Activity.
3. Receive unrelated items, then pay an existing **10s** debt: Activity should show both trades and the gold debt should settle. Cancelling a trade must still change nothing.

Previously missed transfers remain unrecorded; adjust their IOU through More if needed before repeating a balance check. A short text result is enough. Mail and player confirmation can wait until these pass.

Use small amounts and ordinary materials. Finish or undo one example before creating another with the same player and asset; several open matching debts correctly produce a Review choice.

## One player, with a friend for transfers

| Check | Do this | Expected result |
| --- | --- | --- |
| Compact UI, target, and reminders | Target your friend, open `/iou`, and create **Owed to me: 10s**. Leave the optional fields blank. Hover them and open a trade. | Name is filled; the IOU, tooltip, and trade reminder show 10s. Inputs respond immediately. Closing the trade without completing it changes nothing. |
| Trade repayment and Undo | Have the friend successfully trade you **3s**. Open Activity, then use **Undo** for that transfer. | The balance becomes **7s**, then returns to **10s** after Undo. The history retains the payment and reversal. |
| Cancellation and settlement | Start another 3s trade and cancel it. Then successfully trade the remaining 10s. | Cancellation leaves **10s**. Success leaves **0**, with the settled IOU in History. No duplicate payment appears. |
| Items and partial quantities | Use **Choose from bags** or a Shift-click link to create an IOU for **5 Linen Cloth** owed to you. Receive **2** through a completed trade. | Remaining balance is **3 Linen Cloth**, never a gold amount. Undo restores 5. An item variant or ambiguous exchange asks for Review. |
| Crafting entry | In New IOU → Items, select a material from bags. Try **Use stacks**, then add a second material with **+ Add another item** and save. | Known full stacks convert to actual units. Both materials get separate correct balances. An uncached stack size leaves units available instead of guessing. |
| Deliberate quick capture | Complete a transfer with two assets that have no matching open IOUs. Open Activity and use **Track all**. | Before clicking, no new debt exists. Clicking creates the appropriate gold/item IOUs once, with the player and amounts already filled. Repeating cannot duplicate them. |
| Successful outgoing mail | Create **I owe: 5s** to the friend. Successfully mail that player **5s**, and do not have them collect it yet. | Your balance becomes **0 immediately after send success**. Postage is excluded. Failed or cancelled sends do nothing. |
| Incoming mail | Create **Owed to me: 4s**. Have the friend mail 4s. Open/read the mail, then collect the money. | Reading leaves **4s**. Confirmed collection leaves **0**. Reopening the mailbox does not pay it again. Try a material attachment the same way if convenient. |

Use **More** for manual exceptions or to remove temporary test records from active balances. Existing real records should retain their amounts and history throughout.

## Two players: optional sharing

1. Both use 1.0.1 with **Options → Requests: on**. No Listen test, pairing, or manually enabled peer is required.
2. Create a **10s IOU**, enable **Ask to confirm**, and save. The sender sees Sent; the recipient sees Requests. These different views are expected.
3. The recipient opens **Review**. Confirm the names, direction, and 10s, then click **Accept**. Before that click, it must remain an unaccepted request. After delivery, each player's ordinary ledger shows the corresponding shared debt once.
4. Close both addon windows. Complete a **3s** trade in the appropriate direction, then reopen IOU. The local automatic repayment should leave **7s**. After the background exchange, both linked records should agree. If a review is required, its amount and resulting balance must be clear.
5. Use repayment **Undo**, allow the background exchange, and check that both balances return to 10s. A correction that cannot be reconciled safely must remain for review rather than changing unrelated history.
6. Repeat a small loan with a native **item link and quantity**. Item requests and repayments must show item units throughout.
7. Decline a separate new request. It must never appear as an agreed debt. Send another request, close/reopen the windows, and accept it; closing a window should not force pairing or local recovery steps.
8. Reload both clients with an accepted record and a partly paid balance. The same balance and history should remain, with no duplicate personal/Shared rows. Existing older confirmed Shared records stay in Requests; **More → Add to ledger** is a deliberate conversion, not an automatic new loan.

A successfully sent mail payment counts locally even while the recipient has not collected it. Peer synchronization can be pending independently; an unacknowledged packet must not be reported as delivered. The addon never transfers gold/items itself.

## What to report

A short text result is enough, for example: **“Trade 10s → 7s → Undo 10s passed; sent mail settled before collection; shared items still showed Pending sync.”**

For a failure, give the action, expected amount, actual amount/status, which player saw it, and any full Lua error. Report input lag or clipped controls in words if that is easier. Screenshots and exports are optional; never post real ledgers or account files in a public issue.

## Evidence already available

| Version | Actual evidence | Limit |
| --- | --- | --- |
| 0.1.0 | User reported personal records surviving `/reload` and a full restart. | Does not establish later observers or Shared links. |
| 0.3.2 | Two clients completed 4/4 exact ASCII/UTF-8 diagnostic echoes; live Shared payment, correction, and settlement were demonstrated. | Does not establish new background synchronization or trade/mail detection. |
| 0.5.0 | User reported successful backup checks; supplied private snapshots retained prior records. | The new test offer in those snapshots was interrupted. |
| 0.6.0 | User confirmed personal and Shared debts appearing in Trade and Tooltip. | Later UI and automatic repayments were not separately verified. |
| 1.0.0 | First live pass confirmed one gold repayment and Undo; native item links, bags, and later trades failed. | Fixed in 1.0.1; the patch, mail, and the new confirmation flow still need live verification. |

## Maintainer regression reference

Run `python tools/test_iou.py`, `python tools/test_curseforge.py`, and `python tools/package_iou.py`. The suites exercise financial limits, duplicates, cancellation/failure paths, strict item identity, stale choices, atomic mutations, consent, background inbox bounds, replay/reload, and recovery.

Additional client checks can cover UI scaling/resolutions, combat taint, other mailbox/trade addons, character isolation, full restart persistence, ambiguous exchanges, full bags, offline peers, and optional export/recovery. Do not delete live SavedVariables to simulate loss; use disposable harness data. The [connection diagnostic](connection-test.md) is available for an actual transport failure, not as a routine prerequisite.
