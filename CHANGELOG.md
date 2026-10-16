# Changelog

## 0.3.2 — 2026-10-16

- Fixed window stacking so foreground dialogs and their inputs stay above the complete background window, including scroll children. Added opaque backgrounds and immediate click focus for single-line and multiline fields.
- Made amendment, cancellation, restoration, reversal, and paused-review reasons optional. Blank reasons record "No reason provided"; existing schemas and exact shared consent remain intact.
- Simplified Shared reviews and payment references while keeping full names, amounts, deadlines, notes, prior event descriptions, and the selected correction target visible.
- Updated the connection diagnostic to protocol 2 (`IOU_LINKv2`) with pipe-free plain text and bounded receive metadata to distinguish absent events from rejected sender/channel/payload.
- Added stacking/focus, optional-reason, and diagnostic regressions. Personal and Shared records remain separate; personal `IOU2` exports do not include Shared.

Validation: Lua 5.1 regressions, two-client simulations, publisher checks, and package validation. Live 0.3.1 screenshots show an acknowledged Shared agreement and a declined payment, while the standalone diagnostic timed out at 0/4. Its old pipe framing is a suspected cause, not a proven diagnosis. Actual focus latency and protocol-2 delivery need live confirmation. Both players need 0.3.2 for the new diagnostic; `/reload` loads this update.

## 0.3.1 — 2026-10-16

- Fixed a broad realm restriction check that prevented enabling the connection test and shared logged whispers even when that flag did not establish the API's availability.
- Kept actual chat-lockdown checks and native logged-send failures in effect; local submission still never counts as a delivery receipt.
- Added both current restriction states, the attempted player, and the exact failed Listen/Run operation to copied diagnostic reports. Unknown or secret results stay safely labeled without exposing raw values.
- Made Stop clear a failed attempt and its visible error, including when listening could not start.
- Updated the connection guide and added focused UI, transport, report, and shared-wire regressions. Existing personal/shared records and protocols are unchanged.

Validation: Lua 5.1 regressions, two-client simulations, publisher checks, and package validation. The user's 0.3.0 report on Forever build 70425 confirmed local preflights passed but no test traffic was sent because of the old check. Actual logged-whisper round trips remain pending a retry on 0.3.1. Published through the regular Release channel.

## 0.3.0 — 2026-10-16

- Published the shared-agreement features through CurseForge's normal **Release** channel, allowing updates with the app's default release setting.
- Included opt-in shared gold proposals, explicit acceptance, partial payments, settlement, and reasoned full reversals of individual payments from the preceding prereleases.
- Retained acknowledged balances, event history, interrupted-offer recovery, and existing personal and shared records without a schema change.
- Made normal `X.Y.Z` Release versions the publishing default; future prereleases require an explicit owner request.

Validation: Existing Lua 5.1 regressions, mocked UI, simulated two-client payment delivery, publisher checks, and package validation. This release promotes the existing shared implementation; actual Forever delivery, rendering, and shared-record persistence remain unverified. Both players should use 0.3.0 for shared agreements.

## 0.3.0-alpha.4 — 2026-10-16

- Added mutually acknowledged shared gold payments, settlement of the remaining balance, and reasoned full reversal of individual confirmed payments.
- Added shared balance and event history, complete payment/correction review, explicit correction-target selection, and stale draft protection.
- Kept the original agreement proposer as the event sequencer; a new event waits for acknowledgment of the parent and latest event. Balances distinguish an acknowledged event from a pending commitment.
- Bound each event to exact original terms, parent commitment, and a flat canonical chain of prior acknowledged events. Rejected stale histories, overlapping events, overpayments, reused reversal targets, and oversized messages before persistence.
- Preserved legacy shared gold terms and personal ledgers without changing their schema, balances, or backup format. Both peers need alpha.4 for payment events.
- Added codec, financial-domain, UI, and full two-client packet simulations covering partial payment, settlement, corrections, acknowledgment loss, duplicates, stale bases, reload, and queue failures.

Validation: Lua 5.1 regressions, mocked UI, simulated two-client packet delivery, publisher checks, and package validation. Actual in-game delivery, rendering, and shared-record persistence remain unverified; live testing is deferred while servers are unavailable. Dedicated shared backup/reconciliation remains future work.

## 0.3.0-alpha.3 — 2026-10-16

- Added an experimental **Shared** view and `/iou shared` for proposing, reviewing, accepting, declining, and withdrawing gold agreements.
- Added full-term confirmation with explicit debtor/creditor, complete notes, and deadlines fixed to end of day UTC.
- Added readable UTF-8 packet framing/reassembly over a separate logged addon whisper prefix, with peer scoping, pacing, bounded queues, expiration, and receive-rate limits.
- Added validated shared SavedVariables per character, separate from personal balances and personal backup/import.
- Paused interrupted offers on disconnect/reload; retained local consent and terminal history without automatic traffic on login.
- Added explicit local review of paused offers, retained tombstones, and replacement guards to prevent silent restarts of unresolved handshakes.
- Added UI, persistence, framing, and two-client integration simulations, including stale confirmation and queue failure cases.

Validation: Lua 5.1 regressions and mocked two-client packet delivery. Actual in-game delivery, rendering, and shared-record persistence remain unverified; live testing is deferred. This remains an opt-in alpha. Shared payments and shared backup/import are future work.

## 0.3.0-alpha.2 — 2026-10-15

- Added the offline shared-agreement engine: explicit proposal, acceptance, commit, acknowledgment, decline, withdrawal, status, and exact retry handling.
- Added a strict plain-text logical codec with exact canonical term binding and validated Unicode, names, amounts, identifiers, and UTC dates.
- Separated agreement state from delivery evidence; missing acknowledgments do not cancel agreements, and missing local acceptance cannot be reconstructed from incoming messages.
- Added bounded immutable stores, duplicate handling, paused recovery, and simulations of dropped/reordered messages, changed terms, withdrawal races, and missing consent.
- Added automated CurseForge publishing using the configured Actions secret and project 1746575, with archive integrity checks and upload receipts.
- Preserved personal ledgers and existing UI. The shared foundation does not yet send proposals, persist shared records, or expose a player consent UI.

Validation: Lua 5.1 regressions and deterministic two-peer simulations, plus publisher integrity/retry checks. Live addon-message testing remains pending; development of the offline foundation does not depend on that test. Framing, saved shared storage, and the opt-in consent UI are the next integration stage.

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
