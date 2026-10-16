# IOU

A personal debt and favor ledger for **WoW: Forever**. Remember who owes you gold, items, or help, and what you owe other players.

Create an agreement, record repayments as they happen, and keep the history when it is settled. Each character has a separate ledger.

**0.3.0-alpha.4 adds shared gold repayments and corrections.** The stable personal ledger remains available as [0.2.0](https://github.com/PhilForever/IOU/releases/tag/v0.2.0). Open **Shared** or `/iou shared` to enable communication with one player, propose terms, and review an offer before accepting. The original proposer can then record partial payments, settlement, or a full reversal of one payment; each requires the other player's acknowledgment. Both players need alpha.4 for these new events. Automated simulations cover the full flow; actual Forever delivery and rendering remain unverified.

Downloads: [GitHub Releases](https://github.com/PhilForever/IOU/releases) · [CurseForge](https://www.curseforge.com/wow/addons/iou).

## Install

1. Download an `IOU-<version>.zip` asset from [Releases](https://github.com/PhilForever/IOU/releases), when available.
2. Extract its `IOU` folder into `_classic_beta_/Interface/AddOns/`. The final path must be `AddOns/IOU/IOU.toc`.
3. Start the game, enable **IOU** in the AddOns list, and enter `/iou`.

For a source checkout, copy the repository into a folder named `IOU` under `AddOns`; `IOU.toc` must be directly inside it. GitHub's automatic **Source code** archives use a different folder name, which you need to rename. Fully restart the client after a first installation or an update that adds files or keybindings. An ordinary Lua-only update can be loaded with `/reload`.

IOU targets Forever interface `16001`. Version 0.1 was tested in game with both `/reload` and a full exit/restart, including working saved data. Version 0.2 adds the features below and still needs the live regression checks in the [manual testing guide](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md). Compatibility with other WoW clients has not been established.

## Keep track of an agreement

Click **+ New IOU**, choose **Owed to me** or **I owe**, and enter the player and agreement type:

| Type | Example | How to enter it |
| --- | --- | --- |
| Gold | A 5g loan | Enter gold, silver, and copper. |
| Items | 20 Linen Cloth | Enter a whole quantity and item name or link. |
| Favor | 30 minutes of quest help | Enter quantity `30` and label `minutes of quest help`. |

Use the player's full name to distinguish characters. Item links can be pasted or inserted by focusing the item label field and Shift-clicking an item. Notes and an optional due date provide context. Enter dates as `YYYY-MM-DD`; an agreement becomes overdue after the end of that day in the client's local time.

Select an agreement to view its remaining balance and history. Record a partial payment or delivery, or settle its remaining balance. A mistaken repayment can be reversed with a reason; the original event and correction stay visible.

Use **Edit details** to change the player, item/favor label, note, and due date with an audit reason. Amount, type, and direction stay fixed so an edit cannot rewrite a loan's financial history. **Cancel IOU** removes an agreement from active balances without recording a payment. **Restore IOU** brings it back; both actions require a reason and retain the records.

## Find what needs attention

- **Owed to me**, **I owe**, and **History** separate active agreements from completed or cancelled records.
- Search player names, labels, and notes, filter by gold/items/favors, and sort by newest, oldest, player, or due date.
- Due dates make overdue agreements visible. Optional login reminders summarize overdue agreements for the current character.
- The minimap button opens the ledger. You can also assign a key in the game's keybinding settings.
- Move the ledger by dragging its header; IOU remembers its position.

Gold summaries cover gold agreements only. Item and favor quantities retain their own units.

## Commands

| Command | Action |
| --- | --- |
| `/iou` | Show or hide the ledger. |
| `/iou add` | Open a new agreement. |
| `/iou export` | Open this character's backup text. |
| `/iou import` | Open the backup import dialog. |
| `/iou settings` | Open launcher, reminder, and position settings. |
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

Use **Backups** or `/iou export`, select the entire text with **Ctrl+A**, copy it with **Ctrl+C**, and save it outside the game. A backup includes the current character's personal agreements and history. Shared agreements are not included in `IOU1`/`IOU2` exports or affected by personal imports. Backups can contain player names and private notes; remove personal information before sharing one in a public issue.

To restore a backup, paste it in `/iou import`, choose **Preview import**, review the replacement, and confirm. Import replaces the current character's ledger rather than merging it. Cancelling the preview leaves your data unchanged. **Previous ledger** provides the snapshot taken before the last confirmed replacement; there is one previous snapshot per character.

Version 0.2 exports `IOU2:` backups, accepts older `IOU1:` backups, and upgrades older saved ledgers while preserving agreements and events. The backup is encoded text, not executable Lua. Keep the prefix and the entire backup; visual wrapping is normal.

## What IOU records

The personal ledger is manual bookkeeping. It does not detect trades, verify payments, or synchronize personal entries. A settled personal entry records your own decision. Gold balances use whole copper, and item/favor repayments use whole quantities.

The alpha's **Shared** view exchanges gold agreements, payments, and reasoned payment reversals with one enabled peer. Both players opt in; a separate review shows exact terms and prior payment history before consent. The original agreement proposer sequences events, regardless of who owes the gold. Closing the window or reloading disconnects and pauses unfinished offers. The proposer updates a payment balance after observing the peer's acknowledgment; the recipient updates on commitment, so missing acknowledgment can temporarily leave different displayed balances. Shared records stay separate from personal totals. Read the [Shared guide](https://github.com/PhilForever/IOU/blob/main/docs/shared-agreements.md) for use and interrupted-offer recovery.

The alpha's **Settings > Connection test** sends fixed diagnostic text over logged addon whispers only while you explicitly enable it for one player. Both players need the same build, enter each other's full name, and click **Listen**; one clicks **Run test**. IOU checks ASCII, Unicode, and 239/240-byte messages automatically and creates a copyable report. Keep both windows open; closing the window, **Stop**, or a reload disables listening. See the [short connection guide](https://github.com/PhilForever/IOU/blob/main/docs/connection-test.md). Reports contain player names, so share them privately.

The [Shared Agreements specification](https://github.com/PhilForever/IOU/blob/main/docs/shared-agreements-protocol.md) and [development guide](https://github.com/PhilForever/IOU/blob/main/docs/shared-development.md) describe the engine, bounded transport, and storage. Development continues independently of live testing; actual two-client delivery remains unverified and must be reported separately from simulations.

No third-party addon libraries are required. The addon is available under the [MIT license](LICENSE).

## Development

Python 3.12 and Lupa run the Lua 5.1 regression harness:

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
python tools/test_curseforge.py
python tools/package_iou.py
```

The package command validates TOC/XML dependencies and builds an installable ZIP under `artifacts/`, with a SHA-256 checksum. Only runtime files, this README, the changelog, and the license are included. CI runs the same checks on pull requests and pushes to `main`. Pushing a `v<version>` tag runs the release workflow; the tag must match `IOU.toc`. The verified ZIP is published to GitHub and CurseForge. Hyphenated prerelease versions are marked as prereleases and do not replace the latest stable release. See [Publishing](https://github.com/PhilForever/IOU/blob/main/docs/publishing.md) for configuration and backfilling existing tags.

Automated tests exercise domain behavior, backup validation, mocked UI interactions, and simulated two-client diagnostic traffic. They cannot establish actual rendering, event delivery, combat taint, or persistence in the client. See [Contributing](https://github.com/PhilForever/IOU/blob/main/CONTRIBUTING.md), the [changelog](CHANGELOG.md), and the [manual testing guide](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md).
