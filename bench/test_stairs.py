"""Stairs-needed orders, cursor and freeze guard, on both exes. Reuses test_gates' world."""
src = open(__file__.replace('test_stairs.py', 'test_gates.py'), encoding='utf-8-sig').read()
exec(src.split("for extreme in (False, True):")[0])


def _unit(self, uid, xy, owner=2, passage=0, climb=0):
    H = self.H
    u = self.units + uid * 0x490
    H.put16(u + 0x96, owner); H.put16(u + 0xC4, xy[0]); H.put16(u + 0xC6, xy[1])
    H.put8(u + 0x402, passage); H.put16(u + 0x360, climb)
    return u


def _area_set(self, x, y, a):
    self.H.put16(self.area + self.tile(x, y) * 2, a)


def _climb(self, cid, kind, bid, a, b, roof, owner=2, used=1, open_=1):
    H = self.H
    c = self.pf + 0x1084 + cid * 0x204
    H.put32(c + 0, used); H.put32(c + 4, kind); H.put32(c + 0xC, bid); H.put32(c + 0x18, open_)
    H.put32(c + 0x34, a); H.put32(c + 0x38, b); H.put32(c + 0x1E8, roof); H.put32(c + 0x1E4, owner)
    H.put16(self.bld + bid * 0x32C + 0x2D2, cid)
    H.put32(self.pf, max(H.u32(self.pf), cid + 1))


def _search2(self, uid, dest, results=None):
    """The wrapper for unit uid, standing where unit() put it. Returns every search call."""
    H = self.H
    u = self.units + uid * 0x490
    esi = u - 0x614
    x = struct.unpack('<h', H.m.read(u + 0xC4, 2))[0]
    y = struct.unpack('<h', H.m.read(u + 0xC6, 2))[0]
    H.put32(self.pf + 8, x); H.put32(self.pf + 0xC, y)
    H.put32(self.pf + 0x10, dest[0]); H.put32(self.pf + 0x14, dest[1])
    self.calls = []
    self.results = list(results or [])
    regs = {'esi': esi, 'ebx': 0x1111, 'edi': 0x2222, 'ebp': 0x3333}
    cpu = H.run(self.pathcall, until=self.pathcall + 25, regs=regs, stack=[0, 0, 0, 0, 0x55, 0])
    assert (cpu.r['ebx'], cpu.r['edi'], cpu.r['ebp'], cpu.r['esi']) == (0x1111, 0x2222, 0x3333, esi)
    assert cpu.r['esp'] == harness.STACK_TOP - 7 * 4, 'stack not balanced'
    return self.calls, cpu.r['eax']


CURSOR_AOB = ("B9 ? ? ? ? E8 ? ? ? ? 8B 0D ? ? ? ? 50 53 57 51 B9 ? ? ? ? E8 ? ? ? ? "
              "33 FF 85 C0 74 08 C7 44 24 2C 01 00 00 00 8B 5C 24 2C EB 02")
MOUSE_AOB = "8B 0D ? ? ? ? 8B 15 ? ? ? ? 51 52 55 B9 ? ? ? ? E8"
TRIBE_AOB = "89 44 24 3C 89 54 24 24 0F 85 ? ? ? ? 8B 44 24 48 8B 4C 24 10 C7 05 ? ? ? ? 00 00 00 00"


def _cursor(self, uid, mouse):
    """The patched cursor test: 1 = normal cursor, 0 = can't go there."""
    H = self.H; E = H.E
    site = E.find(CURSOR_AOB)[0]
    ms = E.find(MOUSE_AOB)[0]
    H.put32(E.u32(ms + 8), mouse[0]); H.put32(E.u32(ms + 2), mouse[1])
    climb_fn = (site + 10 + E.u32(site + 6)) & MASK
    def can_climb(cpu):
        cpu.r['eax'] = 0
        cpu.eip = cpu.pop()
    H.cpu.hooks[climb_fn] = can_climb
    stack = [0] * 16
    stack[10] = 1            # [esp+0x2C], the game's own answer
    cpu = H.run(site + 0x2C, until=site + 0x34, regs={'ebp': uid, 'edi': 0, 'esi': 0x44},
                stack=stack)
    assert (cpu.r['ebp'], cpu.r['edi'], cpu.r['esi']) == (uid, 0, 0x44)
    assert cpu.r['esp'] == harness.STACK_TOP - 17 * 4
    return cpu.r['ebx']


def _tribe(self, uid, target):
    """The patched move order: True = the order goes on, False = given up."""
    H = self.H; E = H.E
    site = E.find(TRIBE_AOB)[0]
    fail = (site + 14 + E.u32(site + 10)) & MASK
    out = {}
    def gave_up(cpu):
        out['esp'] = cpu.r['esp']
        raise Stop()
    H.cpu.hooks[fail] = gave_up
    stack = [0] * 24
    stack[3] = 0xAAAA         # [esp+0x10]
    stack[17] = 0xBBBB        # [esp+0x48]
    try:
        cpu = H.run(site + 14, until=site + 22,
                    regs={'esi': uid * 0x490, 'edi': target[0], 'ebp': target[1]}, stack=stack)
    except Stop:
        assert out['esp'] == harness.STACK_TOP - 25 * 4
        return False
    assert (cpu.r['eax'], cpu.r['ecx']) == (0xBBBB, 0xAAAA), 'replayed loads'
    return True


World.unit = _unit; World.area_set = _area_set; World.climb = _climb
World.search2 = _search2; World.cursor = _cursor; World.tribe = _tribe


def section4(extreme):
    print('=== %s' % ('Extreme' if extreme else 'vanilla'))
    print('4. stairs needed: orders, the cursor, no frozen units')
    W = World(extreme, cfg(enemy=False, stairs=True))
    print('   log:', W.H.logs[-1])
    W.gate(); W.lay()
    H = W.H
    # ground outside is area 1, inside area 3, the walls and the gatehouse area 2
    for x, y in [(50, 95), (60, 95), (GX - 1, GY + 2)]:
        W.area_set(x, y, 1)
    W.area_set(GX + 5, GY + 2, 3)
    for j in range(5):
        for i in range(5):
            W.area_set(GX + i, GY + j, 2)
    WALL = (GX + 2, GY - 1)
    H.put32(W.flags + W.tile(*WALL) * 4, 0x100); W.area_set(*WALL, 2)
    W.climb(1, 4, GATE, 1, 3, 2)
    H.put8(W.linkage + W.tile(*WALL), 0x10)
    H.put8(W.linkage + W.tile(GX + 2, GY), W.link_at(GX + 2, GY) | 0x01)
    before = W.links()
    roof = lambda: H.u32(W.pf + 0x1084 + 0x204 + 0x1E8)

    W.unit(3, (50, 95))
    calls, eax = W.search2(3, WALL)
    check('no stairs, ground to wall: the game\'s own search, once',
          (len(calls), calls[0]['links'] == before, eax), (1, True, 7))
    check('   the roof is back in the climb entry', roof(), 2)
    check('   cursor: can\'t go there', W.cursor(3, WALL), 0)
    check('   move order given up', W.tribe(3, WALL), False)
    aic = H.E.u32(H.E.find('69 C0 F4 39 00 00 8B 88 ? ? ? ? 69 C9 A4 02 00 00')[0] + 8)
    H.put32(aic + 2 * 0x39F4, 5)
    check('   ... unless it is an AI player''s', W.tribe(3, WALL), True)
    H.put32(aic + 2 * 0x39F4, 0)
    check('   cursor on the ground: fine', W.cursor(3, (60, 95)), 1)
    check('   move order on the ground: goes ahead', W.tribe(3, (60, 95)), True)
    check('   cursor inside the castle, through the gate: fine', W.cursor(3, (GX + 5, GY + 2)), 1)

    W.unit(4, (GX + 2, GY + 2), passage=10)
    check('in the passage, to the wall: cursor refuses', W.cursor(4, WALL), 0)
    check('in the passage, to the ground: fine', W.cursor(4, (60, 95)), 1)
    W.unit(5, WALL)
    check('on the wall, to the ground: cursor refuses', W.cursor(5, (60, 95)), 0)
    check('on the wall, along the wall: fine', W.cursor(5, (GX + 2, GY + 1)), 1)
    W.unit(6, (GX + 2, GY + 1))
    check('on the roof, not the passage, to the wall: fine', W.cursor(6, WALL), 1)

    # stairs: the wall's area is the outside ground's
    W.area_set(*WALL, 1)
    calls, eax = W.search2(3, WALL)
    check('stairs outside: the rule\'s search, sides cut',
          (len(calls), calls[0]['links'] == before, eax), (1, False, 7))
    check('   cursor fine', W.cursor(3, WALL), 1)
    calls, eax = W.search2(3, WALL, results=[0, 9])
    check('rule\'s search fails anyway: searched again the game\'s way',
          (len(calls), calls[0]['links'] == before, calls[1]['links'] == before, eax),
          (2, False, True, 9))
    check('   everything back afterwards', (W.links() == before, roof()), (True, 2))

    W.area_set(*WALL, 3)
    check('stairs only inside: reachable through the gate', W.cursor(3, WALL), 1)
    W.climb(1, 4, GATE, 1, 3, 2, owner=1)
    check('   ... not through an enemy gate', W.cursor(3, WALL), 0)
    W = World(extreme, cfg(enemy=False, stairs=False))
    check('setting off: no cursor or order hooks', W.H.logs[-1].endswith('1 place(s) in the game changed.'), True)


for extreme in (False, True):
    section4(extreme)

def section5(extreme):
    import random
    print('5. passages below, roofs on top')
    W = World(extreme, cfg(enemy=False, stairs=True))
    W.gate(); W.lay()
    H = W.H
    other = W.gate(bid=6, x=140, y=100)
    W.lay(6)
    for x, y in [(50, 95), (60, 95), (GX - 1, GY + 2)]:
        W.area_set(x, y, 1)
    W.area_set(GX + 5, GY + 2, 3)
    for j in range(5):
        for i in range(5):
            W.area_set(GX + i, GY + j, 3)
    WALL = (GX + 2, GY - 1)
    H.put32(W.flags + W.tile(*WALL) * 4, 0x100); W.area_set(*WALL, 3)
    W.climb(1, 4, GATE, 1, 3, 3)
    W.climb(2, 4, 6, 3, 3, 3)
    seen = {}
    def fake(cpu):
        seen['g5'] = H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0]
        seen['g6'] = H.m.read(W.bld + 6 * 0x32C + 0x2A2, 1)[0]
        seen['links'] = W.links()
        W.fake_search(cpu)
    H.cpu.hooks[W.dopath] = fake
    H.put8(W.linkage + W.tile(*WALL), 0x10)
    H.put8(W.linkage + W.tile(GX + 2, GY), W.link_at(GX + 2, GY) | 0x01)
    before = W.links()
    W.unit(3, (50, 95))
    calls, eax = W.search2(3, WALL)
    cross = lambda l: bool(l[1 * 9 + 4] & 0x10) or bool(l[2 * 9 + 4] & 0x01)
    ent = lambda l: bool(l[4 * 9 + 1] & 4) and bool(l[4 * 9 + 2] & 0x40)
    check('outside, stairs inside: its gatehouse is a passage',
          (seen['g5'], ent(seen['links']), cross(seen['links'])), (0, True, False))
    check('   the gatehouse inside is a roof', seen['g6'], 2)
    check('   everything back', (W.links() == before, H.m.read(W.bld + 6 * 0x32C + 0x2A2, 1)[0]), (True, 0))
    W.unit(4, (GX + 5, GY + 2))
    W.search2(4, WALL)
    check('inside, stairs inside: no gatehouse needed, both roofs',
          (seen['g5'], seen['g6'], cross(seen['links'])), (2, 2, True))
    W.unit(5, (GX + 2, GY + 1))
    W.search2(5, (60, 95))
    # (a unit going down from a roof is tested with real routes in section 6)
    W.unit(7, (60, 95))
    W.search2(7, (50, 95))
    check('ground to ground: every gatehouse a passage',
          (seen['g5'], seen['g6'], ent(seen['links']), cross(seen['links'])), (0, 0, True, False))

    # the table-driven cut clears exactly what crosses the footprint's edge
    rnd = random.Random(7)
    for j in range(-2, 7):
        for i in range(-2, 7):
            H.put8(W.linkage + W.tile(GX + i, GY + j), rnd.randrange(256))
    before = W.links()
    W.search2(7, (50, 95))
    dirs = [(-1, -1, 0x80), (0, -1, 1), (1, -1, 2), (1, 0, 4), (1, 1, 8), (0, 1, 0x10), (-1, 1, 0x20), (-1, 0, 0x40)]
    inside = lambda i, j: 0 <= i < 5 and 0 <= j < 5
    want = bytearray(before)
    for j in range(-1, 6):
        for i in range(-1, 6):
            k = (j + 2) * 9 + (i + 2)
            for dx, dy, bit in dirs:
                if inside(i, j) != inside(i + dx, j + dy):
                    want[k] &= ~bit & 0xFF
    want[4 * 9 + 1] |= 4
    want[4 * 9 + 2] |= 0x40
    want[4 * 9 + 6] |= 4
    want[4 * 9 + 7] |= 0x40
    diff = [k for k in range(81) if want[k] != seen['links'][k]]
    check('the cut matches, tile for tile', [(k, hex(want[k]), hex(seen['links'][k]), hex(before[k])) for k in diff], [])
    check('   and is undone', W.links() == before, True)


for extreme in (False, True):
    section5(extreme)

DIRS = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

def planner(W, log):
    """A stand-in search that walks straight at the target and writes a real route."""
    H = W.H
    def fake(cpu):
        pf = W.pf
        sx, sy, dx, dy = (struct.unpack('<i', H.m.read(pf + o, 4))[0] for o in (8, 0xC, 0x10, 0x14))
        buf = H.u32(pf + 0x1BB38)
        x, y, steps = sx, sy, []
        while (x, y) != (dx, dy):
            d = ((dx > x) - (dx < x), (dy > y) - (dy < y))
            steps.append(DIRS.index(d)); x += d[0]; y += d[1]
        for i, st in enumerate(steps):
            b = H.m.read(buf + i // 2, 1)[0]
            b = (b & 0xF0 | st) if i % 2 == 0 else (b & 0x0F | st << 4)
            H.put8(buf + i // 2, b)
        log.append(dict(start=(sx, sy), dest=(dx, dy), g5=H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0],
                        links=W.links()))
        r = len(steps)
        if W.results:
            r = W.results.pop(0)
        H.put32(pf + 0x1BB3C, r)
        cpu.r['eax'] = r
        cpu.eip = cpu.pop()
        cpu.r['esp'] = (cpu.r['esp'] + 8) & MASK
    return fake

def walk(W, start, n):
    buf = W.H.u32(W.pf + 0x1BB38)
    x, y = start
    for i in range(n):
        b = W.H.m.read(buf + i // 2, 1)[0]
        st = (b & 0xF) if i % 2 == 0 else (b >> 4)
        x += DIRS[st][0]; y += DIRS[st][1]
    return (x, y)

def section6(extreme):
    print('6. onto a gatehouse by the stairs; the AI switch')
    for ai_on in (False, True):
        W = World(extreme, cfg(enemy=False, stairs=True) | {'walls': {'stairs_needed': True, 'stairs_needed_ai': ai_on}})
        W.gate(); W.lay()
        H = W.H
        H.put32(W.pf + 0x1BB38, 0x51000000)
        for x, y in [(50, 95), (60, 95), (GX - 1, GY + 2)]:
            W.area_set(x, y, 1)
        W.area_set(GX + 5, GY + 2, 3)
        for j in range(5):
            for i in range(5):
                W.area_set(GX + i, GY + j, 3)
        W.climb(1, 4, GATE, 1, 3, 3)
        H.put8(W.linkage + W.tile(GX + 2, GY - 1), 0x10)
        H.put32(W.flags + W.tile(GX + 2, GY - 1) * 4, 0x100); W.area_set(GX + 2, GY - 1, 3)
        H.put8(W.linkage + W.tile(GX + 2, GY), W.link_at(GX + 2, GY) | 0x01)
        before = W.links()
        log = []
        H.cpu.hooks[W.dopath] = planner(W, log)
        ROOF = (GX + 2, GY + 1)
        IN, OUT = (GX + 5, GY + 2), (GX - 1, GY + 2)
        cross = lambda l: bool(l[1 * 9 + 4] & 0x10) or bool(l[2 * 9 + 4] & 0x01)
        ent = lambda l: bool(l[4 * 9 + 1] & 4) and bool(l[4 * 9 + 2] & 0x40)
        if not ai_on:
            W.unit(3, (50, 95))
            log.clear(); calls, eax = W.search2(3, ROOF)
            check('outside, onto the roof: two legs', [(c['start'], c['dest']) for c in log],
                  [((50, 95), IN), (IN, ROOF)])
            check('   first through it (passage)', (log[0]['g5'], ent(log[0]['links']), cross(log[0]['links'])), (0, True, False))
            check('   then up the stairs and onto it (roof)', (log[1]['g5'], ent(log[1]['links']), cross(log[1]['links'])), (2, False, True))
            check('   one joined route, ending on the roof', (eax, walk(W, (50, 95), eax)), (55 + 3, ROOF))
            check('   everything back', (W.links() == before, H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0], H.u32(W.pf + 8), H.u32(W.pf + 0x10)), (True, 0, 50, ROOF[0]))
            W.unit(4, ROOF)
            log.clear(); calls, eax = W.search2(4, (60, 95))
            check('roof down to outside: two legs', [(c['start'], c['dest']) for c in log], [(ROOF, IN), (IN, (60, 95))])
            check('   first off the roof by the stairs (roof)', (log[0]['g5'], ent(log[0]['links'])), (2, False))
            check('   then out through it (passage)', (log[1]['g5'], ent(log[1]['links']), cross(log[1]['links'])), (0, True, False))
            check('   joined', walk(W, ROOF, eax), (60, 95))
            log.clear(); calls, eax = W.search2(3, ROOF, results=[5])
            check('first leg misses its entrance: the game\'s search instead', (len(log), log[-1]['links'] == before, eax), (2, True, 52))
            # the quick second click: in the passage already, then onto the roof
            u = W.unit(8, (GX + 2, GY + 2), passage=10)
            log.clear(); calls, eax = W.search2(8, ROOF)
            check('in the passage, onto its roof: out, up the stairs, onto it',
                  [(c['start'], c['dest']) for c in log], [((GX + 2, GY + 2), IN), (IN, ROOF)])
            check('   joined', walk(W, (GX + 2, GY + 2), eax), ROOF)
            H.put16(u + 0xF6, 2)
            log.clear(); calls, eax = W.search2(8, ROOF, results=[0])
            check('   if that fails, the game\'s route up the doors is refused', eax, 0)
            check('   and the unit stops where it is, not frozen mid-stride',
                  (H.m.read(u + 0xF6, 2), struct.unpack('<hh', H.m.read(u + 0xC8, 4)), struct.unpack('<hh', H.m.read(u + 0xEC, 4))),
                  (b'\x00\x00', (GX + 2, GY + 2), (GX + 2, GY + 2)))
            W.unit(9, (50, 95))
            log.clear(); calls, eax = W.search2(9, (60, 95), results=[0])
            check('   a fallback route that stays on the ground is kept', (len(log), eax), (2, 10))
        # an AI player's unit
        aic = H.E.u32(H.E.find('69 C0 F4 39 00 00 8B 88 ? ? ? ? 69 C9 A4 02 00 00')[0] + 8)
        H.put32(aic + 2 * 0x39F4, 5)
        W.unit(3, (50, 95))
        log.clear(); calls, eax = W.search2(3, (60, 95))
        check('AI unit, AI switch %s' % ('on' if ai_on else 'off'), (len(log), cross(log[0]['links'])),
              (1, False) if ai_on else (1, True))


for extreme in (False, True):
    section6(extreme)

FLAG_AOB = ("85 FF 74 4F 8B B0 ? ? ? ? 8B 14 B5 ? ? ? ? F7 C2 00 01 00 00 0F BF 0C 75 "
            "? ? ? ? 74 0E F6 C2 02 75 09 C6 80 ? ? ? ? 00 EB 24")

def flag(W, uid, tile_xy, prev_xy, prev_state, byte402, owner=2):
    H = W.H; E = H.E
    site = E.find(FLAG_AOB)[0]
    u = W.units + uid * 0x490
    H.put16(u + 0x96, owner)
    H.put32(u + 0xD4, W.tile(*tile_xy)); H.put32(u + 0x404, W.tile(*prev_xy))
    H.put16(u + 0x308, prev_state); H.put8(u + 0x402, byte402)
    H.put32(u + 0xD8, 0x1234)
    out = {}
    def stop(which):
        def hook(cpu):
            out['where'] = which; out['esi'] = cpu.r['esi']
            out['keep'] = (cpu.r['ebx'], cpu.r['ebp'], cpu.r['edi'], cpu.r['eax'], cpu.r['esp'])
            raise Stop()
        return hook
    H.cpu.hooks[site + 4 + 0x4F] = stop('done')
    H.cpu.hooks[site + 10] = stop('game')
    try:
        H.run(site + 4, regs={'eax': uid * 0x490, 'edi': 0xA, 'ebx': 0x11, 'ebp': 0x22})
    except Stop:
        pass
    assert out['keep'] == (0x11, 0x22, 0xA, uid * 0x490, harness.STACK_TOP - 4), out['keep']
    if out['where'] == 'game':
        assert out['esi'] == 0x1234
        return 'game'
    return H.m.read(u + 0x402, 1)[0]

def section7(extreme):
    print('7. in the passage or on the roof, by how the unit got on')
    W = World(extreme, cfg(enemy=False, stairs=True))
    W.gate()
    check('stepped in from the entrance: passage', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 0xA)
    check('stepped in from the far entrance: passage', flag(W, 3, (GX + 4, GY + 2), (GX + 5, GY + 2), 0, 0), 0xA)
    check('already in the passage: stays there, wherever it is going', flag(W, 3, (GX + 2, GY + 1), (GX + 2, GY + 2), 3, 7), 0xA)
    check('came off a wall: roof', flag(W, 3, (GX + 2, GY), (GX + 2, GY - 1), 1, 0), 0)
    check('came off a wall onto a passage tile: still roof', flag(W, 3, (GX, GY + 2), (GX, GY + 1), 1, 0), 0)
    check('walking about on the roof: roof', flag(W, 3, (GX + 1, GY + 1), (GX + 1, GY), 3, 0), 0)
    W.gate(variation=0x51)
    check('turned gatehouse, in from its entrance: passage', flag(W, 3, (GX + 2, GY), (GX + 2, GY - 1), 0, 0), 0xA)
    check('turned gatehouse, from the side: roof', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 0)
    W.gate(kind=0x2F)
    check('not a gatehouse: the game decides', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 'game')
    W.gate()
    aic = W.H.E.u32(W.H.E.find('69 C0 F4 39 00 00 8B 88 ? ? ? ? 69 C9 A4 02 00 00')[0] + 8)
    W.H.put32(aic + 2 * 0x39F4, 5)
    check('an AI unit with the AI switch off: the game decides', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 'game')
    W = World(extreme, cfg(enemy=False, stairs=False) | {'walls': {'stairs_needed': False, 'stairs_needed_ai': True}})
    W.gate()
    W.H.put32(aic + 2 * 0x39F4, 5)
    check('an AI unit with the AI switch on: decided here', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 0xA)
    W.H.put32(aic + 2 * 0x39F4, 0)
    check('   and a player\'s unit then: the game decides', flag(W, 3, (GX, GY + 2), (GX - 1, GY + 2), 0, 0), 'game')


for extreme in (False, True):
    section7(extreme)
print()
print('FAILURES: %s' % ', '.join(FAILS) if FAILS else 'ALL OK')
