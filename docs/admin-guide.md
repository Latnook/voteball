# Admin guide: reassigning votes for party splits and mergers

This covers the "Reassign votes…" action in the admin UI (`https://voteball.latnook.com/admin`,
Previous Parties / Upcoming Parties tabs) — what it does, and how to use it when a real-world
political party splits into two, or two parties merge into one.

## The short version

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

## Where it lives

On the **Previous Parties** or **Upcoming Parties** tab, each party row has three buttons:
`Rename`, `Reassign votes…`, and `Delete`. Click `Reassign votes…` to open an inline form with a
dropdown of every *other* party in that same list (previous parties can only reassign to other
previous parties, and likewise for upcoming) and a `Reassign` button.

## What actually happens when you reassign

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

## Merging two parties into one

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

## Handling a split

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

## Limitations (by design, not bugs)

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

## Related actions on the same tabs

- `Rename` — change a party's display name without touching any votes. Use this for a pure
  rebranding (same party, new name) rather than reassign, which is specifically for moving votes
  *between different party IDs*.
- `Delete` — removes a party outright. Blocked with a `409` error if any votes still reference it —
  reassign those votes elsewhere first, then delete.
