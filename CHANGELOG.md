# Changelog

## 1.0.1 — 2026-10-18

- Fixed native named item-quality colors (`|cnIQ1:`) being rejected by item matching, bag selection, trade snapshots, and outgoing mail snapshots. Existing item labels and saved identity keys remain intact.
- Removed color-token fragments from player tooltips and trade reminders.
- Preserved the accepted trade contents when the native window clears money and acceptance during its close handler, before IOU receives the close event. A typed completion event is still required; cancellations and duplicate notifications remain excluded.
- Replaced vague Shared labels with Send request, Ask to confirm, Confirmed, and IOU requests. Unreadable bag contents now show an explanation instead of falsely appearing empty.

Validation: native-link and close-order regressions include gold payment → Undo → two cloth repayments → unrelated items → another gold payment, plus native item mail handling and the existing suites. The first live 1.0.0 pass confirmed one gold payment and Undo, and exposed the item and later-trade failures; the fixes, mail, and confirmation flow still need live verification. Earlier missed trades cannot be reconstructed and are not invented. Existing records and formats are preserved. Use `/reload` after updating from 1.0.0.

## 1.0.0 — 2026-10-17

- Integrated optional sharing into ordinary gold and item IOUs. New loans require recipient acceptance; accepted records link to the personal ledger and reminders avoid counting a linked copy twice. Existing Shared records remain available, with deliberate Add to ledger for older confirmed records.
- Added background request delivery and bounded retries, retaining exact saved consent across reload and interruption. Closing a window no longer creates a connection chore. Unaccepted background invitations use a bounded, expiring session inbox instead of consuming permanent history capacity.
- Added item Shared terms, payment/correction quantities, and compact Requests review. Essential player, direction, balance, and note stay visible; technical details, history, and connection controls remain secondary.
- Added bag item selection, known full-stack quantities, and material bundles of up to 12 items. Activity Track all creates loans deliberately from the remaining unassigned contents of a transfer. Gifts and purchases still never become loans automatically.
- Kept successful outgoing mail repayments immediate in the sender's personal ledger. Observed repayments can exchange Shared synchronization hints and acknowledged events; uncertain matches or conflicting state still need review. Undo retains original payment history.
- Preserved existing personal/Shared records and export formats, and retained manual exceptions and optional backups under More/Options.

Validation: expanded Lua 5.1 domain, UI, two-client, transient inbox, crafting, trade/mail, and regression checks plus publishing/package validation. **Live testing of 0.7 onward remains deferred; no new in-game success is claimed. Fully restart WoW after updating because 1.0.0 adds addon files.** Published through the regular Release channel.

## 0.9.0 — 2026-10-17

- Added matching personal repayments from successfully sent mail. The sender's ledger updates on send success without waiting for collection or peer acknowledgment; postage and COD are excluded.
- Added incoming player-mail observation requiring a native collection, success, and an unambiguous inbox asset change. Failed collections, returned/system/auction mail, unreadable data, and uncertain changes do not become repayments.
- Extended Activity with Trade, Mail sent, and Mail collected. **Track as IOU** creates a personal loan from a chosen unassigned asset with the exact player, amount, and item link already filled; gifts and purchases never become debts automatically.
- Kept repayment Undo separate from explicitly captured loans, preserved existing trade receipts and personal/Shared records, and added independent automatic mail preferences.

Validation: mail observers, real financial service/Activity integration, capture and duplicate protection, plus the existing regression and publishing/package suites. Native 0.8 trade behavior and new mail event timing remain unverified in-game; testing was deferred by the user. Shared confirmation rules are unchanged. **Fully restart after updating because this release adds addon files.** Published through the regular Release channel.

## 0.8.0 — 2026-10-17

- Added completed-trade observation for exact player names, copper, and item quantities. Clear personal IOU repayments apply automatically, including partial repayment; cancelled, failed, and duplicate trade events do not create payments.
- Kept item variants, exchanges, multiple eligible records, and possible personal/Shared overlap for review. Excess and unmatched assets never create new IOUs automatically. Shared repayment consent is unchanged.
- Added compact Trade activity in the main header, Options, and `/iou trades`, with Given/Received summaries, current-balance allocation choices, Dismiss, and Undo. Applied/review notices never open a window, take focus, or print chat messages; ordinary unmatched trades stay quiet.
- Retained manual actions under More and added an automatic trade repayment preference. Existing ledger events, personal/Shared schemas, and backup formats are preserved; recent trade receipts are separate per-character data.

Validation: trade matching, observer, service, and compact Activity UI regressions plus the existing suites, publisher checks, and package validation. Native trade completion and event ordering still need normal live use; mocked events do not establish a successful client transfer. Mail automation remains planned for 0.9. **Fully restart after updating because this version adds addon files.** Published through the regular Release channel.

## 0.7.0 — 2026-10-17

- Made Requests available in the main header, with passive review counts. Existing Shared records remain separate from personal IOUs.
- Shortened money, list rows, record summaries, and ordinary Shared text. Retained history and full agreement details behind expandable controls.
- Collapsed optional New IOU fields and moved manual financial/edit/correction actions into More. Existing records, payment rules, consent, and backup formats are unchanged.
- Added the development roadmap through 1.0, prioritizing automatic trade and mail repayments. Future successful outgoing matching mail counts in the sender's personal ledger immediately after send success; it does not wait for recipient collection or acknowledgment.

Automatic repayments are **not implemented in 0.7.0**. The user confirmed that personal and Shared balances appear in 0.6.0 trade and tooltip reminders. New 0.7.0 presentation behavior remains subject to normal in-game use; no repeat screenshots or backup tests are required.

## 0.6.0 — 2026-10-17

- Put personal gold and crafting-item records first. New IOUs can use the targeted player's full name; the main header offers Target IOUs, while Shared and optional backups remain available in Settings.
- Added player-hover and trade reminders for exact full-name matches. Gold directions and literal item/favor quantities stay separate; personal notes and acknowledged Shared balances are labeled separately to avoid counting the same debt twice.
- Kept trade reminders read-only: they do not offer gold, accept a trade, verify delivery, or record repayments automatically. Tooltip and trade reminders can be disabled in Settings.
- Closing the Shared board now leaves its explicitly enabled player session running. Disconnect, logout, reload, and actual transport failures retain their existing stop/pause behavior. Closing a review never accepts its terms.
- Renamed the sender's Waiting view to Sent. Incoming offers appear under Needs review on the recipient's client; these different views describe the same pending offer.
- Kept attention counts and recovery notices available without putting connection and backup controls ahead of ordinary bookkeeping. Existing ledgers, Shared evidence, and backup formats are preserved.

Validation: read-only player-summary and client-context regressions, complete-addon workflow checks, existing financial/consent/recovery simulations, publisher checks, and package validation. The user reported successful 0.5.0 backup checks; supplied before/after exports validate and preserve prior history, while the new test proposal remains interrupted in those snapshots. The later user report confirms personal and Shared debts in the live 0.6.0 trade and tooltip reminders; it does not separately establish every close-window or failure condition. **Fully restart after this update because it adds addon files.** Published through the regular Release channel.

## 0.5.0 — 2026-10-17

- Split the Shared board into Needs review, Agreements, Waiting, History, and All offers, with global counts, literal name/note search, stable selection, and pagination.
- Show the remaining acknowledged balance on original agreement rows while preserving the amount and type of each payment or correction. Completed events move to History; an original stays active while a financial event is unfinished.
- Added passive review counts on the main Shared button and minimap. Shift-left-click opens Shared review; incoming traffic never opens a dialog or steals the current view, focus, or detail scroll.
- Added explicit enabling for a selected offer's exact player while disconnected, with stale-state checks and recovery gates. Connection copy describes local readiness without claiming the other client is online or enabled.
- Show relevant actions and next-step guidance for the selected offer. Newly sent events are explicitly revealed in their appropriate view without creating duplicate records.
- Added a detached service overview and pure presentation model. Search, filtering, passive notices, and board details use that snapshot; confirmations continue to validate live state.

Validation: Lua 5.1 regression, presentation, and complete-addon workflow checks, plus existing two-client/payment/recovery simulations, publisher checks, and package validation. Live evidence remains the 0.3.2 diagnostic and acknowledged payment/correction/settlement pilot. The 0.4.0 recovery test and new 0.5.0 workflow remain pending. Existing schemas, consent rules, Shared wire formats, and personal backups are unchanged. **Fully restart after this update because it adds an addon file.** Published through the regular Release channel.

## 0.4.0 — 2026-10-16

- Added separate `IOUS1:` Shared backups containing full agreements, payment/correction history, exact retained consent and messages, and closed-offer review markers. Personal `IOU1`/`IOU2` formats and existing records are unchanged.
- Added backup previews with current, saved, and proposed balances, including readable comparisons of differing versions.
- Added staged recovery that disconnects sharing and persists a review gate across reloads. The player explicitly restores missing history or keeps current records before enabling communication again.
- Recovery preserves existing records, current-only history, review markers, and identifier high-water marks. The complete combined financial graph must validate before any missing records are adopted; incompatible histories remain unchanged.
- Retained the imported snapshot and the records before the latest recovery for comparison and external copying. No restore resumes messages or invents missing acceptance.
- Added bounded parser, service recovery, and UI regression checks, and documented the live 0.3.2 connection/payment results.

Validation: Lua 5.1 regressions, two-client simulations, publisher checks, and package validation. Two live 0.3.2 clients completed 4/4 exact ASCII/UTF-8/boundary echoes on Forever build 70425; user screenshots show acknowledged partial payment, a correction with the default optional reason, and final settlement. Those results do not establish live 0.4.0 recovery or a full restart of Shared records. **Fully restart the game after this update because it adds addon files.** Published through the normal Release channel.

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
