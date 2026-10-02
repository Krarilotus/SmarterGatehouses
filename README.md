# Gatehouse Fixes

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. Gatehouses close only for
enemies who can actually reach them, measure that distance from their middle, count as shut to
enemy troops looking for a way in, and - as an option, for the player and the AI separately -
stop working as staircases onto the walls.

What the module does, in plain English, is in `module/locale/description-en.md`.

The [UCP integration review](UCP-INTEGRATION.md) explains packaging, ownership,
focused checks and the remaining single-player checks before store release.
Gatehouse Capture Fix is a separate correction and Improved Tunnelers remains
its own module. Select compatible fixes together; they are not alternative presets.

The display name is Gatehouse Fixes. The existing package ID `smarter-gatehouses`
and option URLs stay unchanged, preserving dependencies and saved configuration.
UCP3 Fixes can select this module through a dependency; the native implementation
and its switches remain here. The bundle integration is a test candidate until
the remaining native composition and single-player checks pass.

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
   route check and the passage-or-roof decision), both on both executables.
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/smarter-gatehouses-<version>`, leaving the build before it installed and
   clearing anything older.
4. In the UCP GUI press F5, then apply. `ucp-config.yml` is never edited by hand: the apply
   button moves the pin.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

The bench needs Python with `lupa`, `capstone`, `pefile` and `keystone-engine`, and a 32-bit
PowerShell for fasm.dll; it reads the executables from the game folder named in `shc.py`.
