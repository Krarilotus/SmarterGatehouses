"""Run smarter-gatehouses unmodified in the emulation harness against both exes."""
import os, sys, struct
BENCH = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(os.path.dirname(BENCH), 'module')
os.environ['TUNNELERS_MODULE'] = MODULE      # the harness reads the module from here
sys.path.insert(0, BENCH)
os.chdir(BENCH)
import harness
from harness import Host, SENTINEL, MASK

FAILS = []
class Stop(Exception):
    pass
def check(name, got, want):
    ok = got == want
    print('   %-58s %s   (got %s, want %s)' % (name, 'ok' if ok else 'FAIL', got, want))
    if not ok:
        FAILS.append(name)

AOB = {
 'detect': "0F BF 88 ? ? ? ? 8B 54 24 30 3B D1 7E 04 2B D1 EB 04 2B CA 8B D1 0F BF 80 ? ? ? ? 8B 4C 24 34",
 'pathcall': "0F BF 8E AA 06 00 00 8B 44 24 14 50 51 B9 ? ? ? ? E8 ? ? ? ?",
 'linkGates': "8B 4C 24 04 69 C9 2C 03 00 00 53 55 56 0F BF B1 ? ? ? ? 57 8B B9 ? ? ? ? 8B C7 99 2B C2 D1 F8 66 83 B9 ? ? ? ? 50",
 'doPath': "56 8B F1 8B 46 0C 8B 4E 14 8D 04 40 8B 04 85 ? ? ? ? 03 46 08 8D 0C 49 8B 0C 8D ? ? ? ? 03 4E 10 0F B7 14 45 ? ? ? ?",
 'teams': "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?",
 'tilemaps': "F7 04 8D ? ? ? ? 00 01 00 00 75 1F 0F BF 14 4D ? ? ? ? 69 D2 2C 03 00 00 0F BF 8A ? ? ? ? 83 3C 8D ? ? ? ? 00",
}
ROW0 = 90          # rows below this are not used by the little test world
GATE = 5
GX, GY = 100, 100


class World:
    def __init__(self, extreme, config):
        self.H = H = Host(extreme=extreme, config=config, texts=False)
        E = H.E
        f = lambda k: E.find(AOB[k])[0]
        self.detect = f('detect'); self.pathcall = f('pathcall'); self.link = f('linkGates')
        self.dopath = f('doPath')
        self.units = E.u32(self.detect + 3) - 0xB6
        self.bld = E.u32(self.link + 16) - 0xEE
        self.linkage = E.u32(self.link + 0x8E)
        self.row = E.u32(self.dopath + 15); self.area = E.u32(self.dopath + 39)
        self.teams = E.u32(f('teams') + 3)
        t = f('tilemaps')
        self.flags = E.u32(t + 3); self.bmap = E.u32(t + 17); self.got = E.u32(t + 37)
        self.pf = E.u32(self.pathcall + 14)
        for y in range(400):
            H.put32(self.row + y * 12, max(0, y - ROW0) * 400)
        H.put32(self.bld - 0xC, 10)
        for p in range(9):
            H.put32(self.teams + p * 4, p)
        self.calls = []
        H.cpu.hooks[self.dopath] = self.fake_search

    def tile(self, x, y):
        return (y - ROW0) * 400 + x

    def gate(self, size=5, kind=0x2D, owner=2, variation=0x50, state=0, held=0, bid=GATE, x=GX, y=GY):
        H = self.H
        b = self.bld + bid * 0x32C
        H.put16(b + 0xD0, 1); H.put16(b + 0xD2, kind); H.put16(b + 0xD6, owner)
        H.put16(b + 0xEE, x); H.put16(b + 0xF0, y); H.put32(b + 0xF8, size)
        H.put16(b + 0x102, variation); H.put8(b + 0x2A2, state); H.put16(b + 0x2C6, held)
        for j in range(size):
            for i in range(size):
                t = self.tile(x + i, y + j)
                H.put16(self.bmap + t * 2, bid)
                H.put32(self.flags + t * 4, 0x100)
        return b

    def lay(self, bid=GATE):
        self.H.run(self.link, regs={'ecx': self.pf}, stack=[bid])

    def links(self, x0=GX - 2, y0=GY - 2, n=9):
        return bytes(self.H.m.read(self.linkage + self.tile(x0, y0 + j), n)[i]
                     for j in range(n) for i in range(n))

    def link_at(self, x, y):
        return self.H.m.read(self.linkage + self.tile(x, y), 1)[0]

    def fake_search(self, cpu):
        args = [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(2)]
        self.calls.append(dict(ecx=cpu.r['ecx'], args=args, links=self.links(),
                               state=self.H.m.read(self.bld + GATE * 0x32C + 0x2A2, 1)[0]))
        cpu.r['eax'] = self.results.pop(0) if getattr(self, 'results', None) else 7
        cpu.eip = cpu.pop()
        cpu.r['esp'] = (cpu.r['esp'] + 8) & MASK

    def search(self, player, start, dest, in_passage=0):
        H = self.H
        unit = 0x50000000
        H.put16(unit + 0x6AA, player)
        H.put8(unit + 0x614 + 0x402, in_passage)
        H.put32(self.pf + 8, start[0]); H.put32(self.pf + 0xC, start[1])
        H.put32(self.pf + 0x10, dest[0]); H.put32(self.pf + 0x14, dest[1])
        self.calls.clear()
        regs = {'esi': unit, 'ebx': 0x1111, 'edi': 0x2222, 'ebp': 0x3333}
        # [esp+0x14] at the site is the flag handed on to the search
        cpu = H.run(self.pathcall, until=self.pathcall + 25, regs=regs,
                    stack=[0, 0, 0, 0, 0x55, 0])
        keep = (cpu.r['ebx'], cpu.r['edi'], cpu.r['ebp'], cpu.r['esi'])
        assert keep == (0x1111, 0x2222, 0x3333, unit), 'registers not preserved %r' % (keep,)
        assert cpu.r['esp'] == harness.STACK_TOP - 7 * 4, 'stack not balanced'
        # the first search is the rule's own; a stand-in route the rule then rejects may be
        # followed by more searches, which section 4 of test_stairs looks at
        assert len(self.calls) >= 1
        assert self.calls[0]['args'] == [player, 0x55] and self.calls[0]['ecx'] == self.pf
        return self.calls[0]

    def near(self, unit_micro, unit_tile, gate=GATE):
        """Run the patched distance test for one enemy unit. True = the gate sees him."""
        H = self.H
        uoff = 3 * 0x490
        u = self.units + uoff
        H.put16(u + 0xB6, unit_micro[0]); H.put16(u + 0xB8, unit_micro[1])
        H.put16(u + 0xC4, unit_tile[0]); H.put16(u + 0xC6, unit_tile[1])
        b = self.bld + gate * 0x32C
        bx = struct.unpack('<h', H.m.read(b + 0xEE, 2))[0]
        by = struct.unpack('<h', H.m.read(b + 0xF0, 2))[0]
        out = {}
        found = self.detect + 0x3C + H.m.read(self.detect + 0x3B, 1)[0]
        def stop(which):
            def hook(cpu):
                out['hit'] = which
                out['esp'] = cpu.r['esp']
                raise Stop()
            return hook
        H.cpu.hooks[found] = stop(True)
        H.cpu.hooks[self.detect + 0x3C] = stop(False)
        stack = [0] * 16
        stack[11] = bx * 8       # [esp+0x30] once the sentinel is on top
        stack[12] = by * 8       # [esp+0x34]
        regs = {'eax': uoff, 'edi': gate * 0x32C, 'ebx': gate, 'esi': 0x77, 'ebp': 0x88}
        try:
            H.run(self.detect, regs=regs, stack=stack)
        except Stop:
            pass
        cpu = H.cpu
        assert out['esp'] == harness.STACK_TOP - 17 * 4, 'stack not balanced'
        assert (cpu.r['ebx'], cpu.r['esi'], cpu.r['ebp'], cpu.r['edi']) == \
            (gate, 0x77, 0x88, gate * 0x32C), 'registers not preserved'
        return out['hit']


def cfg(enemy=True, centred=True, reach=True, stairs=False):
    return {'pathing': {'enemy_gates_closed': enemy},
            'detection': {'centred': centred, 'reachable_only': reach},
            'walls': {'stairs_needed': stairs}}


def run(extreme):
    print('=== %s' % ('Extreme' if extreme else 'vanilla'))
    IN, OUT1, OUT2 = (GX, GY + 2), (GX - 1, GY + 2), (GX + 5, GY + 2)

    print('1. enemy gatehouses count as shut during a search')
    W = World(extreme, cfg())
    for line in W.H.logs:
        print('   log:', line)
    W.gate(); W.lay()
    before = W.links()
    check('the game laid the entrance link (outside tile)', W.link_at(*OUT1) & 4, 4)
    check('the game laid the entrance link (gate tile)', W.link_at(*IN) & 0x40, 0x40)
    c = W.search(1, (50, 95), (60, 95))
    check('enemy: shut while searching', c['state'], 2)
    check('enemy: no way in while searching', (c['links'] == before, W.link_at(*OUT1)), (False, before[4 * 9 + 1]))
    check('enemy: everything back afterwards', W.links() == before, True)
    check('enemy: gate open again', W.H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0], 0)
    c = W.search(2, (50, 95), (60, 95))
    check('owner: untouched', (c['state'], c['links'] == before), (0, True))
    W.H.put32(W.teams + 4, 2)
    c = W.search(1, (50, 95), (60, 95))
    check('ally: untouched', (c['state'], c['links'] == before), (0, True))
    W.H.put32(W.teams + 4, 1)
    W.gate(held=1)
    c = W.search(1, (50, 95), (60, 95))
    check('captured gatehouse: untouched', (c['state'], c['links'] == before), (0, True))
    W.gate(state=1)
    c = W.search(1, (50, 95), (60, 95))
    check('closing gate: shut, then closing again',
          (c['state'], W.H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0]), (2, 1))
    W = World(extreme, cfg(enemy=False)); W.gate(); W.lay(); before = W.links()
    c = W.search(1, (50, 95), (60, 95))
    check('setting off: untouched', (c['state'], c['links'] == before), (0, True))

    print('2. stairs needed')
    W = World(extreme, cfg(enemy=False, stairs=True))
    W.gate(); W.lay()
    # a wall along the top edge of the gatehouse, linked to it the way the game links walls
    H = W.H
    for x in range(GX, GX + 5):
        t = W.tile(x, GY - 1)
        H.put32(W.flags + t * 4, 0x100)
        H.put8(W.linkage + t, 0x10 | 0x04 | 0x40 | 0x08 | 0x20)
        g = W.tile(x, GY)
        H.put8(W.linkage + g, H.m.read(W.linkage + g, 1)[0] | 0x01 | 0x02 | 0x80 | 0x04 | 0x10)
    before = W.links()
    WALL, ROOF, GROUND, FAR = (GX + 2, GY - 1), (GX + 3, GY + 1), (50, 95), (60, 95)
    def crossing(c):
        """Links across the footprint's edge, without the two entrance links."""
        wall = [c['links'][1 * 9 + 2 + i] & (0x10 | (0x08 if i < 4 else 0) | (0x20 if i > 0 else 0)) for i in range(5)]
        roof = [c['links'][2 * 9 + 2 + i] & (0x01 | 0x02 | 0x80) for i in range(5)]
        return any(wall) or any(roof)
    def entrance(c):
        return bool(c['links'][4 * 9 + 1] & 4) and bool(c['links'][4 * 9 + 2] & 0x40)
    c = W.search(2, GROUND, FAR)
    check('ground to ground: a passage, no way onto the walls', (c['state'], entrance(c), crossing(c)), (0, True, False))
    c = W.search(2, GROUND, WALL)
    check('ground to wall: gate open, no way onto the wall', (c['state'], entrance(c), crossing(c)), (0, True, False))
    check('   inside the roof links survive', c['links'][3 * 9 + 3], before[3 * 9 + 3])
    check('   everything back afterwards', W.links() == before, True)
    c = W.search(2, WALL, GROUND)
    check('wall to ground: the same', (c['state'], entrance(c), crossing(c)), (0, True, False))
    c = W.search(2, GROUND, ROOF)
    check('ground to roof: gate shut, walls still joined', (c['state'], entrance(c), crossing(c)), (2, False, True))
    c = W.search(2, ROOF, GROUND)
    check('roof to ground: gate shut', (c['state'], entrance(c), crossing(c)), (2, False, True))
    c = W.search(2, ROOF, WALL, in_passage=10)
    check('in the passage, to the wall: counts as ground', (c['state'], entrance(c), crossing(c)), (0, True, False))
    c = W.search(2, WALL, ROOF)
    check('wall to roof: gate shut, walls joined', (c['state'], entrance(c), crossing(c)), (2, False, True))
    check('everything back afterwards', (W.links() == before, W.H.m.read(W.bld + GATE * 0x32C + 0x2A2, 1)[0]), (True, 0))
    W2 = World(extreme, cfg(enemy=True, stairs=True)); W2.gate(); W2.lay(); before2 = W2.links()
    c = W2.search(1, GROUND, (GX + 2, GY - 2))
    check('enemy, both settings: shut', (c['state'], entrance(c)), (2, False))
    check('   and back', W2.links() == before2, True)

    print('3. when a gatehouse closes')
    cx, cy = GX * 8 + 20, GY * 8 + 20
    W = World(extreme, cfg(reach=False)); W.gate()
    check('centred: 199 to the right', W.near((cx + 199, cy), (0, 0)), True)
    check('centred: 200 to the right', W.near((cx + 200, cy), (0, 0)), False)
    check('centred: 199 to the left', W.near((cx - 199, cy), (0, 0)), True)
    check('centred: 200 to the left', W.near((cx - 200, cy), (0, 0)), False)
    check('centred: 199 down', W.near((cx, cy + 199), (0, 0)), True)
    check('centred: 200 up', W.near((cx, cy - 200), (0, 0)), False)
    W.gate(size=7)
    check('centred, large gatehouse: 199 from its middle', W.near((GX * 8 + 28 + 199, cy), (0, 0)), True)
    check('centred, large gatehouse: 200 from its middle', W.near((GX * 8 + 28 + 200, cy), (0, 0)), False)
    W = World(extreme, cfg(centred=False, reach=False)); W.gate()
    check('corner (as the game does it): 199', W.near((GX * 8 + 199, GY * 8), (0, 0)), True)
    check('corner: 200', W.near((GX * 8 + 200, GY * 8), (0, 0)), False)
    check('corner: -199', W.near((GX * 8 - 199, GY * 8 - 199), (0, 0)), True)

    W = World(extreme, cfg()); W.gate()
    H = W.H
    def area(x, y, a):
        H.put16(W.area + W.tile(x, y) * 2, a)
    area(*OUT1, 7); area(*OUT2, 8); area(GX + 2, GY + 2, 9)
    area(GX + 2, GY - 1, 11); area(GX + 2, GY + 5, 12)
    area(120, 100, 7); area(121, 100, 8); area(122, 100, 9); area(123, 100, 5)
    area(125, 100, 11); area(126, 100, 12)
    check('reachable: enemy on the ground outside', W.near((cx, cy), (120, 100)), True)
    check('reachable: enemy on the ground inside', W.near((cx, cy), (121, 100)), True)
    check('reachable: enemy on the walls joined to it', W.near((cx, cy), (122, 100)), True)
    check('reachable: enemy somewhere cut off', W.near((cx, cy), (123, 100)), False)
    check('reachable: enemy on unwalkable ground', W.near((cx, cy), (124, 100)), False)
    check('reachable: too far anyway', W.near((cx + 200, cy), (120, 100)), False)
    check('reachable: area beside the gate, not at an entrance', W.near((cx, cy), (125, 100)), False)
    W.gate(variation=0x51)
    check('turned gatehouse: its entrances are top and bottom', W.near((cx, cy), (125, 100)), True)
    check('turned gatehouse: other entrance', W.near((cx, cy), (126, 100)), True)
    check('turned gatehouse: the old entrance no longer counts', W.near((cx, cy), (120, 100)), False)
    W.gate(kind=0x2F)
    check('not a gatehouse: the game\'s own behaviour', W.near((cx, cy), (123, 100)), True)


for extreme in (False, True):
    run(extreme)
print()
print('FAILURES: %s' % ', '.join(FAILS) if FAILS else 'ALL OK')



