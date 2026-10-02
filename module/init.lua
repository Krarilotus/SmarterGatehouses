--[[
  Smarter Gatehouses

  Four separate changes to gatehouses, each switchable on its own:

  1. Gatehouses of another team count as shut when a unit searches its route, open or not.
  2. The distance at which a gatehouse closes is measured from its middle, not its corner.
  3. A gatehouse only closes for enemies standing on ground that connects to it.
  4. (experimental) Walking in through a gate does not lead onto the walls - for the
     player's troops and, as a separate switch, for the AI's.

  How each of them works is written above the assembly it uses, in templates.lua. What
  follows here is where the module finds the game code it needs and what it does to it.

  Everything is located by pattern scan, so the module runs on both shipped executables
  (Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe): every address that differs
  between them is read out of the instruction that uses it rather than written down here.

  The two halves are independent: if the game code one of them needs cannot be found, it
  logs a warning and stays off while the other carries on.
]]

local templates = require("templates")

local DEFAULTS = {
  pathing = { enemy_gates_closed = true },
  detection = { centred = true, reachable_only = true },
  walls = { stairs_needed = false, stairs_needed_ai = false },
}

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- BuildingsState::updateGateDrawBridgeOpenCloseLogic, at the distance test inside its loop
-- over the owner's enemy units: movsx ecx, word [eax + units + microX] and what follows.
local AOB_DETECT = "0F BF 88 ? ? ? ? 8B 54 24 30 3B D1 7E 04 2B D1 EB 04 2B CA 8B D1 0F BF 80 "
  .. "? ? ? ? 8B 4C 24 34"
local DETECT_HOOK_SIZE = 7
local DETECT_MICROX_OPERAND = 3
local DETECT_RANGE = 0x34                     -- cmp ecx, 0xC8
local DETECT_RANGE_OPERAND = 0x36
local DETECT_FOUND_JUMP = 0x3A                -- jl "an enemy is near"
local DETECT_CONTINUE = 0x3C                  -- ... or on to the next enemy unit
local DETECT_GUARDS = {
  [DETECT_RANGE] = { 0x81, 0xF9 },
  [DETECT_FOUND_JUMP] = { 0x7C },
  [DETECT_CONTINUE] = { 0x8B, 0x4C, 0x24, 0x28 },
}

-- UnitsState::setDestinationForUnit, where it calls PathFindingState::doPathfinding with
-- the unit's owner: the one place a unit's route is searched.
local AOB_PATH_CALL = "0F BF 8E AA 06 00 00 8B 44 24 14 50 51 B9 ? ? ? ? E8 ? ? ? ?"
local PATH_STATE_OPERAND = 14                 -- mov ecx, PathFindingState
local PATH_CALL = 18

-- PathFindingState::doPathfinding. Only read: the row table and the area map.
local AOB_DO_PATHFINDING = "56 8B F1 8B 46 0C 8B 4E 14 8D 04 40 8B 04 85 ? ? ? ? 03 46 08 8D "
  .. "0C 49 8B 0C 8D ? ? ? ? 03 4E 10 0F B7 14 45 ? ? ? ?"
local SEARCH_ROW_TABLE_OPERAND = 15
local SEARCH_AREA_MAP_OPERAND = 39

-- PathFindingState::updatePathLinkageTileMapRelatedToGates(building): lays a gatehouse's
-- two entrance links, or takes them away when its gate state says closed. Called as it
-- is, and read for the building array and the link layer.
local AOB_LINK_GATES = "8B 4C 24 04 69 C9 2C 03 00 00 53 55 56 0F BF B1 ? ? ? ? 57 8B B9 ? ? ? "
  .. "? 8B C7 99 2B C2 D1 F8 66 83 B9 ? ? ? ? 50"
local LINK_BUILDING_X_OPERAND = 16            -- movsx esi, word [ecx + buildings + x]
local LINK_LAYER = 0x8C                       -- and byte [eax + link layer], 0xFB
local LINK_LAYER_OPERAND = 0x8E
local LINK_GUARDS = {
  [LINK_LAYER] = { 0x80, 0xA0 },
}

-- Two reads of the team each player is on, next to each other: the game's own "are these
-- two players enemies" test.
local AOB_PLAYER_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local OFFSET_PLAYER_TEAMS = 3

-- UnitsState::updateUnitFadeAndVisibilityNearStructures, where it decides whether a unit
-- on a gatehouse is up on the roof or down in the passage. Read for three tile layers.
local AOB_TILE_LAYERS = "F7 04 8D ? ? ? ? 00 01 00 00 75 1F 0F BF 14 4D ? ? ? ? 69 D2 2C 03 00 "
  .. "00 0F BF 8A ? ? ? ? 83 3C 8D ? ? ? ? 00"
local LAYERS_TILE_FLAGS_OPERAND = 3
local LAYERS_BUILDING_MAP_OPERAND = 17
local LAYERS_GATE_OR_TOWER_OPERAND = 37

-- PathFindingState::calculateCanPlayerUnitsNavigateToAreaFromArea(player, from, to,
-- canClimb): the game's own "can this player get from area to area" test.
local AOB_CAN_NAVIGATE = "81 EC 6C 09 00 00 8B 84 24 74 09 00 00 56 8B B4 24 7C 09 00 00 3B C6"
local CLIMB_DATA = 0x1084                     -- PathFindingState + this: climbData[200]
local MAX_CLIMBS = 200

-- The move cursor for selected troops, right after the game's own area test for the
-- first selected soldier: mov ebx, [esp+0x2C] / jmp, which is replaced.
local AOB_MOVE_CURSOR = "B9 ? ? ? ? E8 ? ? ? ? 8B 0D ? ? ? ? 50 53 57 51 B9 ? ? ? ? E8 ? ? ? ? "
  .. "33 FF 85 C0 74 08 C7 44 24 2C 01 00 00 00 8B 5C 24 2C EB 02"
local CURSOR_UNITS_STATE_OPERAND = 1          -- mov ecx, UnitsState
local CURSOR_CAN_CLIMB_CALL = 5               -- call canAUnitClimb
local CURSOR_HOOK = 0x2C
local CURSOR_HOOK_SIZE = 6
local CURSOR_RESUME = 0x34

-- The same handler, a little further on, reading the mouse's tile x / y.
local AOB_MOUSE_TILE = "8B 0D ? ? ? ? 8B 15 ? ? ? ? 51 52 55 B9 ? ? ? ? E8"
local MOUSE_Y_OPERAND = 2
local MOUSE_X_OPERAND = 8

-- TribesState::giveTribeMoveInstruction, where the target has passed the game's checks:
-- jne <give up> / mov eax, [esp+0x48] / mov ecx, [esp+0x10].
local AOB_TRIBE_MOVE = "89 44 24 3C 89 54 24 24 0F 85 ? ? ? ? 8B 44 24 48 8B 4C 24 10 C7 05 ? ? "
  .. "? ? 00 00 00 00"
local TRIBE_GIVE_UP_JUMP = 8
local TRIBE_HOOK = 14
local TRIBE_HOOK_SIZE = 8

-- Which AI character each player runs; 0 is a human player.
local AOB_PLAYER_AIC = "69 C0 F4 39 00 00 8B 88 ? ? ? ? 69 C9 A4 02 00 00"
local PLAYER_AIC_OPERAND = 8

-- Fields of a building (0x32C bytes each) and of a unit (0x490 bytes each).
local BUILDING_STRIDE = 0x32C
local BUILDING_TYPE = 0xD2
local BUILDING_X = 0xEE
local BUILDING_Y = 0xF0
local BUILDING_SIZE = 0xF8
local BUILDING_VARIATION = 0x102
local BUILDING_COUNT_BEFORE_ARRAY = 0xC       -- BuildingsState + 8, the array is at + 0x14
local UNIT_MICROX = 0xB6
local UNIT_MICROY = 0xB8
local UNIT_X = 0xC4
local UNIT_Y = 0xC6
local UNIT_IN_PASSAGE = 0x614 + 0x402         -- from UnitsState + index * 0x490
local UNIT_CAN_CLIMB = 0x614 + 0x360
local UNIT_START = 0x614                      -- UnitsState + index * 0x490 + this = the unit
local UNIT_OWNER = 0x614 + 0x96

-- processUnitMove, stepping a unit along its route: the x / y change for each of the eight
-- directions a route is written in.
local AOB_DIRECTIONS = "0F B7 14 ED ? ? ? ? 66 03 D1 66 89 94 37 ? ? ? ? 0F B7 14 ED ? ? ? ? 66 03 D0"
local DIRECTIONS_OPERAND = 4

-- updateUnitFadeAndVisibilityNearStructures, where it decides whether a unit standing on a
-- gatehouse is in its passage or on its roof: test edi, edi / je <done> / mov esi,
-- [eax + units + destination tile] / ... the two stores of the passage byte.
local AOB_PASSAGE_FLAG = "85 FF 74 4F 8B B0 ? ? ? ? 8B 14 B5 ? ? ? ? F7 C2 00 01 00 00 0F BF 0C 75 "
  .. "? ? ? ? 74 0E F6 C2 02 75 09 C6 80 ? ? ? ? 00 EB 24"
local PASSAGE_HOOK = 4
local PASSAGE_HOOK_SIZE = 6
local PASSAGE_DONE_JUMP = 2                   -- je <done>, rel8
local PASSAGE_TILE_OPERAND = 6                -- [eax + units + 0xD8]

-- The module's own memory.
local MAX_GATES = 64
local MAX_LINKS = 4096
local MAX_STAGGER = 8                         -- gatehouses tried for a there-and-over trip
local C = {
  CENTRE_ENABLED = 0, REACH_ENABLED = 4, ENEMY_ENABLED = 8, TOP_ENABLED = 12,
  GATE_COUNT = 16, LINK_COUNT = 20, CUT_X = 24, CUT_Y = 28, CUT_N = 32,
  SPECIAL_R1 = 36, SPECIAL_R2 = 40, SPECIAL_P = 44, AI_ENABLED = 48,
  GATE_LIST = 64,
}
C.LINK_LIST = C.GATE_LIST + MAX_GATES * 8
C.SHADOW = C.LINK_LIST + MAX_LINKS * 8
C.CHAIN = C.SHADOW + MAX_CLIMBS * 4
C.LEGS = C.CHAIN + 1024                      -- two_legs' variables, 4 bytes each
local LEG_NAMES = { "LEG_GATE", "FORCE_BID", "FORCE_MODE", "HIGH_AREA", "E1X", "E1Y", "E2X",
  "E2Y", "EX", "EY", "SX", "SY", "DX_", "DY_", "N1", "RX", "RY", "GIN", "ENTRY_KIND", "RULES_NOW", "VIOLATED", "CAND", "TRIES", "LEG_DONE", "S_HIGH" }
C.SAVE_A = C.LEGS + #LEG_NAMES * 4
C.SAVE_B = C.SAVE_A + 0x190
C.SIZE = C.SAVE_B + 0x190

-- Which link bits cut_sides clears, by the kind of column and the kind of row a tile of the
-- square around a gatehouse is in: 0 outside before, 1 first footprint tile, 2 middle, 3
-- last footprint tile, 4 outside after. Written into the script as its c_masks table.
local LINK_DIRECTIONS = {
  { -1, -1, 0x80 }, { 0, -1, 0x01 }, { 1, -1, 0x02 }, { 1, 0, 0x04 },
  { 1, 1, 0x08 }, { 0, 1, 0x10 }, { -1, 1, 0x20 }, { -1, 0, 0x40 },
}
local FOOTPRINT_PATTERN = { { 0, 0, 1 }, { 0, 1, 1 }, { 1, 1, 1 }, { 1, 1, 0 }, { 1, 0, 0 } }
local function cutMasks()
  local masks = {}
  for column = 1, 5 do
    for row = 1, 5 do
      local inside = FOOTPRINT_PATTERN[column][2] & FOOTPRINT_PATTERN[row][2]
      local mask = 0
      for _, direction in ipairs(LINK_DIRECTIONS) do
        local other = FOOTPRINT_PATTERN[column][2 + direction[1]]
          & FOOTPRINT_PATTERN[row][2 + direction[2]]
        if other ~= inside then
          mask = mask | direction[3]
        end
      end
      masks[#masks + 1] = string.format("0x%02X", mask)
    end
  end
  return "\nc_masks:\ndb " .. table.concat(masks, ",") .. "\n"
end

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local readByte = core.readByte
local readInteger = core.readInteger
local writeInteger = core.writeInteger

local patched = {}

---Scan for a pattern this module can live without. Modules load in the order the config
---lists them and rewrite game code as they go, so a pattern that has been overwritten has
---to switch its feature off, not take the game down at launch.
---@param pattern string
---@param purpose string
---@return number|nil
local function scanOptional(pattern, purpose)
  local found, address = pcall(core.AOBScan, pattern)
  if not found or address == nil then
    log(WARNING, "smarter-gatehouses: could not find " .. purpose
      .. "; the part of the module that needs it is off. Another module has probably "
      .. "patched the same code.")
    return nil
  end
  return address
end

---True when the bytes at base + offset are the ones this module expects.
---@param base number
---@param offsets table<number, table> offset -> expected bytes
---@param purpose string
---@return boolean
local function guardsHold(base, offsets, purpose)
  for offset, expected in pairs(offsets) do
    for index, byte in ipairs(expected) do
      local found = readByte(base + offset + index - 1) & 0xFF
      if found ~= byte then
        log(WARNING, string.format(
          "smarter-gatehouses: %s does not look the way it should at +0x%X (found 0x%02X, "
          .. "expected 0x%02X); that part of the module is off.",
          purpose, offset + index - 1, found, byte))
        return false
      end
    end
  end
  return true
end

---Read a pointer-sized value as the unsigned address it is.
---@param address number
---@return number
local function readAddress(address)
  return readInteger(address) & 0xFFFFFFFF
end

---The target of the five byte call at this address.
---@param address number
---@return number
local function callTarget(address)
  return (address + 5 + readInteger(address + 1)) & 0xFFFFFFFF
end

---Where a six-byte conditional jump goes.
---@param address number
---@return number
local function jumpTarget(address)
  return (address + 6 + readInteger(address + 2)) & 0xFFFFFFFF
end

---Remember the bytes at address so disable can put them back, then overwrite them.
---@param address number
---@param bytes table
local function patch(address, bytes)
  local original = {}
  for index = 1, #bytes do
    original[index] = readByte(address + index - 1) & 0xFF
  end
  patched[#patched + 1] = { address = address, bytes = original }
  core.writeCodeBytes(address, bytes)
end

---A five byte jump or call to destination, padded with NOPs up to size.
---@param opcode number 0xE9 or 0xE8
---@param address number
---@param destination number
---@param size number
---@return table
local function branch(opcode, address, destination, size)
  local relative = (destination - (address + 5)) & 0xFFFFFFFF
  local bytes = { opcode, relative & 0xFF, (relative >> 8) & 0xFF, (relative >> 16) & 0xFF,
    (relative >> 24) & 0xFF }
  for _ = 6, size do
    bytes[#bytes + 1] = 0x90
  end
  return bytes
end

---A setting out of the config, falling back to this module's own default.
---@param config table
---@param group string
---@param name string
---@return boolean
local function setting(config, group, name)
  local section = config and config[group]
  local value = section and section[name]
  if value == nil then
    value = DEFAULTS[group][name]
  end
  return value and true or false
end

return {

  enable = function(self, config)
    config = config or {}

    local enemyClosedOn = setting(config, "pathing", "enemy_gates_closed")
    local centredOn = setting(config, "detection", "centred")
    local reachableOn = setting(config, "detection", "reachable_only")
    local stairsOn = setting(config, "walls", "stairs_needed")
    local stairsAiOn = setting(config, "walls", "stairs_needed_ai")

    ---------------------------------------------------------------------------------
    -- Find the game code
    ---------------------------------------------------------------------------------

    local linkGates = scanOptional(AOB_LINK_GATES, "the gatehouse link function")
    if linkGates ~= nil and not guardsHold(linkGates, LINK_GUARDS,
        "the gatehouse link function") then
      linkGates = nil
    end
    local search = scanOptional(AOB_DO_PATHFINDING, "the route search")
    if linkGates == nil or search == nil then
      log(WARNING, "smarter-gatehouses: nothing was changed.")
      return
    end

    local buildings = (readAddress(linkGates + LINK_BUILDING_X_OPERAND) - BUILDING_X)
      & 0xFFFFFFFF
    local linkage = readAddress(linkGates + LINK_LAYER_OPERAND)
    local rowTable = readAddress(search + SEARCH_ROW_TABLE_OPERAND)
    local areaMap = readAddress(search + SEARCH_AREA_MAP_OPERAND)

    local control = core.allocate(C.SIZE, true)
    writeInteger(control + C.CENTRE_ENABLED, centredOn and 1 or 0)
    writeInteger(control + C.REACH_ENABLED, reachableOn and 1 or 0)
    writeInteger(control + C.ENEMY_ENABLED, enemyClosedOn and 1 or 0)
    writeInteger(control + C.TOP_ENABLED, stairsOn and 1 or 0)
    writeInteger(control + C.AI_ENABLED, stairsAiOn and 1 or 0)

    ---------------------------------------------------------------------------------
    -- When a gatehouse closes
    ---------------------------------------------------------------------------------

    if centredOn or reachableOn then
      local site = scanOptional(AOB_DETECT, "the gatehouse's enemy check")
      if site ~= nil and guardsHold(site, DETECT_GUARDS, "the gatehouse's enemy check") then
        local units = (readAddress(site + DETECT_MICROX_OPERAND) - UNIT_MICROX) & 0xFFFFFFFF
        local found = site + DETECT_FOUND_JUMP + 2
          + (readByte(site + DETECT_FOUND_JUMP + 1) & 0x7F)
        local detect = core.allocateAssembly(templates.detect, {
          BLD_SIZE = buildings + BUILDING_SIZE,
          BLD_TYPE = buildings + BUILDING_TYPE,
          BLD_X = buildings + BUILDING_X,
          BLD_Y = buildings + BUILDING_Y,
          BLD_VARIATION = buildings + BUILDING_VARIATION,
          UNIT_MICROX = units + UNIT_MICROX,
          UNIT_MICROY = units + UNIT_MICROY,
          UNIT_X = units + UNIT_X,
          UNIT_Y = units + UNIT_Y,
          CENTRE_ENABLED = control + C.CENTRE_ENABLED,
          REACH_ENABLED = control + C.REACH_ENABLED,
          -- The range stays where the game keeps it, so a module that changes it there
          -- changes it here too.
          RANGE_ADDRESS = site + DETECT_RANGE_OPERAND,
          ROW_TABLE = rowTable,
          AREA_MAP = areaMap,
          CONTINUE = site + DETECT_CONTINUE,
          FOUND = found,
        })
        patch(site, branch(0xE9, site, detect, DETECT_HOOK_SIZE))
      end
    end

    ---------------------------------------------------------------------------------
    -- Route finding
    ---------------------------------------------------------------------------------

    if enemyClosedOn or stairsOn or stairsAiOn then
      local site = scanOptional(AOB_PATH_CALL, "the call that searches a unit's route")
      local teamSite = scanOptional(AOB_PLAYER_TEAMS, "the team of each player")
      local layers = scanOptional(AOB_TILE_LAYERS, "the tile layers")
      local aicSite = scanOptional(AOB_PLAYER_AIC, "which players are human")
      if site ~= nil and teamSite ~= nil and layers ~= nil and aicSite ~= nil then
        local playerAic = readAddress(aicSite + PLAYER_AIC_OPERAND)
        local pathfinding = readAddress(site + PATH_STATE_OPERAND)
        local call = site + PATH_CALL
        local doPathfinding = (call + 5 + readInteger(call + 1)) & 0xFFFFFFFF

        local cutSides = core.allocateAssembly(templates.cut_sides .. cutMasks(), {
          CUT_X = control + C.CUT_X,
          CUT_Y = control + C.CUT_Y,
          CUT_N = control + C.CUT_N,
          LINK_COUNT = control + C.LINK_COUNT,
          LINK_LIST = control + C.LINK_LIST,
          MAX_LINKS = MAX_LINKS,
          ROW_TABLE = rowTable,
          LINKAGE = linkage,
        })
        local prepare = core.allocateAssembly(templates.prepare, {
          GATE_COUNT = control + C.GATE_COUNT,
          LINK_COUNT = control + C.LINK_COUNT,
          GATE_LIST = control + C.GATE_LIST,
          MAX_GATES = MAX_GATES,
          ENEMY_ENABLED = control + C.ENEMY_ENABLED,
          FIRST_BUILDING = buildings + BUILDING_STRIDE,
          BUILDING_COUNT = buildings - BUILDING_COUNT_BEFORE_ARRAY,
          TEAMS = readAddress(teamSite + OFFSET_PLAYER_TEAMS),
          CUT_SIDES = cutSides,
          PATHFINDING = pathfinding,
          LINK_GATES = linkGates,
          SPECIAL_R1 = control + C.SPECIAL_R1,
          SPECIAL_R2 = control + C.SPECIAL_R2,
          SPECIAL_P = control + C.SPECIAL_P,
          CLIMBS = pathfinding + CLIMB_DATA,
          CHAIN = control + C.CHAIN,
          FORCE_BID = control + C.LEGS + 4,
          FORCE_MODE = control + C.LEGS + 8,
        })
        local restore = core.allocateAssembly(templates.restore, {
          GATE_COUNT = control + C.GATE_COUNT,
          LINK_COUNT = control + C.LINK_COUNT,
          GATE_LIST = control + C.GATE_LIST,
          LINK_LIST = control + C.LINK_LIST,
          BUILDINGS = buildings,
          LINKAGE = linkage,
          PATHFINDING = pathfinding,
          LINK_GATES = linkGates,
        })
        local buildingMap = readAddress(layers + LAYERS_BUILDING_MAP_OPERAND)
        local gateOrTower = readAddress(layers + LAYERS_GATE_OR_TOWER_OPERAND)
        local tileFlags = readAddress(layers + LAYERS_TILE_FLAGS_OPERAND)

        -- "Can the rule get this unit there at all", for the search, the cursor and the
        -- move order. Without the game's area test it cannot be answered, and the stairs
        -- rule is left off rather than half on.
        local ruleOk
        local canNavigate = (stairsOn or stairsAiOn)
          and scanOptional(AOB_CAN_NAVIGATE, "the game's area-to-area test") or nil
        local directions = (stairsOn or stairsAiOn)
          and scanOptional(AOB_DIRECTIONS, "the route step directions") or nil
        if canNavigate ~= nil and directions ~= nil then
          ruleOk = core.allocateAssembly(templates.rule_ok, {
            ROW_TABLE = rowTable,
            AREA_MAP = areaMap,
            BUILDING_MAP = buildingMap,
            BUILDINGS = buildings,
            GATE_OR_TOWER = gateOrTower,
            TILE_FLAGS = tileFlags,
            PATHFINDING = pathfinding,
            CLIMBS = pathfinding + CLIMB_DATA,
            MAX_CLIMBS = MAX_CLIMBS,
            SHADOW = control + C.SHADOW,
            CAN_NAV = canNavigate,
          })
        else
          stairsOn = false
          stairsAiOn = false
          writeInteger(control + C.TOP_ENABLED, 0)
          writeInteger(control + C.AI_ENABLED, 0)
          ruleOk = core.allocateCode({ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC2, 0x10, 0x00 })
        end

        local chainBuild = core.allocateAssembly(templates.chain_build, {
          CHAIN = control + C.CHAIN,
          PATHFINDING = pathfinding,
          CLIMBS = pathfinding + CLIMB_DATA,
          MAX_CLIMBS = MAX_CLIMBS,
          SPECIAL_P = control + C.SPECIAL_P,
          BUILDINGS = buildings,
          ROW_TABLE = rowTable,
          AREA_MAP = areaMap,
          HIGH_AREA = control + C.LEGS + 12,
        })

        local legValues = {
          BUILDINGS = buildings,
          CHAIN = control + C.CHAIN,
          PATHFINDING = pathfinding,
          DIR_TABLE = directions and readAddress(directions + DIRECTIONS_OPERAND) or 0,
          SAVE_A = control + C.SAVE_A,
          SAVE_B = control + C.SAVE_B,
          SHUT_GATES = prepare,
          REOPEN_GATES = restore,
          DO_PATHFINDING = doPathfinding,
          ROW_TABLE = rowTable,
          AREA_MAP = areaMap,
        }
        for index, name in ipairs(LEG_NAMES) do
          legValues[name] = control + C.LEGS + (index - 1) * 4
        end
        local twoLegs = core.allocateAssembly(templates.two_legs, legValues)
        local routeValues = {
          PATHFINDING = pathfinding,
          DIR_TABLE = legValues.DIR_TABLE,
          BUILDINGS = buildings,
          ROW_TABLE = rowTable,
          BUILDING_MAP = buildingMap,
        }
        for _, name in ipairs({ "RX", "RY", "GIN", "ENTRY_KIND" }) do
          routeValues[name] = legValues[name]
        end
        local routeOk = core.allocateAssembly(templates.route_ok, routeValues)

        local pathSearch = core.allocateAssembly(templates.path_search, {
          TOP_ENABLED = control + C.TOP_ENABLED,
          AI_ENABLED = control + C.AI_ENABLED,
          UNIT_OWNER = UNIT_OWNER,
          PLAYER_AIC = playerAic,
          TWO_LEGS = twoLegs,
          ROUTE_OK = routeOk,
          RULES_NOW = legValues.RULES_NOW,
          VIOLATED = legValues.VIOLATED,
          CAND = legValues.CAND,
          TRIES = legValues.TRIES,
          LEG_DONE = legValues.LEG_DONE,
          S_HIGH = legValues.S_HIGH,
          HIGH_AREA = legValues.HIGH_AREA,
          MAX_STAGGER = MAX_STAGGER,
          BUILDING_COUNT = buildings - BUILDING_COUNT_BEFORE_ARRAY,
          CLIMBS = pathfinding + CLIMB_DATA,
          LEG_GATE = control + C.LEGS,
          UNIT_IN_PASSAGE = UNIT_IN_PASSAGE,
          UNIT_CAN_CLIMB = UNIT_CAN_CLIMB,
          UNIT_START = UNIT_START,
          RULE_OK = ruleOk,
          CHAIN_BUILD = chainBuild,
          SPECIAL_R1 = control + C.SPECIAL_R1,
          SPECIAL_R2 = control + C.SPECIAL_R2,
          SPECIAL_P = control + C.SPECIAL_P,
          SHUT_GATES = prepare,
          REOPEN_GATES = restore,
          DO_PATHFINDING = doPathfinding,
          ROW_TABLE = rowTable,
          BUILDING_MAP = buildingMap,
          BUILDINGS = buildings,
          GATE_OR_TOWER = gateOrTower,
          TILE_FLAGS = tileFlags,
        })
        patch(call, branch(0xE8, call, pathSearch, 5))

        local cursorSite = (stairsOn or stairsAiOn)
          and scanOptional(AOB_MOVE_CURSOR, "the troops' move cursor") or nil
        local units
        if cursorSite ~= nil then
          units = readAddress(cursorSite + CURSOR_UNITS_STATE_OPERAND) + UNIT_START
        end
        if stairsOn then
          -- The "can't go there" cursor for a target the rule rules out.
          local mouseSite = scanOptional(AOB_MOUSE_TILE, "the mouse's tile")
          if cursorSite ~= nil and mouseSite ~= nil then
            local hook = cursorSite + CURSOR_HOOK
            local cursor = core.allocateAssembly(templates.cursor, {
              UNITS_STATE = readAddress(cursorSite + CURSOR_UNITS_STATE_OPERAND),
              CAN_A_UNIT_CLIMB = callTarget(cursorSite + CURSOR_CAN_CLIMB_CALL),
              MOUSE_X = readAddress(mouseSite + MOUSE_X_OPERAND),
              MOUSE_Y = readAddress(mouseSite + MOUSE_Y_OPERAND),
              UNITS = units,
              RULE_OK = ruleOk,
              RESUME = cursorSite + CURSOR_RESUME,
            })
            patch(hook, branch(0xE9, hook, cursor, CURSOR_HOOK_SIZE))
          end

        end

        -- Who is in a passage and who is on a roof, by how they got onto the gatehouse.
        if stairsOn or stairsAiOn then
          local flagSite = scanOptional(AOB_PASSAGE_FLAG, "the passage-or-roof decision")
          if flagSite ~= nil then
            local hook = flagSite + PASSAGE_HOOK
            local flag = core.allocateAssembly(templates.passage_flag, {
              UNITS = (readAddress(flagSite + PASSAGE_TILE_OPERAND) - 0xD8) & 0xFFFFFFFF,
              PLAYER_AIC = playerAic,
              TOP_ENABLED = control + C.TOP_ENABLED,
              AI_ENABLED = control + C.AI_ENABLED,
              BUILDING_MAP = buildingMap,
              BUILDINGS = buildings,
              ROW_TABLE = rowTable,
              RESUME = hook + PASSAGE_HOOK_SIZE,
              DONE = flagSite + PASSAGE_HOOK + (readByte(flagSite + PASSAGE_DONE_JUMP + 1) & 0x7F),
            })
            patch(hook, branch(0xE9, hook, flag, PASSAGE_HOOK_SIZE))
          end
        end

        -- ... and the move order for it is never given, so nobody starts walking.
        if stairsOn or stairsAiOn then
          local tribeSite = scanOptional(AOB_TRIBE_MOVE, "the troops' move order")
          if tribeSite ~= nil and units ~= nil then
            local hook = tribeSite + TRIBE_HOOK
            local move = core.allocateAssembly(templates.tribe_move, {
              UNITS = units,
              PLAYER_AIC = playerAic,
              TOP_ENABLED = control + C.TOP_ENABLED,
              AI_ENABLED = control + C.AI_ENABLED,
              RULE_OK = ruleOk,
              FAIL = jumpTarget(tribeSite + TRIBE_GIVE_UP_JUMP),
              RESUME = hook + TRIBE_HOOK_SIZE,
            })
            patch(hook, branch(0xE9, hook, move, TRIBE_HOOK_SIZE))
          end
        end
      end
    end

    log(INFO, string.format(
      "smarter-gatehouses: enemy gates closed %s, centred %s, reachable only %s, stairs "
      .. "needed %s, for the AI %s; %d place(s) in the game changed.",
      tostring(enemyClosedOn), tostring(centredOn), tostring(reachableOn),
      tostring(stairsOn), tostring(stairsAiOn), #patched))
  end,

  disable = function(self, config)
    for index = #patched, 1, -1 do
      core.writeCodeBytes(patched[index].address, patched[index].bytes)
    end
    patched = {}
  end,
}
