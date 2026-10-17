# IOU

A gold and item debt tracker for **WoW: Forever**. Remember who owes you 10g or 20 Linen Cloth, and what you owe other players.

Click **+ New IOU**, enter the player and amount, and save. Targeting a player fills their name for you. Each character has a separate ledger; the other player does not need IOU for your own records.

**0.6.0 brings your records into normal play.** Hover a player to see what they owe you or what you owe them. Opening a trade shows the same reminder; **Target IOUs** opens the ledger for your target. Gold in each direction and item quantities stay separate. These reminders never record a repayment or change a trade.

**Shared agreements are optional.** Open them from Settings when both players want to acknowledge a gold agreement. Closing the Shared window now leaves your chosen session enabled so the other player can review later in that session. **Disconnect**, logout, or reload stops sharing and pauses unfinished offers. Optional backups remain available in Settings. The new tooltip, trade, and close-window behavior await live verification.

Downloads: [GitHub Releases](https://github.com/PhilForever/IOU/releases) · [CurseForge](https://www.curseforge.com/wow/addons/iou).

## Install

Install or update **IOU** through the CurseForge app. For manual installation:

1. Download an `IOU-<version>.zip` asset from [Releases](https://github.com/PhilForever/IOU/releases).
2. Extract its `IOU` folder into `_classic_beta_/Interface/AddOns/`. The final path must be `AddOns/IOU/IOU.toc`.
3. Start the game, enable **IOU** in the AddOns list, and enter `/iou`.

For a source checkout, copy the repository into a folder named `IOU` under `AddOns`; `IOU.toc` must be directly inside it. GitHub's automatic **Source code** archives use a different folder name, which you need to rename. Fully restart the client after a first installation or an update that adds files or keybindings. An ordinary Lua-only update can be loaded with `/reload`.

IOU targets Forever interface `16001`. Version 0.1 was tested in game with both `/reload` and a full exit/restart, including working saved data. Later features still need the live regression checks in the [manual testing guide](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md). Compatibility with other WoW clients has not been established.

## Record what someone owes

Target the player if they are nearby, click **+ New IOU**, and choose **Owed to me** or **I owe**. Enter gold or an item quantity and name, then save. No sharing, connection test, due date, or explanation is needed.

| Type | Example | How to enter it |
| --- | --- | --- |
| Gold | A 5g loan | Enter gold, silver, and copper. |
| Items | 20 Linen Cloth | Enter a whole quantity and item name or link. |
| Favor | 30 minutes of quest help | Enter quantity `30` and label `minutes of quest help`. |

Use the player's full name to distinguish characters. Item links can be pasted or inserted by focusing the item label field and Shift-clicking an item. Notes and an optional due date provide context. Enter dates as `YYYY-MM-DD`; an agreement becomes overdue after the end of that day in the client's local time.

Hover that player or open a trade to see your open records. Reminders use the complete player name, ignoring ASCII letter case and repeated spaces. They do not match a first name to a different surname or guess realm names. NPCs have no player-debt reminder. **Settings** lets you turn player tooltips and trade reminders on or off.

Select an agreement to view its remaining balance and history. Record a partial payment or delivery, or settle its remaining balance. A mistaken repayment can be reversed; the original event and correction stay visible. Notes, due dates, and reasons are optional. Blank reasons are retained as "No reason provided" in the history.

Use **Edit details** to change the player, item/favor label, note, and due date with an optional audit reason. Amount, type, and direction stay fixed so an edit cannot rewrite a loan's financial history. **Cancel IOU** removes an agreement from active balances without recording a payment. **Restore IOU** brings it back; both actions retain the records and accept an optional reason.

## Find what needs attention

- **Owed to me**, **I owe**, and **History** separate active agreements from completed or cancelled records.
- Search player names, labels, and notes, filter by gold/items/favors, and sort by newest, oldest, player, or due date.
- Due dates make overdue agreements visible. Optional login reminders summarize overdue agreements for the current character.
- The minimap button opens the ledger. You can also assign a key in the game's keybinding settings.
- **Target IOUs** finds records for your selected player. Shared appears in the main header when an offer or recovery needs attention; otherwise open it from Settings. Shift-left-click the minimap button also opens Shared review. Notices never open a window or accept an offer automatically.
- Move the ledger by dragging its header; IOU remembers its position.

Gold summaries cover gold agreements only. Item and favor quantities retain their own units.

## Commands

| Command | Action |
| --- | --- |
| `/iou` | Show or hide the ledger. |
| `/iou add` | Open a new agreement. |
| `/iou export` | Open this character's backup text. |
| `/iou import` | Open the backup import dialog. |
| `/iou settings` | Open tooltip/trade preferences, Shared agreements, backups, and other settings. |
| `/iou shared [full player name]` | Open experimental shared agreements without sending. |
| `/iou shared off` | Disconnect and pause unfinished shared offers. |
| `/iou test [full player name]` | Open the optional connection test without sending; Listen enables replies. |
| `/iou test stop` | Stop connection-test sending and listening. |
| `/iou minimap show` / `/iou minimap hide` | Show or hide the minimap button. |
| `/iou reminders on` / `/iou reminders off` | Enable or disable login reminders. |
| `/iou resetpos` | Reset the ledger window position. |
| `/iou help` | Show all available commands and settings. |

In keybinding settings, find **IOU** and assign the ledger toggle to a key of your choice.

## Saved data and backups

IOU stores its data in the account SavedVariable `IOUDB`, with separate personal character ledgers, separate shared-agreement records, and account display/reminder settings. WoW saves it on a successful reload or logout. Updating the addon files keeps those records.

Optional exports are under **Settings → Backups** or `/iou export`. Select the entire text with **Ctrl+A**, copy it with **Ctrl+C**, and save it outside the game. A backup includes the current character's personal agreements and history. Shared agreements are not included in `IOU1`/`IOU2` exports or affected by personal imports. Backups can contain player names and private notes; remove personal information before sharing one in a public issue.

Use **Shared backups** in either backup window or the Shared board for a separate `IOUS1:` export. It includes this character's complete Shared records and local evidence. Restoring requires the same character identity, stages a disconnected review, and adds only missing records after validating the combined history. Existing versions and closed-offer markers are preserved. Different versions remain available for comparison; they are not automatically reconciled with the other player. The original imported snapshot and the records before the most recent recovery remain available to copy. This is a local snapshot, not a signed receipt or a new peer acknowledgment.

To restore a backup, paste it in `/iou import`, choose **Preview import**, review the replacement, and confirm. Import replaces the current character's ledger rather than merging it. Cancelling the preview leaves your data unchanged. **Previous ledger** provides the snapshot taken before the last confirmed replacement; there is one previous snapshot per character.

Version 0.2 exports `IOU2:` backups, accepts older `IOU1:` backups, and upgrades older saved ledgers while preserving agreements and events. The backup is encoded text, not executable Lua. Keep the prefix and the entire backup; visual wrapping is normal.

## What IOU records

The personal ledger is manual bookkeeping. Opening a trade displays a read-only reminder; completing it does not record a payment, item delivery, or settlement. A settled personal entry records your own decision. Gold balances use whole copper, and item/favor repayments use whole quantities.

The **Shared** view exchanges gold agreements, payments, and payment reversals with one enabled peer. Both players opt in; a separate review shows exact terms and prior payment history before consent. The original agreement proposer sequences events, regardless of who owes the gold. Closing the window leaves that session enabled; **Disconnect**, logout, or reload stops it and pauses unfinished offers. The proposer updates a payment balance after observing the peer's acknowledgment; the recipient updates on commitment, so missing acknowledgment can temporarily leave different displayed balances. Your own notes and Shared records are labeled separately in reminders because they may describe the same debt; IOU never adds them together. Shared items are not supported yet. Read the [Shared guide](https://github.com/PhilForever/IOU/blob/main/docs/shared-agreements.md) for use and interrupted-offer recovery.

**Settings > Connection test** sends fixed diagnostic text over logged addon whispers only while you explicitly enable it for one player. Both players need the same build, enter each other's full name, and click **Listen**; one clicks **Run test**. IOU checks ASCII, Unicode, and 239/240-byte messages automatically and creates a copyable report. Keep both windows open; closing the window, **Stop**, or a reload disables listening. See the [short connection guide](https://github.com/PhilForever/IOU/blob/main/docs/connection-test.md). Reports contain player names, so share them privately.

The [Shared Agreements specification](https://github.com/PhilForever/IOU/blob/main/docs/shared-agreements-protocol.md) and [development guide](https://github.com/PhilForever/IOU/blob/main/docs/shared-development.md) describe the engine, bounded transport, and storage. Two live 0.3.2 clients demonstrated diagnostic delivery and acknowledged payment/correction/settlement. The user reported successful backup checks on 0.5.0; its supplied exports preserve existing records but retain the new test proposal as interrupted. These results do not establish the new 0.6.0 interactions or every client condition.

No third-party addon libraries are required. The addon is available under the [MIT license](LICENSE).

## Development

Python 3.12 and Lupa run the Lua 5.1 regression harness:

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
python tools/test_curseforge.py
python tools/package_iou.py
```

The package command validates TOC/XML dependencies and builds an installable ZIP under `artifacts/`, with a SHA-256 checksum. Only runtime files, this README, the changelog, and the license are included. CI runs the same checks on pull requests and pushes to `main`. Pushing a `v<version>` tag runs the release workflow; the tag must match `IOU.toc`. The verified ZIP is published to GitHub and CurseForge. Normal releases use `X.Y.Z` versions and CurseForge's **Release** channel so app users receive updates under the default setting. Prereleases require an explicit owner request. See [Publishing](https://github.com/PhilForever/IOU/blob/main/docs/publishing.md) for configuration and backfilling existing tags.

Automated tests exercise domain behavior, backup validation, mocked UI interactions, and simulated two-client diagnostic traffic. They cannot establish actual rendering, event delivery, combat taint, or persistence in the client. See [Contributing](https://github.com/PhilForever/IOU/blob/main/CONTRIBUTING.md), the [changelog](CHANGELOG.md), and the [manual testing guide](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md).
