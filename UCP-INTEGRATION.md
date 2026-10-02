# UCP packaging and ownership review

The 1.0.3 contribution prepares this existing module for UCP packaging. It fixes
the metadata schema version, declares UCP 3.0.7/frontend dependencies and SHC/Extreme
1.41 targets, supplies all nine current UI languages, and includes an explicit
runtime file list. Module descriptions are brief player overviews. No native
Lua or assembly payload changes are made in this contribution.

Gatehouse Fixes is the concise display name. `smarter-gatehouses` remains the
package/configuration ID. UCP3 Fixes can depend on it without copying hooks,
duplicating controls or overwriting user choices.

Closing and route corrections remain ON. Requiring stairs remains OFF for both
human and AI players. Existing option URLs are preserved, so explicit OFF choices
can be retained. Closing/route controls use Bugfixes; optional stairs use Balance
Changes. Category labels intentionally match the existing UCP2-Legacy resolved
strings: the frontend currently groups by those strings, not by translation IDs.
Independent translations of the categories would create duplicate sections.

## Ownership

Smarter Gatehouses owns gate closing and gate passage/roof route corrections.
UCP3 Fixes' Gatehouse Capture Fix owns the living-occupant capture census. These
are different hook sites and different responsibilities; neither should copy the
other's code. UCP2-Legacy retains its existing Responsive Gates range/timer option.
This module reads the native range operand instead of copying that setting.

Improved Tunnelers remains a separate module. It owns tunneler target, digging,
collapse and raid behavior. AI Swapper owns starting-troop configuration and native
initialization. Fixed Engineers owns siege crew/equipment lifecycle. AIC Tactics
owns AI recruitment and siege policy. No dependency on those modules is needed to
provide ordinary gatehouse behavior.

Keep this package independently selectable. The Fixes 0.1.1 integration candidate
depends on 1.0.3; release still needs composition and gameplay acceptance. Do not copy
its hooks into that bundle or mark compatible fixes as alternative configurations.
No `family` field is added by this contribution.

## Existing APIs inspected

| Responsibility | Existing owner and reuse decision |
| --- | --- |
| Metadata/dependencies | UCP frontend `parse-definition.ts` schema 1.0.0; declare framework/frontend ranges rather than relying on defaults |
| Native bindings and code | UCP framework v3.0.7 `core.lua`: cached `AOBScan`, `allocateAssembly`, code writers, `itob`, `getRelativeAddress`, `insertCode`; existing payload installation remains unchanged in this packaging PR |
| Locale discovery | Frontend `discovery/io.ts:readLocales` requires the `locale/` ZIP entry; all registered catalogs are package inputs |
| Package inputs | Framework v3.0.7 `scripts/build-module-package-files.ps1` accepts `files.yml`; only module files/locales belong in the runtime ZIP |
| Gate range/time | Legacy `port/o_responsivegates.lua` changes the original range/timer operands; the module's `RANGE_ADDRESS` reads the range in place |
| Gate control | UCP3 Fixes `gatehouse-capture-fix/capture.lua` patches troop eligibility; this module patches detection, route search and optional cursor/command/passage behavior |
| Presentation families | GUI discovery `metadata.ts:groupFamilies` is presentation grouping, not a reason to transfer native ownership or invent dependencies |

## Native review findings still open

The source at upstream `71cd94c` resolves roots from matched instructions. No
fixed executable-address table was found in its two production Lua files. That
is useful evidence, not a complete runtime/variant acceptance result.

- `scanOptional` accepts the first match, while UCP also exposes `scanForAOB`.
  Verify uniqueness and surrounding context at runtime; do not interpret every
  missing signature as another module's patch.
- Optional stairs currently install route behavior before discovering all cursor,
  passage and command sites. Missing sites can leave the option partly active.
  Preflight a complete enabled feature before writing its first hook.
- The custom branch encoder duplicates `core.itob`/`core.getRelativeAddress`.
  Use the existing helpers in a focused native change with payload checks.
- `disable` restores remembered bytes without checking whether a later module
  replaced the site. Resolve unload ownership before claiming live composition.
- Route searches temporarily alter gate/link state, using one shared scratch area
  with limits of 64 gates and 4,096 saved links. Verify restoration, overflow,
  reentrancy and worst-case route cost. Extra stair-route attempts are opt-in, but
  ordinary enemy-gate searches still traverse the building array.
- The emulator bench prints failures without making them a failing process exit.
  It also depends on author-machine paths. A green-looking command exit is not
  sufficient evidence; make the bench reproducible before using it as a gate.

This review does not prove all native callees/ABI, save/replay behavior, gameplay
composition, or performance. It does not claim that new persistent state is needed:
the gate/link modifications are intended to be temporary within a native search.
The author must choose a license before store distribution terms are settled.

## Focused checks

Build with the framework/store's existing `files.yml` packaging path. Run the
artifact checks with PyYAML installed and paths to the ZIP and the actual UI registry:

```powershell
$env:UCP_TEST_ZIP = 'C:\path\smarter-gatehouses-1.0.3.zip'
$env:UCP_GUI_LANGUAGES = 'C:\path\UCP3-GUI\resources\lang\languages.yaml'
python -m unittest discover -s tests -p test_package.py -v
```

These checks validate packaged inputs, locale discovery, metadata and controls.
They do not run the game. Python, research, tests and this document are outside
the module ZIP. Human translation review and installed GUI/RTL checks remain open.

For this contribution, three artifact tests pass against the ZIP built with the
existing UCP3 Fixes packaging tool and the live nine-language registry. Both
production Lua files compile under Lua 5.4 and are unchanged from upstream.
An additional task-local real-image Lua admission check on the local SHC/Extreme
1.41 pair finds unique matches for the seven default-path signatures and all
13 signatures with stairs enabled. Its two/five hook spans do not overlap the
capture-fix span. Allocation/assembly are mocked in that check; it does not execute
the native payload, prove either load order or replace game acceptance.

## Short single-player checks before store release

- [ ] Own, allied and captured gates remain usable; troops avoid open enemy gates.
- [ ] Both gate sizes and orientations close consistently from all sides.
- [ ] Enemies separated by walls, moat or cliffs do not close an inner gate incorrectly.
- [ ] With both stairs switches OFF, ordinary wall access is unchanged.
- [ ] With stairs ON, troops use real stairs, including routes through and over one gate.
- [ ] Repeat with Gatehouse Capture Fix and Legacy Responsive Gates enabled.
- [ ] Save/reload and replay with matching packages/settings retain the same results.
- [ ] Large castles do not leave altered gate links or introduce noticeable pauses.
- [ ] Check the settings/defaults in the installed GUI, including long and RTL text.

Run these in normal Crusader and Extreme for declared supported variants.
Multiplayer testing remains with players. No game, replay or UI acceptance is
claimed by the packaging contribution.
