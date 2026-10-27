import sys, struct
from minidump.minidumpfile import MinidumpFile
mf = MinidumpFile.parse(sys.argv[1])
r = mf.get_reader()
mods = sorted(((m.baseaddress, m.baseaddress + m.size, m.name.replace(chr(92), '/').split('/')[-1]) for m in mf.modules.modules))
def where(a):
    for lo, hi, n in mods:
        if lo <= a < hi:
            return f"{n}+0x{a-lo:X}"
    return f"0x{a:X}"
exc = mf.exception.exception_records[0]
er = exc.ExceptionRecord
print("code", er.ExceptionCode, "at", where(er.ExceptionAddress), "thread", exc.ThreadId)
print("params", [hex(x) for x in er.ExceptionInformation[:er.NumberParameters]])
th = [t for t in mf.threads.threads if t.ThreadId == exc.ThreadId][0]
ctx = exc.ContextRecord if hasattr(exc,'ContextRecord') else None
# read raw context for the faulting thread from the exception stream
from minidump.streams.ContextStream import CONTEXT
rd = mf.file_handle
rd.seek(exc.ThreadContext.Rva)
c = CONTEXT.parse(rd)
print("RIP", where(c.Rip), "RSP", hex(c.Rsp), "RCX", hex(c.Rcx), "RDX", hex(c.Rdx), "RAX", hex(c.Rax))
# scan the stack for return addresses inside interesting modules
base = c.Rsp
data = r.read(base, 0x800)
hits = []
for off in range(0, len(data) - 8, 8):
    v = struct.unpack_from('<Q', data, off)[0]
    w = where(v)
    if not w.startswith('0x') and not w.startswith(('ntdll', 'KERNEL', 'ucrtbase', 'msvcp', 'VCRUNTIME')):
        hits.append(w)
print("stack (return-address candidates):")
for h in hits[:40]:
    print("  ", h)
for lo, hi, n in mods:
    if n.lower() in ('cyberpunkmp.dll', 'red4ext.dll', 'codeware.dll', 'archivexl.dll', 'tweakxl.dll', 'cyber_engine_tweaks.asi', 'input_loader.dll', 'cyberpunk2077.exe'):
        print(f"module {n} base 0x{lo:X}")
