# Changelog

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
