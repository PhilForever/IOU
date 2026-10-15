# Connection test

This is an optional test for the next stage of IOU. It does not create agreements or change your ledger.

An ordinary chat whisper only checks chat. IOU checks its own addon messages and measures the text for you; you do not need to count bytes or type special characters.

## Two-player test

You need two online characters, each running the same IOU test build.

1. Both players open **IOU > Settings > Connection test**, or type `/iou test`.
2. Each enters the other character's full **first name and surname**, as used for whispers. For example: `Amber Stone`. **Use target** can fill this in when you have the other player targeted.
3. Both click **Listen**.
4. One player clicks **Run test** and waits for the result.
5. Both click **Copy report**, then press **Ctrl+C** in the report box. Paste the reports into the development chat.
6. Click **Stop** when finished. Listening also turns off on `/reload` or logout.

Keep the Connection test window open on both clients during the test. Closing it or pressing **Escape** stops listening and sending, just like **Stop**.

The addon sends a short set of predefined test messages. It checks simple text, Unicode text, and messages of 239 and 240 bytes. It records what the client reports and whether the other IOU client sends a matching reply. A send result alone does not prove delivery.

Reports include character names and client details. Share them privately; remove names before posting one in a public issue.

## If it does not connect

Check that both players are online, entered the other's full name, clicked **Listen**, and have the same test build. Then run it once more. If it still fails, copy both reports; the failure is useful evidence too.

The report also includes an automatic local preflight. That checks the local setup only. Testing against your own character is blocked so it cannot be mistaken for a successful two-player test.

## Commands

| Command | Action |
| --- | --- |
| `/iou test` | Open Connection test. |
| `/iou test Amber Stone` | Open it with that full name filled in; sends nothing. |
| `/iou test stop` | Stop listening and sending test messages. |

This build tests communication only. Shared proposals, acceptance, and shared repayments come later, after this test supplies live client evidence.
