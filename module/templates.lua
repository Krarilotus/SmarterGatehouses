--[[
  Smarter Gatehouses - injected assembly.

  Every script is FASM source for core.allocateAssembly. Values are passed in as
  assembly-time constants, so nothing here hardcodes an address: init.lua reads them all
  out of the running executable. Keep the comments here rather than in the strings
  (fasm.dll gets one fixed 64000 byte buffer for source, symbols and output together).

  Register discipline: the game is MSVC, so ebx, esi, edi and ebp are preserved across a
  call and eax, ecx and edx are not.
]]

---------------------------------------------------------------------------------------
-- When a gatehouse closes
---------------------------------------------------------------------------------------
-- Replaces the distance test in BuildingsState::updateGateDrawBridgeOpenCloseLogic, inside
-- its loop over the owner's enemy units. There EAX is the unit (index * 0x490), EDI the
-- building (index * 0x32C), [esp+0x30] / [esp+0x34] the building's x / y in micro units
-- (eight to a tile), and the game closes the gate when the larger of the two axis
-- distances is under the range.
--
-- The building's x / y is its corner, which is why the unmodified game reacts earlier on
-- two sides. Half the footprint (size * 8 / 2) is added to both when centring is on.
--
-- "reachable" is the second test: the enemy's area number has to match the area of the
-- tile outside either entrance, or of the gatehouse itself (which shares its area with the
-- walls joined to it). The game builds that area map with every gatehouse shut, so an
-- open gate does not join the two sides. Area 0 is ground nobody can walk on. Anything
-- that is not a gatehouse (type 0x2D / 0x2E) keeps the game's behaviour.
local detect = [[
mov ecx, [edi+BLD_SIZE]
shl ecx, 2
imul ecx, [CENTRE_ENABLED]
movsx edx, word [eax+UNIT_MICROX]
sub edx, [esp+0x30]
sub edx, ecx
jns dx_ok
neg edx
dx_ok:
cmp edx, [RANGE_ADDRESS]
jge not_found
movsx edx, word [eax+UNIT_MICROY]
sub edx, [esp+0x34]
sub edx, ecx
jns dy_ok
neg edx
dy_ok:
cmp edx, [RANGE_ADDRESS]
jge not_found
cmp dword [REACH_ENABLED], 0
je found
push eax
push edi
call reachable
test eax, eax
jne found
not_found:
jmp CONTINUE
found:
jmp FOUND

reachable:
push ebx
push esi
push edi
push ebp
mov edx, [esp+20]
movsx eax, word [edx+BLD_TYPE]
sub eax, 0x2D
cmp eax, 1
ja r_yes
mov eax, [esp+24]
movsx ecx, word [eax+UNIT_Y]
movsx eax, word [eax+UNIT_X]
call area_at
test eax, eax
je r_no
mov ebx, eax
movsx esi, word [edx+BLD_X]
movsx edi, word [edx+BLD_Y]
mov ebp, [edx+BLD_SIZE]
mov eax, ebp
shr eax, 1
lea ecx, [esi+eax]
add eax, edi
push eax
push ecx
mov eax, [esp]
mov ecx, [esp+4]
call area_at
cmp eax, ebx
je r_yes2
cmp word [edx+BLD_VARIATION], 0x50
jne r_other
lea eax, [esi-1]
mov ecx, [esp+4]
call area_at
cmp eax, ebx
je r_yes2
lea eax, [esi+ebp]
mov ecx, [esp+4]
call area_at
cmp eax, ebx
je r_yes2
jmp r_no2
r_other:
mov eax, [esp]
lea ecx, [edi-1]
call area_at
cmp eax, ebx
je r_yes2
mov eax, [esp]
lea ecx, [edi+ebp]
call area_at
cmp eax, ebx
je r_yes2
r_no2:
add esp, 8
r_no:
xor eax, eax
jmp r_out
r_yes2:
add esp, 8
r_yes:
mov eax, 1
r_out:
pop ebp
pop edi
pop esi
pop ebx
ret 8

area_at:
cmp eax, 399
ja area_none
cmp ecx, 399
ja area_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+AREA_MAP]
ret
area_none:
xor eax, eax
ret
]]

---------------------------------------------------------------------------------------
-- Route finding: cutting a gatehouse off from the walls beside it
---------------------------------------------------------------------------------------
-- cut_sides(building pointer), stdcall. A gatehouse's footprint is wall-top tiles like any
-- other; the passage and the roof are the same tiles, and the only thing that makes it a
-- gate is one link at each entrance. So "through the gate but not onto the walls" means:
-- for the length of one search, no link between the footprint and anything beside it.
--
-- Walks the square one tile larger than the footprint on every side, remembers each tile's
-- link byte (tile index, old value) and clears every link that crosses the footprint's
-- edge. The caller then lets the game put the two entrance links back. Link bits, from the
-- game's own area fill: 0x01 (x, y-1), 0x02 (x+1, y-1), 0x04 (x+1, y), 0x08 (x+1, y+1),
-- 0x10 (x, y+1), 0x20 (x-1, y+1), 0x40 (x-1, y), 0x80 (x-1, y-1).
--
-- This runs for almost every route search once "stairs needed" is on, so which bits to
-- clear is not worked out neighbour by neighbour: a column is one of five kinds (outside
-- left, left edge, middle, right edge, outside right) and so is a row, and init.lua fills
-- c_masks with the 25 answers. Middle tiles have nothing to clear and are skipped without
-- being remembered.
local cut_sides = [[
push ebx
push esi
push edi
push ebp
mov edx, [esp+20]
movsx eax, word [edx+0xEE]
dec eax
mov [CUT_X], eax
movsx eax, word [edx+0xF0]
dec eax
mov [CUT_Y], eax
mov eax, [edx+0xF8]
mov [CUT_N], eax
xor edi, edi
c_row:
mov eax, edi
call c_class
mov ebp, eax
xor esi, esi
c_col:
mov eax, esi
call c_class
lea eax, [eax+eax*4]
add eax, ebp
movzx ebx, byte [c_masks+eax]
test ebx, ebx
je c_next
mov eax, [CUT_X]
add eax, esi
mov ecx, [CUT_Y]
add ecx, edi
cmp eax, 399
ja c_next
cmp ecx, 399
ja c_next
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
mov eax, [LINK_COUNT]
cmp eax, MAX_LINKS
jae c_out
mov [eax*8+LINK_LIST], ecx
movzx edx, byte [ecx+LINKAGE]
mov [eax*8+LINK_LIST+4], edx
inc eax
mov [LINK_COUNT], eax
not bl
and [ecx+LINKAGE], bl
c_next:
inc esi
mov eax, [CUT_N]
add eax, 2
cmp esi, eax
jb c_col
inc edi
cmp edi, eax
jb c_row
c_out:
pop ebp
pop edi
pop esi
pop ebx
ret 4
c_class:
test eax, eax
je c_k0
cmp eax, 1
je c_k1
cmp eax, [CUT_N]
jb c_k2
je c_k3
mov eax, 4
ret
c_k0:
xor eax, eax
ret
c_k1:
mov eax, 1
ret
c_k2:
mov eax, 2
ret
c_k3:
mov eax, 3
ret
]]

---------------------------------------------------------------------------------------
-- Route finding: setting every gatehouse up for one search
---------------------------------------------------------------------------------------
-- prepare(player, mode), stdcall. Each gatehouse is made one of
--   as it is     (mode 0)
--   roof         (mode 1): passage shut, roof joined to the walls - along the walls, over it
--   passage      (mode 2): passage open, roof cut off from the walls - through it, below
--   per gatehouse (mode 3): roof or passage, for a trip between the ground and the heights
-- and, when that setting is on, a gatehouse of another team is shut as well.
--
-- Mode 3 asks, for each gatehouse: is it the one the unit stands on (on the roof -> roof;
-- in the passage -> passage) or the one it is going to (roof)? Otherwise it is a passage
-- when one of its two entrances lies in CHAIN - the ground the unit has to cross on foot
-- before it reaches stairs, filled in by chain_build - and a roof when not, since then the
-- only use the trip can make of it is walking over it on the walls.
--
-- "Shut" is the game's own mechanism: the building's gate state byte (+0x2A2, 2 = closed)
-- decides whether updatePathLinkageTileMapRelatedToGates lays the two entrance links or
-- takes them away, and the game itself flips that byte for every gatehouse and back when it
-- builds its area map. Here the old state goes into a list for restore to put back. A
-- gatehouse an enemy is holding (+0x2C6) is left open to everyone, as in the game's own
-- "can this player get from area to area" test.
local prepare = [[
push ebx
push esi
push edi
push ebp
mov dword [GATE_COUNT], 0
mov dword [LINK_COUNT], 0
mov ebp, [esp+20]
cmp dword [esp+24], 0
jne p_go
cmp dword [ENEMY_ENABLED], 0
je p_out
test ebp, ebp
je p_out
p_go:
mov edi, 1
mov esi, FIRST_BUILDING
p_loop:
cmp edi, [BUILDING_COUNT]
jge p_out
cmp word [esi+0xD0], 0
je p_next
movzx eax, word [esi+0xD2]
sub eax, 0x2D
cmp eax, 1
ja p_next
mov ebx, [esp+24]
cmp ebx, 3
jne p_enemy
cmp edi, [FORCE_BID]
jne p_special
mov ebx, [FORCE_MODE]
jmp p_enemy
p_special:
cmp edi, [SPECIAL_R1]
je p_roof
cmp edi, [SPECIAL_R2]
je p_roof
cmp edi, [SPECIAL_P]
je p_pass
movzx eax, word [esi+0x2D2]
test eax, eax
je p_pass
imul eax, eax, 0x204
mov ecx, [eax+CLIMBS+0x34]
cmp ecx, 1023
ja p_other
cmp byte [ecx+CHAIN], 0
jne p_pass
p_other:
mov ecx, [eax+CLIMBS+0x38]
cmp ecx, 1023
ja p_roof
cmp byte [ecx+CHAIN], 0
jne p_pass
p_roof:
mov ebx, 1
jmp p_enemy
p_pass:
mov ebx, 2
p_enemy:
cmp dword [ENEMY_ENABLED], 0
je p_decided
test ebp, ebp
je p_decided
cmp word [esi+0x2C6], 0
jne p_decided
movsx eax, word [esi+0xD6]
mov eax, [eax*4+TEAMS]
cmp eax, [ebp*4+TEAMS]
je p_decided
or ebx, 1
p_decided:
test ebx, ebx
je p_next
test ebx, 2
jne p_change
cmp byte [esi+0x2A2], 2
je p_next
p_change:
mov eax, [GATE_COUNT]
cmp eax, MAX_GATES
jae p_out
mov [eax*8+GATE_LIST], edi
movzx ecx, byte [esi+0x2A2]
mov [eax*8+GATE_LIST+4], ecx
inc eax
mov [GATE_COUNT], eax
test ebx, 2
je p_state
push esi
call CUT_SIDES
p_state:
test ebx, 1
je p_relink
mov byte [esi+0x2A2], 2
p_relink:
push edi
mov ecx, PATHFINDING
call LINK_GATES
p_next:
inc edi
add esi, 0x32C
jmp p_loop
p_out:
pop ebp
pop edi
pop esi
pop ebx
ret 8
]]

---------------------------------------------------------------------------------------
-- Route finding: which ground has to be crossed on foot
---------------------------------------------------------------------------------------
-- chain_build(sourceIsHigh), stdcall, for a trip between the ground and the heights. The
-- game's area map is built with every gatehouse shut, so each stretch of ground between
-- gatehouses is its own area, and ground that has stairs up to the walls shares the walls'
-- area (W, the area of the high end of the trip). Starting from the area of the ground end
-- (for a unit in a passage: the ground at its gatehouse's entrance), CHAIN marks every area
-- reachable through open gatehouses without passing through W: the ground the unit must
-- walk before it can climb. Ground already in W needs no gatehouse at all, and CHAIN stays
-- empty.
local chain_build = [[
push ebx
push esi
push edi
push ebp
mov ecx, 256
mov eax, CHAIN
z_loop:
mov dword [eax], 0
add eax, 4
dec ecx
jne z_loop
mov eax, [PATHFINDING+0x10]
mov ecx, [PATHFINDING+0x14]
call area_at
mov ebx, eax
mov eax, [PATHFINDING+8]
mov ecx, [PATHFINDING+0xC]
call area_at
cmp dword [esp+20], 0
je g_src
mov ebp, eax
mov edi, ebx
jmp have
g_src:
mov ebp, ebx
mov edi, eax
mov eax, [SPECIAL_P]
test eax, eax
je have
imul eax, eax, 0x32C
movzx eax, word [eax+BUILDINGS+0x2D2]
test eax, eax
je have
imul eax, eax, 0x204
mov edi, [eax+CLIMBS+0x34]
have:
mov [HIGH_AREA], ebp
test edi, edi
je done
cmp edi, 1023
ja done
cmp edi, ebp
je done
mov byte [edi+CHAIN], 1
mov esi, 32
pass:
xor ebx, ebx
mov ecx, 1
mov edx, CLIMBS+0x204
l_loop:
cmp ecx, [PATHFINDING]
jge l_end
cmp ecx, MAX_CLIMBS
jae l_end
cmp dword [edx], 1
jne l_next
mov eax, [edx+4]
sub eax, 3
cmp eax, 1
ja l_next
cmp dword [edx+0x18], 0
je l_next
mov eax, [edx+0x34]
cmp eax, 1023
ja l_next
mov edi, [edx+0x38]
cmp edi, 1023
ja l_next
cmp byte [eax+CHAIN], 0
je l_try_b
cmp byte [edi+CHAIN], 0
jne l_next
test edi, edi
je l_next
cmp edi, ebp
je l_next
mov byte [edi+CHAIN], 1
mov ebx, 1
jmp l_next
l_try_b:
cmp byte [edi+CHAIN], 0
je l_next
test eax, eax
je l_next
cmp eax, ebp
je l_next
mov byte [eax+CHAIN], 1
mov ebx, 1
l_next:
inc ecx
add edx, 0x204
jmp l_loop
l_end:
test ebx, ebx
je done
dec esi
jne pass
done:
pop ebp
pop edi
pop esi
pop ebx
ret 4

area_at:
cmp eax, 399
ja a_none
cmp ecx, 399
ja a_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+AREA_MAP]
ret
a_none:
xor eax, eax
ret
]]

-- restore(): every gate state byte back, the entrance links relaid from it, and then the
-- remembered link bytes written back last to first, so a tile two gatehouses both touched
-- ends up with the value it had before either.
local restore = [[
push ebx
push esi
mov esi, [GATE_COUNT]
xor ebx, ebx
r_gates:
cmp ebx, esi
jae r_links
mov eax, [ebx*8+GATE_LIST]
mov ecx, [ebx*8+GATE_LIST+4]
imul edx, eax, 0x32C
mov [edx+BUILDINGS+0x2A2], cl
push eax
mov ecx, PATHFINDING
call LINK_GATES
inc ebx
jmp r_gates
r_links:
mov ebx, [LINK_COUNT]
r_link:
test ebx, ebx
je r_done
dec ebx
mov eax, [ebx*8+LINK_LIST]
mov ecx, [ebx*8+LINK_LIST+4]
mov [eax+LINKAGE], cl
jmp r_link
r_done:
mov dword [GATE_COUNT], 0
mov dword [LINK_COUNT], 0
pop esi
pop ebx
ret
]]

---------------------------------------------------------------------------------------
-- Route finding: one gatehouse used twice
---------------------------------------------------------------------------------------
-- two_legs(player, flag, case), stdcall, returns the route's length, 0 when there is none
-- (the caller then uses the game's own search) or -1 when it does not apply.
--
-- One search can use a gatehouse as a passage or as a roof, not both, but "onto this
-- gatehouse's roof from outside it" (case 1) needs both: through it, up the stairs behind
-- it, back onto it. So does "down from this roof to the ground on its far side" (case 2).
-- Both are searched in two legs through the entrance E on the stairs' side, with the
-- gatehouse (LEG_GATE) a passage on the ground leg and a roof on the other, and the two
-- routes joined into one. Without this the rule's search fails and the fallback walks the
-- unit up through the doors - the jump onto the roof this avoids.
--
-- E is the entrance whose ground is the high end's area (HIGH_AREA, stairs to the walls),
-- else the one outside CHAIN, else the one farther from the ground end. The first leg must
-- end on E - its route is replayed with the game's direction table to make sure - and the
-- joined route must fit the unit's 800-step plan, or the answer is 0.
--
-- A route is packed four bits a step, even steps in the low half of each byte, into the
-- buffer at PathFindingState + 0x1BB38; + 0x1BB3C is its length.
local two_legs = [[
push ebx
push esi
push edi
push ebp
mov ebx, [LEG_GATE]
imul ebx, ebx, 0x32C
add ebx, BUILDINGS
movsx esi, word [ebx+0xEE]
movsx edi, word [ebx+0xF0]
mov ebp, [ebx+0xF8]
mov eax, ebp
shr eax, 1
cmp word [ebx+0x102], 0x50
jne t_other
lea ecx, [esi-1]
mov [E1X], ecx
lea ecx, [esi+ebp]
mov [E2X], ecx
lea ecx, [edi+eax]
mov [E1Y], ecx
mov [E2Y], ecx
jmp t_have
t_other:
lea ecx, [esi+eax]
mov [E1X], ecx
mov [E2X], ecx
lea ecx, [edi-1]
mov [E1Y], ecx
lea ecx, [edi+ebp]
mov [E2Y], ecx
t_have:
mov eax, [E1X]
mov ecx, [E1Y]
call area_at
mov esi, eax
mov eax, [E2X]
mov ecx, [E2Y]
call area_at
mov edi, eax
xor ebx, ebx
cmp esi, 1023
ja t_in2
cmp byte [esi+CHAIN], 0
je t_in2
inc ebx
t_in2:
cmp edi, 1023
ja t_inq
cmp byte [edi+CHAIN], 0
je t_inq
inc ebx
t_inq:
test ebx, ebx
jne t_go
or eax, -1
jmp t_out
t_go:
mov ebp, [HIGH_AREA]
cmp esi, ebp
je t_pick1
cmp edi, ebp
je t_pick2
cmp esi, 1023
ja t_c2
cmp byte [esi+CHAIN], 0
je t_pick1
t_c2:
cmp edi, 1023
ja t_far
cmp byte [edi+CHAIN], 0
je t_pick2
t_far:
mov edx, PATHFINDING+8
cmp dword [esp+28], 1
je t_ground
mov edx, PATHFINDING+0x10
t_ground:
mov eax, [E1X]
sub eax, [edx]
cdq
xor eax, edx
sub eax, edx
mov esi, eax
mov edx, PATHFINDING+8
cmp dword [esp+28], 1
je t_ground2
mov edx, PATHFINDING+0x10
t_ground2:
mov eax, [E1Y]
sub eax, [edx+4]
mov ecx, edx
cdq
xor eax, edx
sub eax, edx
add esi, eax
mov eax, [E2X]
sub eax, [ecx]
cdq
xor eax, edx
sub eax, edx
mov edi, eax
mov eax, [E2Y]
sub eax, [ecx+4]
cdq
xor eax, edx
sub eax, edx
add edi, eax
cmp esi, edi
jge t_pick1
t_pick2:
mov eax, [E2X]
mov ecx, [E2Y]
jmp t_set
t_pick1:
mov eax, [E1X]
mov ecx, [E1Y]
t_set:
mov [EX], eax
mov [EY], ecx
mov eax, [PATHFINDING+8]
mov [SX], eax
mov eax, [PATHFINDING+0xC]
mov [SY], eax
mov eax, [PATHFINDING+0x10]
mov [DX_], eax
mov eax, [PATHFINDING+0x14]
mov [DY_], eax
mov eax, [EX]
mov [PATHFINDING+0x10], eax
mov eax, [EY]
mov [PATHFINDING+0x14], eax
mov eax, [LEG_GATE]
mov [FORCE_BID], eax
mov eax, [esp+28]
xor eax, 3
mov [FORCE_MODE], eax
call leg
test eax, eax
jle t_fail
mov [N1], eax
mov ecx, [PATHFINDING+0x1BB38]
mov esi, [SX]
mov edi, [SY]
xor edx, edx
v_loop:
cmp edx, [N1]
jge v_done
mov eax, edx
shr eax, 1
movzx eax, byte [ecx+eax]
test dl, 1
je v_low
shr eax, 4
v_low:
and eax, 0xF
cmp eax, 7
ja t_fail
add esi, [eax*8+DIR_TABLE]
add edi, [eax*8+DIR_TABLE+4]
inc edx
jmp v_loop
v_done:
cmp esi, [EX]
jne t_fail
cmp edi, [EY]
jne t_fail
mov esi, [PATHFINDING+0x1BB38]
mov edi, SAVE_A
call copy_plan
mov eax, [EX]
mov [PATHFINDING+8], eax
mov eax, [EY]
mov [PATHFINDING+0xC], eax
mov eax, [DX_]
mov [PATHFINDING+0x10], eax
mov eax, [DY_]
mov [PATHFINDING+0x14], eax
mov eax, [esp+28]
mov [FORCE_MODE], eax
call leg
test eax, eax
jle t_fail
mov ebx, eax
add eax, [N1]
cmp eax, 800
jg t_fail
mov esi, [PATHFINDING+0x1BB38]
mov edi, SAVE_B
call copy_plan
mov esi, SAVE_A
mov edi, [PATHFINDING+0x1BB38]
call copy_plan
mov ecx, [PATHFINDING+0x1BB38]
xor edx, edx
j_loop:
cmp edx, ebx
jge j_done
mov eax, edx
shr eax, 1
movzx eax, byte [eax+SAVE_B]
test dl, 1
je j_low
shr eax, 4
j_low:
and eax, 0xF
mov esi, [N1]
add esi, edx
mov edi, esi
shr edi, 1
test esi, 1
jne j_high
and byte [ecx+edi], 0xF0
or [ecx+edi], al
jmp j_next
j_high:
shl eax, 4
and byte [ecx+edi], 0x0F
or [ecx+edi], al
j_next:
inc edx
jmp j_loop
j_done:
add ebx, [N1]
mov [PATHFINDING+0x1BB3C], ebx
call put_back
mov eax, ebx
jmp t_out
t_fail:
call put_back
xor eax, eax
t_out:
mov dword [FORCE_BID], 0
pop ebp
pop edi
pop esi
pop ebx
ret 12

leg:
push 3
push dword [esp+28]
call SHUT_GATES
push dword [esp+28]
push dword [esp+28]
mov ecx, PATHFINDING
call DO_PATHFINDING
push eax
call REOPEN_GATES
pop eax
ret

put_back:
mov eax, [SX]
mov [PATHFINDING+8], eax
mov eax, [SY]
mov [PATHFINDING+0xC], eax
mov eax, [DX_]
mov [PATHFINDING+0x10], eax
mov eax, [DY_]
mov [PATHFINDING+0x14], eax
ret

copy_plan:
mov ecx, 100
cp_loop:
mov eax, [esi]
mov [edi], eax
add esi, 4
add edi, 4
dec ecx
jne cp_loop
ret

area_at:
cmp eax, 399
ja a_none
cmp ecx, 399
ja a_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+AREA_MAP]
ret
a_none:
xor eax, eax
ret
]]

---------------------------------------------------------------------------------------
-- Stairs needed: does a finished route use a gatehouse as stairs?
---------------------------------------------------------------------------------------
-- route_ok(unit, steps), stdcall: replays the route in PathFindingState + 0x1BB38 from the
-- unit's tile with the game's direction table and returns 0 if it walks into a gatehouse
-- one way and out of it the other - in at an entrance and out onto a wall, or the reverse -
-- or comes in at an entrance and ends on the gatehouse, whose tiles are its roof. A unit
-- that starts on a gatehouse came in by the passage when its passage byte (+0x402) is set.
local route_ok = [[
push ebx
push esi
push edi
push ebp
mov eax, [PATHFINDING+8]
mov [RX], eax
mov eax, [PATHFINDING+0xC]
mov [RY], eax
mov eax, [RX]
mov ecx, [RY]
call gate_at
mov [GIN], eax
mov dword [ENTRY_KIND], 1
test eax, eax
je r_first
mov edx, [esp+20]
cmp byte [edx+0x402], 0
je r_first
mov dword [ENTRY_KIND], 0
r_first:
xor ebx, ebx
r_loop:
cmp ebx, [esp+24]
jge r_end
mov ecx, [PATHFINDING+0x1BB38]
mov eax, ebx
shr eax, 1
movzx eax, byte [ecx+eax]
test bl, 1
je r_low
shr eax, 4
r_low:
and eax, 0xF
cmp eax, 7
ja r_ok
mov esi, [RX]
add esi, [eax*8+DIR_TABLE]
mov edi, [RY]
add edi, [eax*8+DIR_TABLE+4]
mov eax, esi
mov ecx, edi
call gate_at
mov ebp, eax
cmp ebp, [GIN]
je r_next
mov eax, [GIN]
test eax, eax
je r_enter
mov ecx, esi
mov edx, edi
call is_entrance
xor eax, 1
cmp eax, [ENTRY_KIND]
jne r_bad
r_enter:
mov [GIN], ebp
test ebp, ebp
je r_next
mov eax, ebp
mov ecx, [RX]
mov edx, [RY]
call is_entrance
xor eax, 1
mov [ENTRY_KIND], eax
r_next:
mov [RX], esi
mov [RY], edi
inc ebx
jmp r_loop
r_end:
cmp dword [GIN], 0
je r_ok
cmp dword [ENTRY_KIND], 0
je r_bad
r_ok:
mov eax, 1
jmp r_out
r_bad:
xor eax, eax
r_out:
pop ebp
pop edi
pop esi
pop ebx
ret 8

gate_at:
cmp eax, 399
ja g_none
cmp ecx, 399
ja g_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+BUILDING_MAP]
test eax, eax
je g_none
imul ecx, eax, 0x32C
movzx ecx, word [ecx+BUILDINGS+0xD2]
sub ecx, 0x2D
cmp ecx, 1
jbe g_done
g_none:
xor eax, eax
g_done:
ret

is_entrance:
push ebx
push esi
push edi
imul eax, eax, 0x32C
add eax, BUILDINGS
movsx esi, word [eax+0xEE]
movsx edi, word [eax+0xF0]
mov ebx, [eax+0xF8]
cmp word [eax+0x102], 0x50
jne ie_other
mov eax, ebx
shr eax, 1
add eax, edi
cmp edx, eax
jne ie_no
lea eax, [esi-1]
cmp ecx, eax
je ie_yes
lea eax, [esi+ebx]
cmp ecx, eax
je ie_yes
jmp ie_no
ie_other:
mov eax, ebx
shr eax, 1
add eax, esi
cmp ecx, eax
jne ie_no
lea eax, [edi-1]
cmp edx, eax
je ie_yes
lea eax, [edi+ebx]
cmp edx, eax
je ie_yes
ie_no:
xor eax, eax
jmp ie_out
ie_yes:
mov eax, 1
ie_out:
pop edi
pop esi
pop ebx
ret
]]

---------------------------------------------------------------------------------------
-- Stairs needed: is a unit on a gatehouse down in the passage or up on the roof?
---------------------------------------------------------------------------------------
-- Replaces the decision in UnitsState::updateUnitFadeAndVisibilityNearStructures that sets
-- a unit's passage byte (+0x402) every tick it stands on a gatehouse: the game takes it from
-- where the unit is going - a wall tile means "roof" - so a unit given a new order while in
-- the passage was drawn on top at once and, from then on, counted as being up there. That
-- is how troops walking through a gate could be ordered straight up onto it.
--
-- For a player the rule applies to, it is decided by how the unit got on instead: once in
-- the passage it stays in the passage until it leaves the gatehouse, and it is in the
-- passage when it has just come off the ground (previous structure state +0x308 = 0)
-- either from an entrance tile (previous tile +0x404) or onto one of the two passage tiles
-- next to the entrances. Everything else on a gatehouse is on the roof. Other buildings,
-- and players the rule does not apply to, keep the game's own decision.
--
-- EAX is the unit (index * 0x490); EBX, EBP and EDI are the game's and are kept.
local passage_flag = [[
push ebx
push ebp
push edi
movsx ecx, word [eax+UNITS+0x96]
imul ecx, ecx, 0x39F4
cmp dword [ecx+PLAYER_AIC], 0
je f_human
cmp dword [AI_ENABLED], 0
je f_vanilla
jmp f_mine
f_human:
cmp dword [TOP_ENABLED], 0
je f_vanilla
f_mine:
mov ecx, [eax+UNITS+0xD4]
movzx esi, word [ecx*2+BUILDING_MAP]
test esi, esi
je f_vanilla
imul esi, esi, 0x32C
add esi, BUILDINGS
movzx edx, word [esi+0xD2]
sub edx, 0x2D
cmp edx, 1
ja f_vanilla
cmp byte [eax+UNITS+0x402], 0
jne f_passage
cmp word [eax+UNITS+0x308], 0
jne f_roof
movsx ebx, word [esi+0xEE]
movsx ebp, word [esi+0xF0]
mov edi, [esi+0xF8]
mov edx, edi
shr edx, 1
cmp word [esi+0x102], 0x50
jne f_turned
lea ecx, [ebp+edx]
call row_tile
mov edx, [eax+UNITS+0x404]
lea esi, [ecx-1]
cmp edx, esi
je f_passage
lea esi, [ecx+edi]
cmp edx, esi
je f_passage
mov edx, [eax+UNITS+0xD4]
cmp edx, ecx
je f_passage
lea esi, [ecx+edi-1]
cmp edx, esi
je f_passage
jmp f_roof
f_turned:
add ebx, edx
lea ecx, [ebp-1]
call row_tile
cmp ecx, [eax+UNITS+0x404]
je f_passage
lea ecx, [ebp+edi]
call row_tile
cmp ecx, [eax+UNITS+0x404]
je f_passage
mov ecx, ebp
call row_tile
cmp ecx, [eax+UNITS+0xD4]
je f_passage
lea ecx, [ebp+edi-1]
call row_tile
cmp ecx, [eax+UNITS+0xD4]
je f_passage
f_roof:
mov byte [eax+UNITS+0x402], 0
jmp f_done
f_passage:
mov byte [eax+UNITS+0x402], 0xA
f_done:
pop edi
pop ebp
pop ebx
jmp DONE
f_vanilla:
pop edi
pop ebp
pop ebx
mov esi, [eax+UNITS+0xD8]
jmp RESUME

row_tile:
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, ebx
ret
]]

---------------------------------------------------------------------------------------
-- Route finding: the wrapper
---------------------------------------------------------------------------------------
-- Stands in for the call to PathFindingState::doPathfinding(player, flag) in
-- UnitsState::setDestinationForUnit, the one place a unit's route is searched. ECX is the
-- PathFindingState, whose +8 / +0xC is the tile the unit stands on and +0x10 / +0x14 the
-- tile it wants to reach; ESI is the unit (UnitsState + index * 0x490).
--
-- With "stairs needed" on, both ends are sorted into ground, high (wall, tower) or
-- gatehouse. A unit on a gatehouse tile that is walking through the passage counts as on
-- the ground: that is the same per-unit byte the game uses to draw it down there.
--   ground to ground      every gatehouse a passage: through it below, never onto its roof
--   high to high          every gatehouse a roof: over it on top, never down its doors
--   ground to / from high each gatehouse one or the other, see prepare (mode 3)
--
-- Before a ground / high search, rule_ok (below) says whether the rule leaves any way there
-- at all. When it does not - or when the rule's own search finds nothing - the game's own
-- search is run, and its route is kept only if route_ok finds no gatehouse used as stairs
-- in it. Otherwise the unit is stopped where it stands, exactly as if it had arrived: a
-- failed search alone is what left units frozen mid-stride (most callers set the walking
-- state whatever the search says, and the walk code retries the failing search every 40
-- ticks), and simply taking the game's route is what let a quick second click - through
-- the gate, then onto its roof while still in the passage - walk a unit up the doors.
--
-- high_at(eax = x, ecx = y) returns 0 ground, 1 high, 2 gatehouse; bld_at the building.
local path_search = [[
push ebx
push edi
push ebp
mov ebp, ecx
xor ebx, ebx
mov dword [RULES_NOW], 0
movsx eax, word [esi+UNIT_OWNER]
imul eax, eax, 0x39F4
cmp dword [eax+PLAYER_AIC], 0
je human
cmp dword [AI_ENABLED], 0
je search
jmp rules
human:
cmp dword [TOP_ENABLED], 0
je search
rules:
mov dword [RULES_NOW], 1
mov dword [SPECIAL_R1], 0
mov dword [SPECIAL_R2], 0
mov dword [SPECIAL_P], 0
mov eax, [ebp+8]
mov ecx, [ebp+0xC]
call high_at
cmp eax, 2
jne s_known
mov eax, [ebp+8]
mov ecx, [ebp+0xC]
call bld_at
cmp byte [esi+UNIT_IN_PASSAGE], 0
je s_roof
mov [SPECIAL_P], eax
xor eax, eax
jmp s_known
s_roof:
mov [SPECIAL_R1], eax
mov eax, 2
s_known:
mov edi, eax
mov eax, [ebp+0x10]
mov ecx, [ebp+0x14]
call high_at
cmp eax, 2
jne d_known
mov eax, [ebp+0x10]
mov ecx, [ebp+0x14]
call bld_at
mov [SPECIAL_R2], eax
mov eax, 2
d_known:
test edi, edi
jne s_high
test eax, eax
jne mixed
mov ebx, 2
jmp search
s_high:
mov ebx, 1
test eax, eax
jne search
mixed:
movsx eax, word [esi+UNIT_CAN_CLIMB]
push eax
push dword [ebp+0x14]
push dword [ebp+0x10]
lea eax, [esi+UNIT_START]
push eax
call RULE_OK
xor ebx, ebx
test eax, eax
je search
push edi
call CHAIN_BUILD
mov ebx, 3
mov eax, [SPECIAL_R2]
mov ecx, 1
test edi, edi
je legs
mov eax, [SPECIAL_R1]
mov ecx, 2
legs:
test eax, eax
je search
mov [LEG_GATE], eax
push ecx
push dword [esp+24]
push dword [esp+24]
call TWO_LEGS
cmp eax, -1
je search
test eax, eax
jg done
jmp fallback
search:
mov edi, ebx
push ebx
push dword [esp+20]
call SHUT_GATES
mov ecx, ebp
push dword [esp+20]
push dword [esp+20]
call DO_PATHFINDING
push eax
call REOPEN_GATES
pop eax
cmp dword [RULES_NOW], 0
je done
test edi, edi
je check
test eax, eax
jg done
fallback:
push 0
push dword [esp+20]
call SHUT_GATES
mov ecx, ebp
push dword [esp+20]
push dword [esp+20]
call DO_PATHFINDING
push eax
call REOPEN_GATES
pop eax
check:
test eax, eax
jle done
push eax
push eax
lea ecx, [esi+UNIT_START]
push ecx
call ROUTE_OK
test eax, eax
pop eax
jne done
movzx eax, word [esi+0x6D8]
movzx ecx, word [esi+0x6DA]
mov [esi+0x700], ax
mov [esi+0x702], cx
mov [esi+0x6DC], ax
mov [esi+0x6DE], cx
mov eax, [esi+0x6E8]
mov [esi+0x6EC], eax
xor eax, eax
mov [esi+0x70A], ax
mov [esi+0x70E], ax
mov [esi+0x710], ax
mov [esi+0x8E6], ax
done:
pop ebp
pop edi
pop ebx
ret 8

bld_at:
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+BUILDING_MAP]
ret

high_at:
cmp eax, 399
ja h_none
cmp ecx, 399
ja h_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+BUILDING_MAP]
test eax, eax
je h_flags
imul eax, eax, 0x32C
movsx eax, word [eax+BUILDINGS+0xD2]
cmp eax, 0x2D
je h_gate
cmp eax, 0x2E
je h_gate
cmp dword [eax*4+GATE_OR_TOWER], 0
jne h_high
h_flags:
mov eax, [ecx*4+TILE_FLAGS]
and eax, 0x102
cmp eax, 0x100
je h_high
h_none:
xor eax, eax
ret
h_high:
mov eax, 1
ret
h_gate:
mov eax, 2
ret
]]

---------------------------------------------------------------------------------------
-- Stairs needed: can this unit get there at all?
---------------------------------------------------------------------------------------
-- rule_ok(unit, x, y, canClimb), stdcall; unit is a pointer to the unit itself. Returns 1
-- when the rule leaves a way from the unit to tile (x, y), 0 when it does not.
--
-- Answered from the game's own area map rather than by searching, so it is cheap enough
-- for the cursor. That map is built with every gatehouse shut, so walls, towers and
-- gatehouse roofs share an area, each piece of ground has its own, and real stairs merge
-- the two. The game then joins areas through "climb data": ladders, siege towers, and one
-- entry per gatehouse (types 3 and 4) that joins the ground outside (+0x34), the ground
-- inside (+0x38) and the roof (+0x1E8). Blank the roof on every gatehouse entry for one
-- call of the game's own calculateCanPlayerUnitsNavigateToAreaFromArea, and its answer is
-- the rule: through a gate, yes; up onto the roof from its own passage, no.
--
-- Only a trip between the ground and the heights is asked about; ground to ground and
-- wall to wall are the game's business. A unit down in a gatehouse's passage (+0x402)
-- stands on roof tiles but is on the ground: its area is taken from the gatehouse's climb
-- entry (building +0x2D2) instead.
local rule_ok = [[
push ebx
push esi
push edi
push ebp
mov esi, [esp+20]
xor ebx, ebx
movsx eax, word [esi+0xC4]
movsx ecx, word [esi+0xC6]
call high_at
cmp eax, 2
jne k_s
cmp byte [esi+0x402], 0
je k_s
xor eax, eax
mov ebx, 1
k_s:
mov edi, eax
mov eax, [esp+24]
mov ecx, [esp+28]
call high_at
test edi, edi
setne dl
test eax, eax
setne al
cmp al, dl
je ok
mov eax, [esp+24]
mov ecx, [esp+28]
call area_at
test eax, eax
je ok
mov ebp, eax
movsx eax, word [esi+0xC4]
movsx ecx, word [esi+0xC6]
test ebx, ebx
je s_plain
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+BUILDING_MAP]
imul eax, eax, 0x32C
movzx eax, word [eax+BUILDINGS+0x2D2]
test eax, eax
je ok
imul eax, eax, 0x204
mov eax, [eax+CLIMBS+0x34]
jmp s_got
s_plain:
call area_at
s_got:
test eax, eax
je ok
cmp eax, ebp
je ok
mov edi, eax
call hide_roofs
push dword [esp+32]
push ebp
push edi
movsx eax, word [esi+0x96]
push eax
mov ecx, PATHFINDING
call CAN_NAV
mov ebx, eax
call show_roofs
test ebx, ebx
je no
ok:
mov eax, 1
jmp r_out
no:
xor eax, eax
r_out:
pop ebp
pop edi
pop esi
pop ebx
ret 16

hide_roofs:
mov ecx, 1
mov edx, CLIMBS+0x204
h_loop:
cmp ecx, [PATHFINDING]
jge h_done
cmp ecx, MAX_CLIMBS
jae h_done
mov eax, [edx+4]
sub eax, 3
cmp eax, 1
ja h_next
mov eax, [edx+0x1E8]
mov [ecx*4+SHADOW], eax
mov dword [edx+0x1E8], 0
h_next:
inc ecx
add edx, 0x204
jmp h_loop
h_done:
ret

show_roofs:
mov ecx, 1
mov edx, CLIMBS+0x204
w_loop:
cmp ecx, [PATHFINDING]
jge w_done
cmp ecx, MAX_CLIMBS
jae w_done
mov eax, [edx+4]
sub eax, 3
cmp eax, 1
ja w_next
mov eax, [ecx*4+SHADOW]
mov [edx+0x1E8], eax
w_next:
inc ecx
add edx, 0x204
jmp w_loop
w_done:
ret

area_at:
cmp eax, 399
ja a_none
cmp ecx, 399
ja a_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+AREA_MAP]
ret
a_none:
xor eax, eax
ret

high_at:
cmp eax, 399
ja g_none
cmp ecx, 399
ja g_none
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE]
add ecx, eax
movzx eax, word [ecx*2+BUILDING_MAP]
test eax, eax
je g_flags
imul eax, eax, 0x32C
movsx eax, word [eax+BUILDINGS+0xD2]
cmp eax, 0x2D
je g_gate
cmp eax, 0x2E
je g_gate
cmp dword [eax*4+GATE_OR_TOWER], 0
jne g_high
g_flags:
mov eax, [ecx*4+TILE_FLAGS]
and eax, 0x102
cmp eax, 0x100
je g_high
g_none:
xor eax, eax
ret
g_high:
mov eax, 1
ret
g_gate:
mov eax, 2
ret
]]

-- The move cursor, in MenuItemActionHandler_InGameMenu_UnitSelectionAndControlsUnk. It
-- replaces "mov ebx, [esp+0x2C] / jmp" right after the game's own area test for the first
-- selected soldier (EBP). EBX = 0 is what sends the game on to its own "can't go there"
-- cursor, so a target the rule rules out gets exactly that cursor and nothing new is drawn.
-- EDI (zero), ESI and EBP are left as they are; EAX, ECX and EDX are dead here.
local cursor = [[
mov ebx, [esp+0x2C]
test ebx, ebx
je c_done
mov ecx, UNITS_STATE
call CAN_A_UNIT_CLIMB
push eax
push dword [MOUSE_Y]
push dword [MOUSE_X]
mov eax, ebp
imul eax, eax, 0x490
add eax, UNITS
push eax
call RULE_OK
test eax, eax
jne c_done
xor ebx, ebx
c_done:
jmp RESUME
]]

-- TribesState::giveTribeMoveInstruction, just after the target tile has passed the game's
-- own checks: ESI is the tribe's first unit (index * 0x490), EDI / EBP the target x / y.
-- A target the rule rules out leaves by the game's own "no" exit, so the troops are never
-- told to move and never start walking. Replays the two loads it replaces. A human
-- player's orders (no AI character: [player * 0x39F4 + PLAYER_AIC] == 0) follow the
-- player setting, the AI's the AI setting.
local tribe_move = [[
movsx eax, word [esi+UNITS+0x96]
imul eax, eax, 0x39F4
cmp dword [eax+PLAYER_AIC], 0
je t_human
cmp dword [AI_ENABLED], 0
je t_replay
jmp t_check
t_human:
cmp dword [TOP_ENABLED], 0
je t_replay
t_check:
movsx eax, word [esi+UNITS+0x360]
push eax
push ebp
push edi
lea eax, [esi+UNITS]
push eax
call RULE_OK
test eax, eax
je FAIL
t_replay:
mov eax, [esp+0x48]
mov ecx, [esp+0x10]
jmp RESUME
]]

return {
  rule_ok = rule_ok,
  cursor = cursor,
  tribe_move = tribe_move,
  detect = detect,
  cut_sides = cut_sides,
  prepare = prepare,
  chain_build = chain_build,
  two_legs = two_legs,
  route_ok = route_ok,
  passage_flag = passage_flag,
  restore = restore,
  path_search = path_search,
}
