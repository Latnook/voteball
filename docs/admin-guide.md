# Admin guide

The admin UI lives at `https://voteball.latnook.com/admin` (it's deliberately unlinked from the
public pages) and has four tabs: **Teams**, **Previous Parties**, **Upcoming Parties**, **Votes**.

This guide covers the two parts that can damage data if you get them wrong:

- **[Reassigning party votes](#reassigning-votes-for-party-splits-and-mergers)** — for when a
  real-world party splits in two, or two parties merge.
- **[Managing leagues and clubs](#managing-leagues-and-clubs-the-teams-tab)** — adding, editing,
  reassigning and deleting on the Teams tab, including the three rules that will block you.

## Reassigning votes for party splits and mergers

This covers the "Reassign votes…" action on the Previous Parties / Upcoming Parties tabs — what it
does, and how to use it when a real-world political party splits into two, or two parties merge into
one.

### The short version

There's one operation, not two: **move every vote pointing at party A onto party B instead.**

- A **merge** (two parties become one) is this operation applied once per losing party, into
  whichever party survives.
- A **split** (one party becomes two) is this same operation applied once, redirecting the old
  party's history toward whichever of the two new parties you judge actually carried the original
  voters' intent.

Nothing here is automatic or inferred from the data — every reassignment is a deliberate action you
take, because there's no way to know from an anonymous vote which faction a voter would have
followed. You're making a judgment call each time, and that's the point: the tool executes your
decision cleanly, it doesn't make the decision for you.

### Where it lives

On the **Previous Parties** or **Upcoming Parties** tab, each party row has three buttons:
`Rename`, `Reassign votes…`, and `Delete`. Click `Reassign votes…` to open an inline form with a
dropdown of every *other* party in that same list (previous parties can only reassign to other
previous parties, and likewise for upcoming) and a `Reassign` button.

### What actually happens when you reassign

1. You pick a target party from the dropdown and click `Reassign`.
2. The UI asks the backend "how many votes currently point at the source party?" and shows you a
   confirm dialog: *"Reassign N votes from "X" to "Y"? This cannot be undone."*
3. If you confirm, every vote that referenced the source party now references the target party
   instead. The source party itself is **not** deleted — it's just left with zero votes pointing at
   it (you can rename or delete it afterward if you want, see below).
4. The results dashboard (`results.html`) picks up the change the next time the worker recomputes
   its rollup tables — same as any other vote change, no special waiting required beyond that normal
   cycle.

This cannot be undone via the UI. There's no "unreassign" button — if you get it wrong, the only fix
is another reassign in the opposite direction (which will move the votes back, but won't distinguish
which votes were "originally" pointed at which party if there's since been a third movement).

### Merging two parties into one

Example: Party B is folding into Party A (A survives, B disappears).

1. Open the Previous Parties or Upcoming Parties tab, whichever list B is in.
2. Click `Reassign votes…` on **B's** row.
3. Select **A** as the target.
4. Confirm — B's votes move to A.
5. B's row now shows zero referencing votes. Click `Delete` on B's row to remove it entirely, or
   leave it if you'd rather keep a record that it once existed. (Delete is blocked with an error if
   any votes still reference the party — that's your signal that a reassign is needed first.)

If three or more parties are merging into one, repeat steps 2-4 once per losing party, all targeting
the same survivor.

If you also want to rename the survivor to reflect the merged identity (e.g. "Party A" →
"Party A–B Alliance"), use `Rename` on A's row — that's independent of the reassign action.

### Handling a split

This is the harder case, because a split doesn't have an obviously "correct" target — you have to
decide who the voters were really voting for.

**Worked example:** Suppose a joint list, "Religious Zionism," ran in the previous election as one
party — but most of its support came from voters backing one particular leader within that list.
Before the next election, that leader splits off to run independently as "Otzma Yehudit," while
"Religious Zionism" continues as a separate, smaller party. If you judge that most of the original
"Religious Zionism" voters were really voting for that leader (not the list as a whole), then their
historical intent now belongs with "Otzma Yehudit," not with the shrunken "Religious Zionism" that's
left behind.

Steps:

1. Click `Reassign votes…` on the **original party's** row ("Religious Zionism").
2. Select the successor you judge represents the original voters' intent as the target
   ("Otzma Yehudit") — create it first via `Add` on the party list if it doesn't exist yet.
3. Confirm — the original party's historical votes move to that successor.
4. The original party's row now has zero votes. If it's continuing to run as a real, separate
   party going forward (as in the example — "Religious Zionism" still exists, just smaller), leave
   it in the list as-is; new votes cast after this point will naturally accrue to whichever of the
   two parties voters actually pick going forward. If the original identity is fully retired, delete
   its row instead.

If you judge the split roughly even — no single successor clearly represents most of the original
voters — there's no partial/proportional option. You have to pick one target, or leave the history
attached to the original party and accept that it's now an imperfect record. See Limitations below.

### Limitations (by design, not bugs)

- **No proportional splitting.** A reassign always moves *all* of a party's votes to *one* target.
  If you genuinely believe a party's support should split, say, 60/40 between two successors, this
  tool can't do that — it's all-or-nothing per action.
- **No automatic detection.** Nothing in the system suggests when a split or merge has happened, or
  which target makes sense. That's entirely your call, informed by whatever you know about the
  actual political event.
- **No undo / no audit trail.** Once votes move, there's no record kept that they used to point at a
  different party. A reassigned vote looks identical to a vote that was always cast for the target
  party.
- **No server-side confirmation beyond the one dialog.** The confirm dialog shows the vote count so
  you can sanity-check before committing, but there's no second review step — double-check the
  source/target pair before clicking through.

### Related actions on the same tabs

- `Rename` — change a party's display name without touching any votes. Use this for a pure
  rebranding (same party, new name) rather than reassign, which is specifically for moving votes
  *between different party IDs*.
- `Delete` — removes a party outright. Blocked with a `409` error if any votes still reference it —
  reassign those votes elsewhere first, then delete.

---

## Managing leagues and clubs (the Teams tab)

Everything about football teams lives on one tab: **Teams**. Leagues are listed top-level, with
their clubs nested underneath. Reassign works the same way it does for parties — but clubs and
leagues have **three extra rules that will block you**, and they're much easier to understand before
you hit them than after.

### First, the one concept that explains everything else

**A club can belong to two leagues, but only two.** It has a *primary* league and one optional
*secondary* league. That's how Real Madrid appears under both the Champions League and La Liga.

"Primary" does **not** mean "more important" — it only decides which row you edit the club from. In
the seeded data it's the other way round from what you might guess: Real Madrid's primary league is
the *Champions League* and La Liga is its secondary, and the same goes for every seeded UCL club.

The knock-on effects show up everywhere on this tab:

- A club appears twice in the list — once under each of its leagues.
- **The second appearance is read-only.** Edit a club from the row under its *primary* league; the
  copy under its secondary league is just a listing.
- There is only **one** secondary slot, which is why the Champions League button greys out for a
  club that already has a secondary league.
- A vote records *which league tab a club was picked under*. That's what makes club reassignment
  fussier than party reassignment — see below.

### Adding a league or a club

- **`+ Add league`** — English name, Hebrew name, an **optional Russian name**, and an optional logo
  URL. A duplicate name is rejected with an error rather than silently creating a second league.
- **`+ Add club`** (the button under each league) — English name, Hebrew name, an **optional Russian
  name**, an optional secondary league from the dropdown (`— none —` by default), and an optional
  logo URL. **The league you added it under becomes its primary league**, so add the club under the
  league you consider its home.

> **Fill the Russian name in if you can.** English and Hebrew are required; Russian is not, because
> requiring it would have blocked saving any entity that has no Russian name yet. The cost of that
> choice is that Russian coverage rots silently — a club added without one simply falls back to its
> English name for Russian-speaking visitors, with nothing flagging it. If you are adding a club and
> know its Russian name, this is the cheapest moment to record it.
>
> It must be **actual Cyrillic**. `РААМ` typed on a Latin keyboard layout is `PAAM` — visually
> identical, a different string, and it breaks Russian search and sorting.

For logos, prefer a file committed to `services/frontend/logos/` pointed at as `/logos/<name>.png`.
**Do not paste a Facebook/Instagram CDN link** — those URLs expire, and tracker blockers drop
`*.fbcdn.net` in the browser, so the crest vanishes for many visitors while it still loads fine for
you. That failure is invisible from the server side. This already happened once, on F.C. Kiryat Yam.

### The Champions League shortcut

Each club row has a one-click **`Add to UEFA Champions League`** / **`Remove from UEFA Champions
League`** button. It just fills or clears the secondary-league slot for you.

It greys out in two situations, both with an explanation on hover:

- *"Already has a domestic league on file — edit via Rename instead."* The club's one secondary slot
  is already taken. Use `Rename` if you want to swap what's in it.
- *"No domestic league on file — give it one via Rename first."* The club's **primary** league is the
  Champions League and it has no secondary, so removing it would leave the club in no league at all.
  Give it a domestic league via `Rename` first; the button then removes the UCL side.

### Renaming (which is really "edit")

`Rename` on a club is really the full edit form: **names, primary league, secondary league and logo**,
all at once. That's how you move a club from one league to another — there's no separate "move"
action. Changing the primary league rebuilds the secondary dropdown to exclude it, because a club
can't list the same league twice (the backend rejects it too).

`Rename` on a league edits its names and logo. Neither action touches any votes.

### Reassigning club votes

Same operation as parties: move every vote pointing at club A onto club B. One extra rule:

> **The target club must cover every league the source club is votable under.**

If the source is votable in both the Premier League and the Champions League, the target must be in
both too, or you get `target club does not cover every league the source club is votable under`.

The reason is the "votes record which league tab" point above: a vote for the source club is stamped
with the league it was picked under. Moving it to a club that isn't in that league would produce a
vote for a club in a league it doesn't play in — a nonsense row the results tabs would then have to
render. The check refuses instead of creating it.

**The fix is always the same:** give the target club the missing league first (via `Rename`, or the
Champions League button if that's the missing one), *then* reassign.

Duplicates are handled for you. If some voter picked **both** the source and the target club under
the same league, the reassign would collide — so the redundant pick is dropped rather than erroring
out. One consequence worth knowing: the "N votes" in the confirm dialog counts the votes *touched*,
which can be more than the number of picks the target actually gains.

### Reassigning league votes

Moving a league's votes moves two different things at once:

1. "Just this league, no specific club" picks — voters who named a league without naming a team.
2. The league stamp on specific-club picks that were made under that league's tab.

> **The source league must have no clubs left before you can reassign it.** Otherwise you get
> `source league still has clubs; move or delete them first`.

So retiring a league is a sequence, not a single action:

1. For each club in it — reassign the club's votes elsewhere and delete it, or edit it (`Rename`) to
   sit under a different league.
2. Reassign the now-empty league's votes to whichever league should inherit them.
3. Delete the league.

### Deleting

Both deletes are blocked while anything still points at the row — the block is the feature, not an
obstacle:

- **A club** is blocked (`409`) while any vote references it. Reassign its votes first.
- **A league** is blocked twice, in this order: first if any clubs still belong to it, then if any
  votes still reference it. That's why the retirement sequence above has three steps.

### Limitations on the Teams tab (by design, not bugs)

- **No proportional splitting**, exactly as with parties. A club reassign moves *all* of a club's
  votes to *one* target.
- **No undo and no audit trail.** A reassigned pick is indistinguishable from one that was always
  cast for the target club.
- **One secondary league per club.** A club that genuinely plays in three competitions can't be
  represented as such; pick the two that matter for voting.
- **Deleting a club that has votes is intentionally impossible.** If a club should disappear but its
  votes should count for nobody, there's no supported way to do that — the votes have to go
  somewhere, or the club stays.
- **Renaming is not reassigning.** If a club is simply rebranding, `Rename` it and leave the votes
  alone. Reassign exists only for moving votes *between different club IDs*.
