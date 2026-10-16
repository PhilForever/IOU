# Shared backups and recovery

IOU 0.4.0 adds a separate `IOUS1:` backup for the current character's Shared agreements. Personal backups still use `IOU1:`/`IOU2:` and their restore flow is unchanged. Fully restart the client after installing 0.4.0 because it adds addon files.

## Save a copy

Open **Shared → Shared backups**, or **Backups → Shared backups**. **Current export** selects an armored text snapshot. Copy it with Ctrl+C and save it outside the game. The snapshot includes full terms, participants, payments, corrections, retained local acceptance/commitment/acknowledgment evidence, history, processed messages, allocation counters, and local closed-offer review markers. It contains player names and private notes.

Export and preview do not enable sharing or send messages. A backup belongs to the exact current character storage key and full name. Another player's export cannot be imported as your local consent.

## Preview and restore

1. Choose **Paste backup**, paste the complete `IOUS1:` text, then **Preview backup**. Wrapping and clipboard whitespace are accepted; truncated or malformed data is rejected.
2. Compare the saved, current, and proposed balances. Read any different versions and local review markers. Preview changes no records or connection state.
3. Choose **Stage recovery** to save the imported snapshot and a snapshot of current records. Staging disconnects sharing, discards queued traffic, and pauses unfinished offers. This review gate persists across reloads and applies to agreed records too.
4. Choose **Restore missing history** or **Keep current records**. Closing the review leaves it pending. Both choices leave sharing off. Reopen **Shared backups** to return to a pending review.
5. Compare any differing or unfinished records with the other player before explicitly enabling sharing again.

Recovery adds offers that are absent locally, keeps identical offers once, and preserves every current version and current-only record. Different records under the same ID are shown side by side; they are never overwritten, advanced, or downgraded from a backup. Existing local closed-offer markers always survive. A missing marker can be recovered only when its complete offer evidence matches. Stored serial/counter high-water marks prevent identifier reuse.

The complete combined history must pass the existing consent and financial validations. An incompatible payment chain, duplicate agreement identity, capacity limit, missing local acceptance, or future timestamp blocks restoration without partially adding records. **Keep current records** remains available to finish the review. Correct the source of a conflict and preview again; there is no automatic network reconciliation or force-merge button.

The preview is bound to both the pasted text and the current records. If either changes, preview again. A pending recovery is also bound to its staged baseline. It cannot silently apply to a changed ledger.

## Retained comparison snapshots

**Recovery review** shows the latest staged or completed decision. **Copy staged backup** retrieves the imported text; **Copy records before recovery** retrieves the snapshot taken immediately before staging. One pair is retained per character and is replaced when a later recovery is staged. Copy these outside the game if you need older versions.

Restored acknowledgments describe historical local evidence. They are not a fresh peer confirmation, a signed document, or proof of a gold transfer. Recovery does not create acceptance, resend a queue, overwrite another character, or affect personal balances. A newer backup version of an existing offer remains comparison evidence; this recovery flow does not replace that current offer.

## Format and limits

`IOUS1:` is base64-armored canonical typed data, never Lua source. The envelope is version 1 and includes the exact owner, character key, creation timestamp, and existing version-1 Shared wrapper. The parser rejects duplicate/out-of-order keys, unsupported types, cycles/aliases, metatables, noncanonical integers, malformed padding, trailing data, and excessive trees. Limits are 8 MiB of pasted/exported text, just under 6 MiB of decoded data, depth 12, and 100,000 values/map keys. Service validation checks the full wrapper and agreement graph after parsing.

The recovery sidecar is optional `IOUDB.sharedRecoveryByCharacter[IOU.Character()]`; existing personal and Shared schemas are unchanged. It retains status `PENDING`, `RESTORED`, or `KEPT`, owner/key, staging/resolution times, and both armored snapshots. No recovery traffic occurs automatically.
