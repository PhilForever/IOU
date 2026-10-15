# Changelog

## 0.3.0-alpha.1 — 2026-10-15

- Added an opt-in **Connection test** under Settings and `/iou test`, preparing for shared agreements.
- Automatically probes predefined ASCII and Norwegian text, plus exact 239/240-byte messages, using logged addon whispers.
- Added a copyable diagnostic report that distinguishes API submission from an exact reply from the selected peer.
- Restricted the listener to one explicitly selected player, bounded response traffic, and stopped it on window close, Stop, or reload.
- Preserved personal ledger storage, backups, and existing agreement behavior.
- Added a revised Shared Agreements protocol draft and a short two-player test guide.

Validation: Lua 5.1 regressions, mocked UI checks, and a simulated two-client transport harness. Actual logged addon delivery and Forever sender naming still require the two-player [connection test](https://github.com/PhilForever/IOU/blob/main/docs/connection-test.md). This prerelease does not implement shared agreements.

## 0.2.0 — 2026-10-15

- Added due dates, overdue indicators, and optional character-specific login reminders.
- Added search across names, labels, and notes, with agreement type filters and sort options.
- Added audited edits for player, label, note, and due date.
- Added cancellation and restoration, preserving the difference between cancelling and paying.
- Added a minimap launcher, a toggle keybinding, and saved window positioning.
- Preserved existing character ledgers, repayment history, and support for `IOU1:` backups while adding the new data fields.
- Added public development instructions, regression CI, deterministic installable ZIPs, issue templates, and a tag-triggered release workflow.

Validation: Lua 5.1 regression tests and mocked UI checks are provided. The new 0.2 features still need live client regression testing; see [manual testing](https://github.com/PhilForever/IOU/blob/main/docs/manual-testing.md).

## 0.1.1 — 2026-10-15

- Removed outdated SavedVariables persistence warnings after successful reload and full client restart testing.

## 0.1.0 — 2026-10-15

- Added gold, item, and favor agreements in both directions.
- Added partial repayments, settlement, and reasoned repayment reversals with retained history.
- Added separate character ledgers, search, and paginated agreement/history views.
- Added validated text backup/import previews and one previous-ledger snapshot per character.
