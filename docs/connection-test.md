# Connection test

This diagnostic checks IOU's actual addon-message connection. It does not create agreements or change your ledger. Use **0.3.2 or later** on both clients. It uses protocol 2, prefix `IOU_LINKv2`, and pipe-free plain text; a 0.3.1 diagnostic cannot reply to this version.

On 16 October 2026, two live 0.3.2 clients on Forever 1.60.1/build 70425 completed all four exact round trips. Their reports confirm ASCII, Norwegian UTF-8, and 239/240-byte packets survived this logged-whisper path while the broad outgoing restriction flag was true. This establishes those tested sizes in that session, not the client's maximum payload or every network condition. If Shared already works, repeating this diagnostic is optional.

An ordinary chat whisper only checks chat. IOU checks its own addon messages and measures the text for you; you do not need to count bytes or type special characters.

## Two-player test

You need two online characters, each running the same IOU version. After updating from 0.3.1, `/reload` loads this Lua-only fix. Fully restart after a first installation or an update that adds files.

1. Both players open **IOU > Settings > Connection test**, or type `/iou test`.
2. Each enters the other character's full **first name and surname**, as used for whispers. For example: `Amber Stone`. **Use target** can fill this in when you have the other player targeted.
3. Both click **Listen**.
4. One player clicks **Run test** and waits for the result. That player should see **Test complete: 4/4 exact round trips.** The listening player does not need to start a second test.
5. Both click **Copy report**, then press **Ctrl+C** in the report box. Paste the reports into the development chat.
6. Click **Stop** when finished. Listening also turns off on `/reload` or logout.

Keep the Connection test window open on both clients during the test. Closing it or pressing **Escape** stops listening and sending, just like **Stop**.

The addon sends a short set of predefined test messages. It checks simple text, Unicode text, and messages of 239 and 240 bytes. It records what the client reports and whether the other IOU client sends a matching reply. A send result alone does not prove delivery.

Reports include character names and client details. Share them privately; remove names before posting one in a public issue.

## If it does not connect

Check that both players are online, entered the other's full name, clicked **Listen**, and have the same test build. Then run it once more. If it still fails, copy both reports; the failure is useful evidence too.

The report also includes an automatic local preflight. That checks the local setup only. Testing against your own character is blocked so it cannot be mistaken for a successful two-player test.

The report counts diagnostic-prefix events, selected-peer whispers, recognized probes, and reasons for ignored traffic. A capped metadata sample contains channel/sender/target/byte size, never unknown payload text. This distinguishes absent events from rejected names, channels, or frames. The old pipe separators remain a suspected compatibility issue; the later successful protocol-2 test does not by itself prove the cause of the protocol-1 failure.

`Listening: OFF` with only local preflight results means no two-player test has run. A copied report includes the last attempted player/action, its blocking error, and both current and captured restriction states. `AreOutgoingAddonChatMessagesRestricted` is advisory here: that broad realm flag can be true even when addon comms work. Actual `InChatMessagingLockdown` and native logged-send failures still stop messages. Wait for a real lockdown to clear before retrying. IOU never switches to ordinary whispers or unlogged addon messages.

## Commands

| Command | Action |
| --- | --- |
| `/iou test` | Open Connection test. |
| `/iou test Amber Stone` | Open it with that full name filled in; sends nothing. |
| `/iou test stop` | Stop listening and sending test messages. |

This window tests communication only. Shared agreements and payments are available separately under `/iou shared`; follow the [Shared guide](shared-agreements.md) after confirming the connection.
