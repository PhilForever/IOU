# In-game testing

Target client: **WoW: Forever**, interface `16001`.

Use disposable records when trying financial actions. Record the addon version and client build when reporting a failure. Existing backup/recovery checks do not need repeating for this release.

## Normal-use check for 0.8.0

Personal and Shared debts in the trade and tooltip reminders were confirmed working by the user. The user also reported the 0.7 presentation improved. There is no need to repeat those demonstrations or send screenshots/exports.

Fully restart for the added addon files. Use disposable amounts with a friend:

1. Add a personal IOU saying your friend owes you 10 silver. Have them successfully trade you 3 silver with nothing sent back. The balance should become 7 silver once. Use **Undo** on the notice or `/iou trades`; it should return to 10 silver.
2. Try the same flow with a small quantity of a linked crafting item. Cancel a separate trade before completion; cancellation must not change the balance. With two eligible IOUs for that friend, the completed trade should wait for a choice in Trade activity rather than choose a debt silently.

Report whether the successful gold/item trade reduced the right balance once, cancellation left it unchanged, and Undo restored it. If a trade was not detected, give the client build and the short sequence used. Full Lua error text helps if an error appears. Screenshots, exports, and backup tests are not required. Shared repayments still use confirmation; mail automation is not implemented in 0.8.

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
| 0.3.2 live reports | Two private client reports and user screenshots on 16 October 2026, Forever 1.60.1/build 70425/interface 16001 | All four exact diagnostic echoes succeeded, including Norwegian UTF-8 and 239/240-byte packets. Shared screenshots show acknowledged partial payment, correction using the default reason, and final zero/settled balance. A measured focus-latency result and full restart of Shared data were not explicitly reported. |
| 0.4.0 | Bounded Shared backup codec, service recovery, and complete-addon UI simulations plus existing checks | Exercises same-character restore, add-missing union, conflicts, retained closure evidence, capacity, stale bindings, recovery gate across reload, explicit decisions, and zero recovery traffic. Live backup/recovery remains pending. |
| 0.5.0 | Pure presentation and complete-addon workflow checks plus existing suites | Exercises classified views, search/global counts, acknowledged remaining amounts, selection/pagination, explicit selected-peer enabling, stale guards, passive notices, incoming focus/scroll preservation, and detached snapshot rendering. Live workflow and prior recovery verification remain pending. |
| 0.5.0 live feedback | Private before/after exports, screenshots, and user report on 17 October 2026 | User reported successful backup checks with the existing settled balance and record count retained. Supplied snapshots validate and preserve prior records; they retain the new test proposal as interrupted rather than accepted. Sender Waiting versus recipient Needs review was expected. Board closure/reconnection and paused-offer review were confusing; no completed new financial sequence is inferred from these snapshots. |
| 0.6.0 | Pure exact-player summary, client-context, and workflow checks plus existing suites | Adds personal-first navigation, target-prefilled creation, read-only tooltip/trade reminders, and window-close session retention. |
| 0.6.0 live feedback | User report on 17 October 2026 | Personal and Shared IOUs appear in Trade and Tooltip. The user found the addon improved and requested further decluttering. This is sufficient evidence of those live reminders; no repeat screenshots are requested. It does not separately establish every disconnect, failure, or native UI condition. |
| 0.7.0 | Compact presentation and existing financial/consent regression suites | Shortens the ordinary UI, collapses secondary information, and exposes Requests. No automatic trade/mail balance updates or financial/schema changes. Live usability remains to be assessed through ordinary use. |
| 0.7.0 live feedback | User report on 17 October 2026 | The user found the addon improved and requested continued automation with less manual input. |
| 0.8.0 | Trade matching, observer, service, Activity UI, and existing regression suites | Exercises completed/cancelled/failed/duplicate trade observations, exact personal matching, partial/excess amounts, item identity, allocation, Undo, and quiet notices. Native trade completion and event ordering remain pending live use; no automatic Shared consent or mail collection is inferred. |

Run `python tools/test_iou.py` for the current automated check list and result. A passing harness cannot establish the actual client's rendering, event delivery, keybinding registration, minimap behavior, combat taint, or SavedVariables persistence.

The [connection test guide](connection-test.md) is available for investigating transport failures. Both players use the same build; IOU generates Unicode and byte-boundary probes automatically. Closing the diagnostic window, `/iou test stop`, or reload must stop diagnostic traffic. The successful 0.3.2 live diagnostic does not need routine repetition.

The [Shared guide](shared-agreements.md) describes the player flow. The 0.3.2 pilot covered payment/correction/settlement. The maintainer cases below retain broader checks for both directions, pending acknowledgment, stale reviews, decline/withdraw races, reduced UI scale, and long Unicode notes. They are a regression reference, not a required player test script.

Optional recovery regression: preview your own Shared export, stage it, reload, and restore missing history or keep current records. Existing records/counts/balances must remain unchanged and sharing stays off. Do not delete live SavedVariables to simulate loss; use disposable harness data for missing-record cases.

## Live regression cases

This is a maintainer regression reference, not a required player checklist. Some cases have live evidence in the table above; others remain unverified for the current release. Update the record with actual results instead of inferring success from mocks.

| Case | Steps | Expected result |
| --- | --- | --- |
| First install | Install the release ZIP with `AddOns/IOU/IOU.toc`, fully restart, enable IOU, and enter `/iou`. | Ledger opens without a Lua error; only this character's data appears. |
| Upgrade an existing ledger | Keep a private export, install the current release, and log in with existing records. | Names, original amounts, balances, notes, payment events, and corrections are retained. No extra payments appear. |
| Gold and directions | Create one agreement in each direction with gold, silver, and copper. | Entries appear in the correct tabs and summary cards; all balances use exact copper. |
| Items and favors | Create item and favor agreements. Insert a Shift-click item link into the focused item field. | Labels remain readable, links remain intact, and quantities do not affect gold totals. |
| Partial payment and settlement | Repay part of an agreement, then settle its remainder. | Balance decreases by the entered amount, history retains both actions, and the settled entry moves to History. Overpayment is rejected. |
| Correct a repayment | Reverse a payment with a reason, including one on a settled agreement. | The correction and reason are recorded, the original payment stays visible, and an outstanding balance reopens in the correct tab. |
| Edit details | Use Edit details to change player, label, note, and due date with a reason. | Details update and history records the changes. Financial amount, type, and direction cannot be changed through this form. |
| Cancel and reopen | Use More to cancel an unpaid and a partially paid agreement, then reopen each with an optional reason. | Cancellation retains history and removes active balances without creating a repayment; reopening brings back the same remaining balance. |
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
