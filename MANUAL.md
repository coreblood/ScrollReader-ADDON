# ScrollReader — Manual

**Version:** 1.3.0 · **Client:** WotLK 3.3.5a · **Server:** Uncapped

## What it does

Bulk-reads (consumes) scrolls from your bags — **every copy of a type in one press** — via the Uncapped server's mass-consume verb (`SCRALL`), the same mechanism behind the Dashboard's "Use in bulk" buttons. Six scroll types are covered:

1. **Wildcard Transmog Scroll**
2. **Sealed Traveler's Map**
3. **Scroll of Mastery**
4. **Scroll of the Delver**
5. **Scroll of Reach**
6. **Scroll of Bounty**

Client addons cannot loop item uses (each use of a spell-casting item requires its own hardware event), so the addon names the item and the server eats the whole stack in one call per type.

## The bar (new in 1.2.0)

A draggable horizontal bar of **six buttons**, one per scroll type, each showing the item's icon and a live **count badge** of how many you hold. Press a button — or its keybind — to bulk-read that type instantly (no confirmation). Empty types render greyed. Drag anywhere on the bar (or its buttons) to move it; position is remembered.

### Keybinds

Each of the six buttons can be bound to a key: **ESC → Key Bindings → scroll to the "ScrollReader" section** ("Read all: Scroll of Mastery" etc.). A button's tooltip shows its current binding. Keybinds act exactly like clicks — immediately.

## Flow (every trigger)

1. Press a bar button / its keybind (one type), or the minimap button / `/sr` (all six types at once).
2. One `SCRALL:<entry>` request per type goes out **immediately — no confirmation dialog** (removed in 1.2.3 by owner choice; the scrolls are destroyed with no undo, so treat keybinds with respect).
3. The server's `SCRDONE` reply reports spent/remaining; a chat line summarizes it. When the **Uncapped Dashboard** is loaded, its `[Scrolls]` line appears instead (ScrollReader stays quiet to avoid duplicates).

Item entries are resolved live from your bag links by exact title — you can only bulk what you hold, so bags are always a sufficient source of the ID.

## Dungeon-exit auto-read (new in 1.3.0)

About **5 seconds after you leave a 5-man dungeon** (party instance), ScrollReader checks your bags for **Scroll of Mastery** and **Scroll of the Delver**. Any of those two you hold **300 or more** of gets bulk-read automatically — no press needed. Other types are never auto-read.

- It **spam-pushes**: `SCRALL` is re-sent every 1.2s until your bags are empty of that type, even if the server answers "none used", up to 40 sends per type. One summary line at the end.
- `SCRALL` consumes the **whole stack**, not just 300 — 300 is only the trigger.
- Combat holds it; it resumes when combat ends.
- On by default. `/sr dungeon` toggles it.

## Minimap button

Reads **all six types at once**, immediately (no confirmation). Free-form left-drag placement (exact position, no ring snapping; safe with scaled minimaps), with a badge showing the grand total held. *(The separate on-screen master button was removed in 1.2.2 — the bar and the minimap button cover both workflows.)*

## Slash commands

| Command | Effect |
|---|---|
| `/sr` or `/scrollread` | Read ALL six types at once |
| `/sr count` | Held counts per type, with item entry IDs |
| `/sr bar` | Show/hide the six-button bar |
| `/sr minimap` | Show/hide the minimap button |
| `/sr dungeon` | Toggle dungeon-exit auto-read (Mastery/Delver at 300+) |
| `/sr reset` | Reset all positions to defaults and show everything |

## Behavior notes

- **Combat:** everything greys out and presses (clicks and keybinds) do nothing while in combat.
- **Server whitelist:** all six types are bulk-whitelisted server-side as of 2026-09-14 (Wildcard Transmog Scroll = entry 500201, Sealed Traveler's Map = 500200). The server still accepts or rejects each entry independently; a rejection answers "none could be used" plus a server explanation line.
- **Maps ([#1350] server rules):** consumed at most **500 per server call**, they require **every eligible flight path known** first, each keeps its normal socket-scroll chance, and they are consumed even when they award nothing. When you hold more than 500, ScrollReader **auto-repeats the call** until your bags are empty of them, then prints one summary line — e.g. "read 1398 Sealed Traveler's Map over 3 calls." The repeat loop watches your bags, not the server's remaining count, so copies in your bank can't spin it.
- **Combat pauses the queue:** requests waiting to be sent (including auto-repeat calls) hold while you're in combat and resume when it ends.
- **Counts are descriptions, not instructions:** the server consumes what is actually in your bags at execution time; `SCRDONE` reports what really happened.
- **Matching is exact and case-sensitive** — variant titles are ignored by design.
- A 6-second **reply watchdog** covers the edge case of a server build with no `SCRALL` handler at all (this realm answers rejections properly, so you should never see it).

## Saved variables

`ScrollReaderDB` stores positions and visibility (minimap button, bar) and the dungeon auto-read toggle. Delete it (or `/sr reset`) to restore defaults.
