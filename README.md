# IOU

Remember who owes you gold or crafting materials, and what you owe other players. **IOU** is a debt tracker for **WoW: Forever**.

Target a player, click **+ New IOU**, choose the direction and amount, and save. Hovering that player or opening a trade shows the remaining debt. Your own records work even if the other player does not have IOU.

**0.8.0 records straightforward trade repayments automatically.** A completed matching gold or item transfer reduces the personal IOU, with a quiet notice and **Undo**. Ambiguous trades wait in **Trade activity**. Requests, optional details, and history retain the compact 0.7 interface.

[Download on CurseForge](https://www.curseforge.com/wow/addons/iou) · [GitHub Releases](https://github.com/PhilForever/IOU/releases)

## Get started

1. Install **IOU** through the CurseForge app and open it with `/iou`.
2. Target a player and click **+ New IOU**. You can also type their full name.
3. Choose **Owed to me** or **I owe**, then enter gold or an item quantity and name. Notes and a due date are optional.

For items, focus the item field and Shift-click an item, or type its name. Favor records also remain available. Each character has a separate ledger.

Hover the player or open a trade to see what remains. Gold in opposite directions is not netted, and item quantities retain their own units. Personal and Shared reminders have separate labels because they may describe the same real debt. **Target IOUs** finds the selected player's records. Tooltip and trade reminders can be disabled in Options.

## Use the ledger

- **Owed to me**, **I owe**, and **History** separate open debts from completed or cancelled records. Search and type filters help find a record.
- Select a record for its remaining amount. Expand its history when you need the previous payments or changes.
- **More...** contains manual repayment, editing, cancellation, and reopening for exceptions. To correct an individual repayment, expand **History** and use **Undo** on that payment.
- **Requests** opens optional Shared gold agreements. Both players need IOU to share; personal records need no connection or acceptance. See the [short Shared guide](https://github.com/PhilForever/IOU/blob/main/docs/shared-agreements.md).
- **Activity** shows recent completed trades and repayments. **Options** holds automatic trade repayment preferences, display preferences, optional backups, and the connection diagnostic. `/iou trades` also opens Activity.

Click the minimap button or assign IOU a key in the game's keybinding settings. Drag the window header to move it. IOU remembers its position.

## What changes a balance

In **0.8.0**, a confirmed completed trade with an exact player can repay a matching personal IOU automatically. Gold uses exact copper and items use whole quantities and their item identity. Partial repayments leave the remainder open; excess is not turned into a new debt. Opening, accepting, closing, or cancelling a trade alone never records repayment.

An exchange in both directions, an item variant that needs checking, overlapping personal/Shared records, or multiple eligible IOUs needs review. **Trade activity** shows what was given and received and lets you choose an eligible personal IOU without retyping the amount. Shared repayments retain their existing confirmation flow. Unmatched trades are kept quietly as activity; purchases and gifts never become loans automatically. Automatic personal matching can be disabled in Options.

Use **Undo** on the notice or Trade activity to reverse a trade's applied repayments. The original payment events remain in history. Manual **More...** actions remain available for exceptions and favors. Trade activity is separate from personal ledger exports; existing personal and Shared records and export formats are preserved.

Shared gold agreements exchange exact terms with one chosen player. The recipient reviews and accepts an original agreement, payment, or correction. Closing the Shared board leaves an explicitly connected session running; **Disconnect**, logout, or reload stops it and pauses unfinished requests. Closing a window never accepts terms. Shared items and automatic Shared repayments are planned.

Mail automation is next. A successfully sent matching mail repayment will count in the sender's own personal ledger without waiting for collection or a peer acknowledgment. Sending or collecting mail does not change balances in 0.8.0. See the [roadmap](https://github.com/PhilForever/IOU/blob/main/docs/roadmap.md).

## Commands

| Command | Action |
| --- | --- |
| `/iou` | Show or hide the ledger. |
| `/iou add` | Open a new IOU. |
| `/iou target` | Show the selected player's IOUs. |
| `/iou trades` | Review recent completed trades and Undo automatic repayments. |
| `/iou settings` | Open settings. |
| `/iou shared [full player name]` | Open Shared without sending. |
| `/iou shared off` | Disconnect and pause unfinished Shared requests. |
| `/iou export` / `/iou import` | Open optional personal backup/export or restore. |
| `/iou test [full player name]` | Open the optional connection diagnostic without sending. |
| `/iou test stop` | Stop diagnostic sending and listening. |
| `/iou minimap show` / `/iou minimap hide` | Show or hide the minimap button. |
| `/iou reminders on` / `/iou reminders off` | Change login reminders. |
| `/iou resetpos` | Reset the ledger position. |
| `/iou help` | Show available commands. |

## Installation and saved data

For manual installation, download `IOU-<version>.zip` from [Releases](https://github.com/PhilForever/IOU/releases) and extract its `IOU` folder into `_classic_beta_/Interface/AddOns/`. The final path must be `AddOns/IOU/IOU.toc`. Fully restart after a first installation or an update that adds files or keybindings; ordinary Lua-only updates can be loaded with `/reload`.

For a source checkout, name the addon folder `IOU`. GitHub's automatic **Source code** archive needs that folder rename.

IOU stores personal character ledgers, separate Shared records, and account display preferences in `IOUDB`. WoW saves them on a successful reload or logout; updating addon files keeps the records. Personal saved-data persistence was tested with reload and a full restart. The user also confirmed that personal and Shared debts appear in the 0.6.0 trade and tooltip reminders.

Optional exports are under **Options → Backups**. Personal `IOU2:` exports include the current character's personal records and history; imports accept older `IOU1:` data and replace only that personal ledger after preview and confirmation. Shared records use a separate `IOUS1:` format and [recovery flow](https://github.com/PhilForever/IOU/blob/main/docs/shared-backups.md). Exports may contain private player names and notes; do not post them in a public issue.

IOU targets Forever interface `16001`. Other WoW clients have not been verified. There are no third-party addon library dependencies. Licensed under [MIT](LICENSE).

## Development

Python 3.12 and Lupa run the Lua 5.1 regression harness:

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
python tools/test_curseforge.py
python tools/package_iou.py
```

The package command validates TOC/XML dependencies and creates an installable ZIP with a SHA-256 checksum under `artifacts/`. CI runs the checks on pull requests and pushes to `main`. A matching `vX.Y.Z` tag publishes a regular GitHub release and CurseForge **Release**. See [Publishing](https://github.com/PhilForever/IOU/blob/main/docs/publishing.md).

Tests cover financial rules, data validation, mocked UI interactions, and simulated Shared clients. They do not prove native rendering, event delivery, or every client condition. The [testing guide](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md) distinguishes live results from automated evidence. See also [Contributing](https://github.com/PhilForever/IOU/blob/main/CONTRIBUTING.md), the [changelog](CHANGELOG.md), and the [development roadmap](https://github.com/PhilForever/IOU/blob/main/docs/roadmap.md).
