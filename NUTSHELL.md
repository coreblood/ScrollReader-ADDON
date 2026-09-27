# ScrollReader in a nutshell

by Mhortai

**One press eats a whole stack.** ScrollReader bulk-consumes six scroll types — Wildcard Transmog Scroll, Sealed Traveler’s Map, and the Scrolls of Mastery, the Delver, Reach and Bounty — server-side, every bag copy in one go.

## How to use it

- **The bar:** six buttons, one per scroll, with live counts. Click one → the stack is gone. Drag the bar anywhere; `/sr bar` hides it.
- **Keybinds:** ESC → Key Bindings → ScrollReader. Bind any of the six; a keypress works exactly like a click.
- **Read everything:** the minimap button or `/sr` — all six types at once.
- **Dungeon exit (new in 1.3.0):** leave a 5-man and, ~5s later, Mastery and Delver are read automatically if you hold 300+. `/sr dungeon` toggles it.

## Worth knowing

- **No confirmation** — a press spends the whole stack instantly, and it cannot be undone.
- The dungeon auto-read spends the **whole** stack once 300 is reached, and keeps re-sending until your bags are clean.
- Maps go 500 per server call and need all your flight paths first; ScrollReader auto-repeats until the bags are clean.
- Nothing works in combat; queued reads resume after.
- `/sr count` shows what you’re holding.
