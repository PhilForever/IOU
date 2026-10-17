# IOU

**Remember who owes you gold or crafting materials, what you owe other players, and what has already been paid back.** IOU is a lightweight debt tracker for **WoW: Forever**.

Create a loan in a few clicks, then play normally. Matching trades and mail keep the remaining balance updated. Player tooltips and trade reminders show what is owed without opening the ledger.

[Download on CurseForge](https://www.curseforge.com/wow/addons/iou) · [GitHub Releases](https://github.com/PhilForever/IOU/releases)

## Features

- **Gold and materials:** Track either direction, partial repayments, item quantities, and optional notes or deadlines.
- **Automatic repayments:** Completed trades, successfully sent mail, and confirmed mail collections repay clearly matching existing IOUs.
- **Quick capture:** Activity offers **Track as IOU** and **Track all**, using the recorded player, amounts, and items.
- **Crafting shortcuts:** Choose items from your bags, use units or full stacks, and enter several materials together.
- **Optional sharing:** Share an ordinary gold or item IOU. The other player accepts or declines in Requests; routine delivery continues with the windows closed.
- **History and Undo:** Review an unclear match or undo a repayment without deleting its history.

Personal IOUs work even when the other player does not use IOU. Gifts and purchases never become debts automatically.

## Get started

1. Open `/iou`, target a player, and click **+ New IOU**.
2. Choose **Owed to me** or **I owe**, then enter gold or select an item and quantity. Notes and a due date are optional.
3. Save. Hovering the player or opening a trade shows what remains.

For crafting materials, use **Choose from bags** or Shift-click an item into its field. **Use stacks** uses the item's known full stack size; partial stacks can stay in units. **+ Add another item** builds a bundle of up to 12 materials. Each material has its own balance. Favor records and manual exceptions remain available.

Already transferred something? Open **Activity**. Choose an unassigned asset and **Track as IOU**, or use **Track all** for the remaining contents. What you gave becomes an IOU owed to you; what you received becomes an IOU you owe. This is a deliberate loan-creation action.

## Let repayments look after themselves

A clearly matched transfer reduces an existing personal balance once. Partial repayments leave the remainder open; excess stays unassigned. Opening a trade, accepting a trade that later fails, or reading a mail message never counts as repayment.

If you owe someone **5g** and successfully mail them **5g**, your own ledger counts that repayment immediately. It does not wait for collection, the other player being online, or their addon acknowledging it. Postage is excluded. Incoming mail counts after confirmed collection. COD, auction/system/returned mail, failed actions, and uncertain mailbox changes are excluded from automatic matching.

Mixed exchanges, several eligible IOUs, item variants, and unresolved overlapping personal/Shared records need a choice in **Activity**. IOU does not guess. **Undo** on a repayment notice or Activity restores the applied balance and retains the original event. It does not delete a loan you deliberately created with Track as IOU.

Automatic trade and mail matching can be disabled separately in **Options**. Manual payment, editing, cancellation, and correction actions remain under **More** for exceptions. History and full notes expand when needed; optional backups stay under **Options → Backups**.

## Share when it helps

Use **Share with player** while creating a gold or item IOU, or select an existing IOU and click **Share IOU**. Both players need the current IOU version and Requests enabled. The recipient opens **Requests**, reviews the amount and direction, then accepts or declines. A new loan is never accepted automatically.

Sharing runs in the background; routine use needs no repeated pairing, Listen test, or open windows. Accepted records link to the ordinary ledger, so the same linked debt is not shown twice in reminders. Observed repayments can synchronize through the existing acknowledgment exchange; unclear or conflicting events remain available for review. Local successful mail repayment and peer synchronization are separate facts.

Older Shared records are retained. To bring an existing confirmed record into the ordinary ledger, use **Requests → More → Add to ledger**. IOU does not silently duplicate legacy debts. See the [Shared guide](docs/shared-agreements.md) for exceptions and recovery.

## Commands and access

| Command | Action |
| --- | --- |
| `/iou` | Show or hide the ledger. |
| `/iou add` / `/iou target` | Add an IOU or find the targeted player's records. |
| `/iou activity` / `/iou trades` | Recent transfers, loan capture, review, and repayment Undo. |
| `/iou shared [full name]` | Open Requests. Opening it sends nothing. |
| `/iou settings` | Automatic tracking, Requests, display preferences, and optional backups. |
| `/iou export` / `/iou import` | Optional personal export or restore. |
| `/iou test [full name]` | Optional connection diagnostic; ordinary use does not require it. |
| `/iou help` | All commands, including minimap, reminders, and position controls. |

The minimap button and an optional game keybinding also open IOU. Window position is remembered. Each character has a separate ledger.

## Installation and saved data

Install through CurseForge, or extract the release ZIP's `IOU` folder into `_classic_beta_/Interface/AddOns/`. The final path is `AddOns/IOU/IOU.toc`. **Fully restart WoW after updating to 1.0.0**, which adds addon files. GitHub's automatic Source code archive needs its folder renamed to `IOU`.

IOU stores character ledgers, Shared history, recent activity, links, and display preferences in `IOUDB`. Successful reload/logout saves these records; updating addon files keeps existing data. Personal `IOU2:` exports include personal records and payment history. Activity receipts and Shared consent records are separate; Shared recovery uses `IOUS1:`. Exports are optional and may contain private player names and notes.

IOU targets Forever interface `16001`. Other WoW clients are unverified. It has no third-party addon library dependencies and is licensed under [MIT](LICENSE).

## Release readiness and development

**1.0.0 implements the planned feature set. Live testing of changes from 0.7 onward is still pending.** Earlier live reports confirmed personal persistence, Shared messaging/payment exchanges, and tooltip/trade reminders; they do not establish the new trade/mail observers or 1.0 synchronization. The [short testing guide](docs/manual-testing.md) covers ordinary play without requiring screenshots or exports.

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
python tools/test_curseforge.py
python tools/package_iou.py
```

The Lua 5.1 harness covers financial rules, validation, simulated clients, and UI interactions. Mocks cannot prove native event timing, rendering, or every interaction with other addons. CI validates changes and matching `vX.Y.Z` tags publish regular GitHub and CurseForge **Release** files. See [Publishing](docs/publishing.md), [Contributing](CONTRIBUTING.md), the [changelog](CHANGELOG.md), and the [roadmap](docs/roadmap.md).
