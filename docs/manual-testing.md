# In-game testing

Target client: **WoW: Forever**, interface `16001`.

Record the addon version, client build, date, resolution, UI scale, and other addons enabled when reporting results. Use invented names and disposable agreements. If testing an existing character, export its ledger first and retain the text privately.

## Validation record

| Version | Evidence | Scope |
| --- | --- | --- |
| 0.1.0 | In-game user report on 15 October 2026 | Records survived `/reload` and a full game exit/restart. Basic gold/favor creation, settlement, history, and export were demonstrated. |
| 0.1.1 | Lua 5.1 regression and mocked UI checks | Updated persistence copy; no new claim of live client verification. |
| 0.2.0 | Lua 5.1 regression and mocked UI checks, plus package validation | Covers domain logic, backup/migration behavior, and simulated interactions. The live cases below remain to be performed for 0.2.0. |
| 0.3.0-alpha.1 | Automated regressions, mocked UI, and simulated two-client transport | Adds an opt-in diagnostic only. Ordinary chat whispers shown by the user do not establish addon-message delivery. Live connection reports are pending. |
| 0.3.0-alpha.2 | Offline shared-engine/codec simulations plus existing regressions | Exercises acceptance, duplicate and lost-message recovery, withdrawal races, strict input validation, and missing consent. No claim of live shared proposals or persisted shared records. |
| 0.3.0-alpha.3 | Mocked UI, framing, service persistence, and full two-client packet simulations | Exercises the live-path implementation with mock clients, exact terms review, interruption/recovery, character isolation, queue failures, and malformed shared data. Actual client delivery/rendering/persistence are pending; no live result inferred. |
| 0.3.0-alpha.4 | Payment codec/domain, mocked UI, and full two-client payment packet simulations, plus existing regressions | Exercises partial payment, settlement, full reversal, exact historical binding, lost ACKs, duplicates, reload, stale drafts, and personal-ledger isolation. Live testing remains deferred while servers are unavailable. |
| 0.3.0 | The same shared implementation promoted to the normal Release channel; automated regressions, publisher checks, and package validation | Distribution changes do not establish live compatibility. Shared delivery, rendering, and shared-record persistence remain unverified. |
| 0.3.0 diagnostic | User report on 16 October 2026, Forever 1.60.1/build 70425/interface 16001 | Version and local name loaded, prefix registered, four local preflights passed. Listen was rejected by the broad realm restriction flag; no test traffic was sent. This is local setup evidence, not a round trip. |
| 0.3.1 | Focused UI/report, diagnostic transport, and shared-wire regressions plus existing simulations and publisher/package checks | Removes the unsupported blanket veto while retaining real lockdown and native API failures. Actual logged-whisper delivery remains pending a retry; no live success inferred. |
| 0.3.1 live report | User and peer reports/screenshots on Forever 1.60.1/build 70425/interface 16001 | Diagnostic sends reported Success but timed out at 0/4. A later Shared agreement reached Agreed/peer receipt and a payment was declined. Overlapping dialogs and delayed edit focus were reported. Shared traffic worked in that session; complete feature/persistence validation remains pending. |
| 0.3.2 | UI stacking/focus, optional-reason, and protocol-2 diagnostic regressions plus existing simulations and publisher/package checks | Focus/order are verified in mocks; actual latency and protocol-2 delivery need a live retry. Existing Shared records are retained. |

Run `python tools/test_iou.py` for the current automated check list and result. A passing harness cannot establish the actual client's rendering, event delivery, keybinding registration, minimap behavior, combat taint, or SavedVariables persistence.

For shared communication, follow the [connection test guide](connection-test.md). Both players use the same build; IOU generates Unicode and byte-boundary probes automatically. Capture both private reports, including failures. Verify closing the window or using `/iou test stop` stops traffic, and that listening is off after reload. Personal records must remain unchanged.

The [Shared guide](shared-agreements.md) describes the 0.3.0 player flow. When live testing resumes, cover both debtor directions, partial payment, settlement, full reversal with a reason, pending acknowledgment, stale drafts/reviews, decline/withdraw races, reload at each handshake step, retained agreed records, and local review of paused records. Check reduced UI scale and long Unicode notes. Personal totals and personal export/import must remain independent. Live testing is currently deferred; automated simulation is the recorded evidence for this build.

## Live regression cases

All cases below are **pending live verification for the current release**. Update the record with actual results instead of inferring success from mocks.

| Case | Steps | Expected result |
| --- | --- | --- |
| First install | Install the release ZIP with `AddOns/IOU/IOU.toc`, fully restart, enable IOU, and enter `/iou`. | Ledger opens without a Lua error; only this character's data appears. |
| Upgrade an existing ledger | Keep a private export, install the current release, and log in with existing records. | Names, original amounts, balances, notes, payment events, and corrections are retained. No extra payments appear. |
| Gold and directions | Create one agreement in each direction with gold, silver, and copper. | Entries appear in the correct tabs and summary cards; all balances use exact copper. |
| Items and favors | Create item and favor agreements. Insert a Shift-click item link into the focused item field. | Labels remain readable, links remain intact, and quantities do not affect gold totals. |
| Partial payment and settlement | Repay part of an agreement, then settle its remainder. | Balance decreases by the entered amount, history retains both actions, and the settled entry moves to History. Overpayment is rejected. |
| Correct a repayment | Reverse a payment with a reason, including one on a settled agreement. | The correction and reason are recorded, the original payment stays visible, and an outstanding balance reopens in the correct tab. |
| Edit details | Use Edit details to change player, label, note, and due date with a reason. | Details update and history records the changes. Financial amount, type, and direction cannot be changed through this form. |
| Cancel and restore | Cancel an unpaid and a partially paid agreement, then restore each with a reason. | Cancellation removes active balances without creating a repayment; restoration brings back the same remaining balance and retained history. |
| Due dates | Use a past day, today, a future day, blank input, and an impossible date such as `2026-02-30`. | Past open entries are overdue; today remains current until local end of day; blank removes the due date; invalid dates are rejected. |
| Login reminders | Create overdue entries in both directions, reload with reminders enabled, then disable reminders and reload again. | Counts describe this character's overdue open agreements. Disabling reminders suppresses the login summary. |
| Find and sort | Search by player, label, and note. Change type filters and each sort option with several records. | Results and displayed summaries match the active filters; sort is consistent; selected records and pagination remain usable. |
| History and long text | Open settled/cancelled entries and an agreement with many events and a long Unicode note. | Paging and scrolling work; Full note shows the complete stored text without clipping or loss. |
| Minimap launcher | Click and drag the launcher, hide/show it through settings and commands, then reload. | Toggle works; placement and visibility persist; hiding it does not remove command access. |
| Keybinding | Find IOU in keybindings, assign a key, and press it with chat closed. | The binding toggles the ledger without errors; no default key is taken over. |
| Window placement | Drag the header, close/reopen, reload, then run `/iou resetpos`. | Placement survives reopen/reload; reset returns it to a usable position. |
| Backup round trip | Export a ledger containing new fields, preview it, cancel, then preview and confirm. | Cancel changes nothing; confirmed replacement retains amounts, history, due dates, edits, cancellations, and Unicode. |
| Previous ledger | Change the current ledger, confirm an import, then preview Previous ledger. | The snapshot matches the ledger immediately before replacement; another confirmed import replaces that one snapshot. |
| Legacy and invalid import | Preview a synthetic `IOU1:` backup and malformed/truncated text. | Valid legacy data upgrades with intact records; invalid input gives a useful error and does not change the ledger. |
| Character isolation | Create different entries on two characters, then switch between them. | Each character gets its own agreements and overdue counts; imports replace only the current ledger. Display/reminder preferences are shared. |
| Persistence | Create, pay, edit, and cancel records. Run `/reload`, then log out and fully exit/restart the game. | Records and settings survive both paths, with no duplicated history events. |
| Layout and other addons | Check normal and reduced UI scales, at least two resolutions, tooltips, item links, and other commonly used UI addons. | Forms, close buttons, lists, notes, and confirmation controls remain readable and reachable. |
| Combat interactions | Open/close the ledger and launcher in and out of combat, then inspect errors. | Normal gameplay is unaffected and no blocked action or taint error appears. |

For a bug report, include the smallest sequence that reproduces the issue and the full Lua error text. Avoid posting account files or real ledger exports in public.
