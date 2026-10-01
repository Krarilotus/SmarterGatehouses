"""Run improved-tunnelers under Lua 5.4 with core mocked onto an emulated 32 bit address
space holding the real exe image, assemble its scripts with UCP's own fasm.dll, and then
execute the injected code in the x86 interpreter.

Nothing here is a stand-in for the module: the module's own init.lua and templates.lua are
loaded unchanged.
"""
import os, sys, struct
import lupa.lua54 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\autosave\py')
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\perf')

from shc import Exe, G
from x86emu_t import Memory, CPU, MASK
from host import fasm, ucp_source

MODULE = os.environ.get('TUNNELERS_MODULE',
                        r'H:\shc-modding\improved-tunnelers\module')
VAN_PATH = G + r'\Stronghold Crusader.exe'
EXT_PATH = G + r'\Stronghold_Crusader_Extreme.exe'
HEAP = 0x60000000
STACK_TOP = 0x70100000
SENTINEL = 0x7FFFFFF0
_EXES = {}


def exe(path):
    if path not in _EXES:
        _EXES[path] = Exe(path)
    return _EXES[path]


class Host:
    def __init__(self, extreme=False, config=None, texts=True):
        self.E = exe(EXT_PATH if extreme else VAN_PATH)
        self.extreme = extreme
        self.m = Memory(self.image)
        self.cpu = CPU(self.m)
        self.cpu.hooks = {}
        self.heap = HEAP
        self.logs = []
        self.patched = []
        self.detours = []

        lua = self.lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)
        g = lua.globals()
        g[b'INFO'], g[b'WARNING'], g[b'ERROR'] = b'INFO', b'WARNING', b'ERROR'
        g[b'log'] = lambda level, message: self.logs.append(
            '%s: %s' % (level.decode('latin-1'), message.decode('latin-1')))
        data = lua.table()
        version = lua.table()
        version[b'isExtreme'] = lambda *a: self.extreme
        data[b'version'] = version
        g[b'data'] = data

        c = lua.table()
        c[b'AOBScan'] = self.scan
        c[b'scanForAOB'] = self.scan
        c[b'readInteger'] = lambda a: self.m.s32(int(a))
        c[b'readSmallInteger'] = lambda a: struct.unpack('<h', self.m.read(int(a), 2))[0]
        c[b'readByte'] = lambda a: struct.unpack('<b', self.m.read(int(a), 1))[0]
        c[b'readBytes'] = lambda a, n: lua.table_from(list(self.m.read(int(a), int(n))))
        # The game's own code and data sit in a read-only image in the running game: only
        # the writeCode* calls may touch them, and a plain write there is an access
        # violation the moment the module is enabled. The bench has no page protection of
        # its own, so it says so here instead.
        def data_only(name, write):
            def guarded(a, v=None):
                if int(a) < HEAP:
                    raise AssertionError(
                        '%s wrote to the game image at %08X - use the writeCode* call'
                        % (name, int(a)))
                return write(a, v) if v is not None else write(a)
            return guarded

        c[b'writeInteger'] = data_only(
            'writeInteger', lambda a, v: self.m.put32(int(a), int(v)))
        c[b'writeByte'] = data_only(
            'writeByte', lambda a, v: self.m.write(int(a), bytes([int(v) & 0xFF])))
        c[b'writeBytes'] = data_only('writeBytes', self.write_bytes)
        c[b'writeCode'] = self.write_bytes
        c[b'writeCodeByte'] = self.write_code_byte
        c[b'writeCodeBytes'] = self.write_bytes
        c[b'writeCodeInteger'] = lambda a, v: self.m.put32(int(a), int(v))
        c[b'allocate'] = self.allocate
        c[b'allocateCode'] = self.allocate_code
        c[b'allocateAssembly'] = self.allocate_assembly
        c[b'detourCode'] = self.detour
        c[b'itob'] = lambda v: lua.table_from(list(struct.pack('<I', int(v) & MASK)))
        c[b'getRelativeAddress'] = lambda f, t, o=0: (int(t) - int(f) + int(o)) & MASK
        g[b'core'] = c

        lua.execute(('package.path = [[%s\\?.lua;]] .. package.path' % MODULE).encode('mbcs'))
        self.texts = []
        if texts:
            registry = lua.table()
            trm = lua.table()
            trm[b'SetText'] = lambda _self, group, index, text: self.texts.append(
                (int(group), int(index),
                 text.decode('latin-1') if isinstance(text, bytes) else text))
            registry[b'textResourceModifier'] = trm
            g[b'modules'] = registry

        self.mod = lua.eval(b'dofile')((MODULE + r'\init.lua').encode('mbcs'))
        self.mod[b'enable'](self.mod, self.to_lua(config or {}))

    # ---- lua helpers ----------------------------------------------------------------
    def to_lua(self, value):
        if isinstance(value, dict):
            t = self.lua.table()
            for k, v in value.items():
                t[k.encode()] = self.to_lua(v)
            return t
        return value

    # ---- core mocks -----------------------------------------------------------------
    def image(self, base):
        E = self.E
        if base == 0x400000:
            return bytes(E.data[:4096])
        for vs, vsz, po, rsz, _ in E.secs:
            if vs <= base < vs + max(vsz, rsz):
                page = bytearray(4096)
                for i in range(4096):
                    va = base + i
                    if vs <= va < vs + rsz:
                        page[i] = E.data[po + va - vs]
                return bytes(page)
        return None

    def scan(self, pattern, *rest):
        pattern = pattern.decode('latin-1') if isinstance(pattern, bytes) else pattern
        hits = [h for h in self.E.find(pattern) if h is not None]
        if not hits:
            raise lupa.LuaError('AOBScan: no match')
        return hits[0]

    def flatten(self, table):
        out = []

        def walk(t):
            for i in range(1, len(t) + 1):
                v = t[i]
                if lupa.lua_type(v) == 'table':
                    walk(v)
                else:
                    out.append(int(v) & 0xFF)
        if lupa.lua_type(table) == 'table':
            walk(table)
        else:
            out = [int(v) & 0xFF for v in table]
        return bytes(out)

    def write_bytes(self, address, values, *rest):
        data = self.flatten(values)
        self.patched.append((int(address), data))
        self.m.write(int(address), data)

    def write_code_byte(self, address, value):
        self.patched.append((int(address), bytes([int(value) & 0xFF])))
        self.m.write(int(address), bytes([int(value) & 0xFF]))

    def allocate(self, size, zero=None):
        address = self.heap
        self.heap = (self.heap + int(size) + 0x1F) & ~0xF
        self.m.write(address, b'\0' * int(size))
        return address

    def allocate_code(self, data):
        if isinstance(data, (int, float)):
            return self.allocate(int(data))
        values = self.flatten(data)
        address = self.allocate(len(values))
        self.m.write(address, values)
        return address

    def detour(self, fn, address, size):
        """UCP's lua detour: a call to `address` runs fn(registers) and returns."""
        address = int(address)
        self.detours.append(address)

        def hook(cpu):
            regs = self.lua.table()
            for name, value in cpu.r.items():
                regs[name.upper().encode()] = value
            out = fn(regs)
            if out is not None:
                for name in list(cpu.r):
                    v = out[name.upper().encode()]
                    if v is not None:
                        cpu.r[name] = int(v) & MASK
            cpu.eip = cpu.pop()
        self.cpu.hooks[address] = hook

    def allocate_assembly(self, script, values):
        script = script.decode('latin-1')
        values = {k.decode('latin-1'): int(v) & MASK for k, v in values.items()}
        try:
            size = len(fasm(ucp_source(script, values, 0)))
        except Exception as problem:            # say which script it was
            head = ' / '.join(script.strip().splitlines()[:3])
            with open('failed_script.asm', 'w', newline='\n') as f:
                f.write(ucp_source(script, values, 0))
            raise AssertionError('%s --- while assembling: %s' % (problem, head))
        address = self.allocate(size)
        code = fasm(ucp_source(script, values, address))
        assert len(code) == size, 'fasm size differs between passes'
        self.m.write(address, code)
        return address

    # ---- driving the emulator --------------------------------------------------------
    def run(self, start, until=SENTINEL, regs=None, stack=(), limit=5_000_000):
        cpu = self.cpu
        cpu.r['esp'] = STACK_TOP
        for value in reversed(stack):
            cpu.push(int(value) & MASK)
        cpu.push(SENTINEL)
        for name, value in (regs or {}).items():
            cpu.r[name] = int(value) & MASK
        cpu.eip = start
        cpu.run(until, limit)
        return cpu

    def stub(self, address, result=0, ret_bytes=0, record=None):
        """Replace a game function with one that returns `result`."""
        def hook(cpu):
            if record is not None:
                args = [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(6)]
                record.append((cpu.r['ecx'], args))
            cpu.r['eax'] = result & MASK
            cpu.eip = cpu.pop()
            cpu.r['esp'] = (cpu.r['esp'] + ret_bytes) & MASK
        self.cpu.hooks[address] = hook

    # ---- convenience ------------------------------------------------------------------
    def find(self, pattern):
        return self.scan(pattern)

    def u32(self, a):
        return self.m.u32(a)

    def put32(self, a, v):
        self.m.put32(a, v)

    def put16(self, a, v):
        self.m.write(a, struct.pack('<H', v & 0xFFFF))

    def put8(self, a, v):
        self.m.write(a, bytes([v & 0xFF]))
