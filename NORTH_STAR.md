# Savant — North Star

> The *why, feel, and spirit*. This sits **above** [`SPEC.md`](./SPEC.md) (the build spec).
> Where the two disagree on intent, this wins; where they disagree on naming, this is
> newer (see [Naming](#the-gradient) — SPEC.md still uses the old terms and needs reconciling).

*Locked 2026-06-06 with Yousr.*

---

## The essence

**Savant is where thoughts land without friction and organize themselves** — a living set
of spaces you swipe through, capture into instantly, and let tidy itself.

## The bet

Every notes app forces a bad trade: either *you* organize (folders, tags, titles —
friction at the worst moment, when you just want the thought out of your head), or it's a
flat dump that rots. Savant **splits capture from organization in time**:

- **Capture is instant and thoughtless** — drop it, it's saved, you move on. No page
  opens, no title, no decision.
- **Organization happens later, mostly *for* you** — Tidy sorts the stream; you make only
  the few judgment calls that genuinely need a human.

You trust it to hold things, so your head stays empty.

## The feel

**Calm, not cluttered. Alive, not sterile.** Each space is its own little world (color /
mesh identity), so switching context *feels* like walking into a different room, not
filtering a list. Vivid and luminous, but quiet underneath.

## The objective

- **macOS = the workshop.** Deep editing, split-view, multi-select, managing. Where you
  *work on* notes.
- **iOS = the companion.** Three jobs: **capture** (a thought hits you anywhere),
  **glance** (swipe through your worlds), **triage** (a spare minute → tidy & promote).
  Where you *live with* notes.
- **iOS must also stand alone** — someone who never opens the Mac should feel Savant is
  complete. Capture, tidy, and the full hierarchy are all first-class on iOS; it is never
  a "viewer."
- **Sync is invisible infrastructure** (CloudKit). The bar: you never *think* about it.
  Same worlds, both devices.

## The three pillars

1. **Swipeable spaces — contexts, not folders.** A space is a world with its own
   color/mood and its own AI understanding (its profile). Swiping is physical and cheap;
   it's the spatial memory the app runs on.

2. **The input bar — the heart of the app.** Always there, bottom of the screen. Type
   (or dictate, or attach), hit send, and **the note is created but does not open** — it
   drops into the current space and you keep going. This is the frictionless-capture
   thesis made physical. (A separate "new full note" affordance exists for when you *do*
   want to compose.) It should feel as effortless and reliable as iMessage's compose field.

3. **Tidy — the app's quiet intelligence.** On-device (Foundation Models), overnight + on
   demand. Reads the stream and archives the stale, groups the related into folders, and
   *suggests* promotions/moves — then shows a review so you stay in control. Tidy is what
   *lets* capture be careless.

## The gradient

The hierarchy is **two axes, not one ladder:**

- **Contextual importance** — "how much does this matter *in this space*?" → **Stream → Kept**.
  Lives and dies inside one world.
- **Universal importance** — "this matters *everywhere*, regardless of which world I'm in."
  → **Anchors**. Promoting to Anchor is a categorically different act: it *transcends* the
  space and joins your universal anchors. That is *why* Anchors are global (shown atop
  every space) — it's the whole point of the top tier, not a quirk.

| Tier | Means | Scope | Lifecycle | Verb |
|---|---|---|---|---|
| **Stream** | "I just thought of this." The live flow of capture. | per-space | Ephemeral — tidied away or promoted. **The input bar always feeds here.** | (default) |
| **Kept** | "Keep this in front of me, *here*." | per-space | Survives tidy. You chose it. | **Keep** |
| **Anchors** | "This matters, *always*." Your universal anchors. | **global — atop every space** | Permanent, omnipresent. Visually distinct ("above your worlds"). | **Anchor** |

A note's life: **Stream → (you or Tidy) → Kept → Anchor.** Tidy is the current that pushes
things up the contextual axis or sweeps them out.

### Naming migration (TODO, deliberate)
Code + SPEC.md still use the old names. When we implement:
`random → Stream` · `pinned → Kept` · `favorite → Anchors` (global, unchanged behavior).
The `NoteTier` enum cases can stay (`favorite/pinned/random`) internally; rename the
*displayed* labels, section headers, and promote-action verbs (Keep / Anchor).

## Principles (the test for every decision)

- **Does it reduce friction at capture?** If a feature adds a decision before "send," it's
  probably wrong.
- **Does the app do the work, or make the user do it?** Default to the former.
- **Does it keep spaces feeling like distinct worlds?** Protect that.
- **Is it calm?** Vivid is fine; busy is not.
- **Companion *and* standalone** — never ship an iOS feature that assumes the Mac exists.
