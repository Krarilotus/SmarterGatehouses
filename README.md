# Smarter Gatehouses

## UCP package

Make gatehouses close based on enemy distance from their center and help troops plan around enemy gates. Optional settings control access to gatehouse roofs and ranged damage to troops standing on large gatehouses.

- Package version: **1.0.8**
- Module directory: `module/`
- Targets: Stronghold Crusader 1.41 and Stronghold Crusader Extreme 1.41
- Requires UCP framework 3.0.7 and frontend 1.0.2 or a compatible later version
- Requires Map Extensions 1.x for map and save load callbacks
- Requires Route Search 1.x (`route-search`, in the UCP3 Fixes repository) for the gate route
  rules: they are its policy at order 200, so Smarter Pathing's assassin shortcut (order 100)
  can be on at the same time


A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme, shown in the UCP GUI as
"Gatehouse Fixes" (UCP package integration and translations: Krarilotus, see `module/CREDITS.md`).
Gatehouses close only for
enemies who can actually reach them, measure that distance from their middle, count as shut to
enemy troops looking for a way in, and - as an option, for the player and the AI separately -
stop working as staircases onto the walls.

What the module does, in plain English, is in `module/locale/description-en.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `bench/` | the emulator bench: the module's own Lua runs against the real exe image, its assembly is assembled with UCP's own fasm.dll and then executed |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. Run the bench until it is green: `bench/test_gates.py` (gate closing, enemy gates, the
   passage/roof cut) and `bench/test_stairs.py` (cursor, move orders, two-leg routes, the
   route check and the passage-or-roof decision), both on both executables. Section 11 of
   `test_stairs.py` runs the rules inside Smarter Pathing's assassin shortcut.
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/smarter-gatehouses-<version>`, leaving the build before it installed and
   clearing anything older.
4. In the UCP GUI press F5, then apply. `ucp-config.yml` is never edited by hand: the apply
   button moves the pin.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

The bench needs Python with `lupa`, `capstone`, `pefile` and `keystone-engine`, and a 32-bit
PowerShell for fasm.dll; it reads the executables from the game folder named in `shc.py`.
Environment overrides: `SHC_GAME_DIR` (the folder with both executables), `FASM_EXE` (use
fasm.exe instead of fasm.dll, with `FASM_EXE_KB` kilobytes, default 57), `BENCH_FASM_CACHE`,
`ROUTE_SEARCH_MODULE` (the route-search module folder, needed for the route rules) and
`SMARTER_PATHING_MODULE` (Smarter Pathing's `module/` folder, for section 11).
