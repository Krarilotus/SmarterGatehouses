# Smarter Gatehouses

Four small changes to how gatehouses behave. Each one has its own switch.

**Enemy gatehouses count as closed.** Troops looking for a way into a castle no longer head
for an open enemy gate that will shut the moment they get close. They take a breach or an
open side instead. This applies to the player and the AI alike. Your own gates, your allies'
gates and gatehouses you have captured work as before.

**The closing distance is measured from the middle.** The game measures from one corner of
the gatehouse, so it notices enemies sooner on two sides than on the other two. Now the
distance is the same all round.

**A gatehouse only closes for enemies who can reach it.** An enemy counts when he stands on
ground that connects to one side of the gate, or on the walls joined to it. Enemies shut out
behind a wall, a moat or a cliff are ignored. An inner gatehouse in a sealed castle stays open
for your workers until the outer wall is actually breached.

**Gatehouses are not stairs (experimental, off by default).** Walking in through a gate no
longer lets troops step out onto the walls; they need real stairs to go up or down. Troops
below walk through gatehouses and troops on top walk across them. Sent onto a gatehouse,
they go through it, up the stairs and onto it. Point at a spot that can only be reached by
using a gatehouse as stairs and you get the "can't go there" cursor, and the troops stay where
they are. A second click while they are inside the gate does not get them up either.
The same rule can be switched on for the AI separately; an AI castle without stairs then
cannot man its walls.

## Settings

| Setting | Default |
|---|---|
| Treat enemy gatehouses as closed | on |
| Measure from the middle of the gatehouse | on |
| Only close for enemies who can walk to the gate | on |
| Your troops need stairs to get onto the walls | off |
| The AI's troops need stairs too | off |

Works on Stronghold Crusader and Stronghold Crusader Extreme.
