"""Read Mach-O bytes and otool text. Never load or execute the target."""
from pathlib import Path
import struct, re, json, hashlib, csv, os, argparse

cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument('--app',default=os.environ.get('APP_PATH','/Applications/Typora.app'))
cli.add_argument('--output',default='.local/native')
args=cli.parse_args()
ROOT=Path(args.output).resolve()
APP=Path(args.app).resolve()

class MachO:
    def __init__(self, path):
        self.path = path
        self.data = path.read_bytes()
        self.offset = 0
        if self.data[:4] == b'\xca\xfe\xba\xbe':
            count = struct.unpack_from('>I', self.data, 4)[0]
            for i in range(count):
                cpu, subtype, offset, size, align = struct.unpack_from('>IIIII', self.data, 8 + i * 20)
                if cpu == 0x100000c:
                    self.offset = offset
                    break
        magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', self.data, self.offset)
        assert magic == 0xfeedfacf, 'Expected little-endian Mach-O 64'
        self.segments = []
        self.commands = []
        p = self.offset + 32
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', self.data, p)
            if cmd == 0x19:
                name = self.data[p+8:p+24].split(b'\0')[0].decode()
                vm, vmsize, off, filesize = struct.unpack_from('<QQQQ', self.data, p+24)
                self.segments.append(dict(name=name,vm=vm,vmsize=vmsize,offset=self.offset+off,size=filesize))
            self.commands.append(dict(command=hex(cmd),offset=p,length=length))
            p += length

    def file_offset(self, address):
        for seg in self.segments:
            if seg['vm'] <= address < seg['vm'] + seg['size']:
                return seg['offset'] + address - seg['vm']
        return None

    def string(self, address):
        p = self.file_offset(address)
        if p is None: return None
        end = self.data.find(b'\0', p, min(len(self.data),p+8192))
        if end < 0: return None
        try: return self.data[p:end].decode('utf-8')
        except UnicodeDecodeError: return None

    def cfstring(self, address):
        p = self.file_offset(address)
        if p is None or p+32 > len(self.data): return None
        isa, flags, ptr, length = struct.unpack_from('<QQQQ',self.data,p)
        if length > 8192: return None
        start = self.file_offset(ptr)
        if start is None: return None
        try:
            if flags & 0x10:
                value = self.data[start:start+length*2].decode('utf-16-le')
            else:
                value = self.data[start:start+length].decode('utf-8')
            return dict(value=value,vm_address=hex(address),file_offset=p,string_vm=hex(ptr),string_file_offset=start,length=length,flags=hex(flags))
        except UnicodeDecodeError: return None

def parse_objc(text):
    classes=[]; methods=[]
    # Class references are imports, not definitions. Restrict class definitions to classlist.
    sections = re.split(r'^Contents of ',text,flags=re.M)
    for sec in sections:
        if sec.startswith('(__DATA_CONST,__objc_classlist) section') or sec.startswith('(__DATA,__objc_classlist) section'):
            blocks=re.split(r'(?=^[0-9a-f]{16} 0x[0-9a-f]+ _OBJC_CLASS_\$_)',sec,flags=re.M)
            for b in blocks:
                m=re.match(r'^([0-9a-f]{16}) (0x[0-9a-f]+) _OBJC_CLASS_\$_(.+)',b)
                if not m: continue
                sm=re.search(r'^    superclass\s+(0x[0-9a-f]+)(?: _OBJC_CLASS_\$_([^\n]+))?',b,re.M)
                classes.append(dict(name=m[3],class_address=m[2],list_address='0x'+m[1],superclass=sm[2] if sm else None))
    for i,line in enumerate(text.splitlines(),1):
        m=re.match(r'\s+imp\s+.*\((0x[0-9a-f]+)\) ([+-]\[.+\])$',line)
        if m:
            name=m[2]; identity=re.match(r'([+-])\[([^ ]+) (.*)\]',name)
            methods.append(dict(name=name,address=m[1],class_name=identity[2],selector=identity[3],kind='class' if identity[1]=='+' else 'instance',metadata_line=i))
    unique={ (m['address'],m['name']):m for m in methods }
    return classes,list(unique.values())

def parse_disassembly(text, image):
    functions=[]; current=None
    for num,line in enumerate(text.splitlines(),1):
        if line and not line[0].isspace() and not re.match(r'^[0-9a-f]{16}\s',line) and line.endswith(':') and not line.startswith('/'):
            current=dict(name=line[:-1],start_line=num,address=None,instruction_count=0,calls=[],cfstrings=[],bridge_edges=[])
            functions.append(current); regs={}
            continue
        m=re.match(r'^([0-9a-f]{16})\s+(\S+)\s*(.*)',line)
        if not m: continue
        if current is None:
            current=dict(name='unlabeled_text_region',start_line=num,address=None,instruction_count=0,calls=[],cfstrings=[],bridge_edges=[])
            functions.append(current); regs={}
        address='0x'+m[1]; op=m[2]; operands=m[3]
        current['instruction_count']+=1; current['last_instruction']=address
        current['address']=current['address'] or address
        code=operands.split(';',1)[0].strip()
        if op=='adrp':
            rm=re.match(r'(x\d+),.*; (0x[0-9a-f]+)',operands)
            if rm: regs[rm[1]]=int(rm[2],16)
        elif op=='add':
            rm=re.match(r'(x\d+), (x\d+), #(0x[0-9a-f]+|\d+)$',code)
            if rm:
                if rm[2] in regs: regs[rm[1]]=regs[rm[2]]+int(rm[3],0)
                else: regs.pop(rm[1],None)
        elif op=='mov':
            rm=re.match(r'(x\d+), (x\d+)$',code)
            if rm and rm[2] in regs: regs[rm[1]]=regs[rm[2]]
            elif rm: regs.pop(rm[1],None)
        if 'Objc cfstring ref:' in operands:
            reg=code.split(',',1)[0]
            cf=image.cfstring(regs.get(reg,-1))
            if cf:
                cf.update(instruction=address,disassembly_line=num,register=reg)
                current['cfstrings'].append(cf)
        if op in ('bl','b','blr','br'):
            symbolic=code.strip('"')
            call=dict(instruction=address,disassembly_line=num,opcode=op,target=symbolic,comment=operands.split(';',1)[1].strip() if ';' in operands else None)
            current['calls'].append(call)
            if '_objc_msgSend$registerHandler:handler:' in symbolic or '_objc_msgSend$callHandler:' in symbolic:
                cf=image.cfstring(regs.get('x2',-1))
                if cf:
                    current['bridge_edges'].append(dict(operation='registerHandler' if 'registerHandler' in symbolic else 'callHandler',handler=cf['value'],instruction=address,disassembly_line=num,cfstring=cf,evidence='local instruction address construction and literal argument; static syntax, no runtime invocation'))
            if op in ('bl','blr'):
                for register in [f'x{x}' for x in range(19)]: regs.pop(register,None)
        elif op not in ('adrp','add','mov','str','stur','stp','cmp','tst','nop','ret','cbz','cbnz','tbz','tbnz') and not op.startswith('b.'):
            rm=re.match(r'(x\d+)[, ]',code)
            if rm: regs.pop(rm[1],None)
        if op in ('b','br','ret') or op.startswith('b.') or op in ('cbz','cbnz','tbz','tbnz'):
            regs={}
    return functions

results={}
for label,path in [('main',APP/'Contents/MacOS/Typora'),('lib',APP/'Contents/Frameworks/libTypora.dylib')]:
    if not path.is_file():
        print(f'Skipped missing optional target: {path}')
        continue
    image=MachO(path)
    classes,methods=parse_objc((ROOT/f'native-{label}-objc.txt').read_text())
    funcs=parse_disassembly((ROOT/f'native-{label}-disassembly.txt').read_text(),image)
    edges=[dict(function=f['name'],**e) for f in funcs for e in f['bridge_edges']]
    result=dict(source=str(path),sha256=hashlib.sha256(image.data).hexdigest(),architecture='arm64',method='Read-only Mach-O bytes, nm, otool -arch arm64 -ov/-tvV; not Hopper decompilation',classes=classes,methods=methods,functions=funcs,bridge_edges=edges,counts=dict(defined_classes=len(classes),method_implementations=len(methods),disassembly_labels=len(funcs),instructions=sum(f['instruction_count'] for f in funcs),bridge_literal_edges=len(edges)),limitations=['All facts are static; Objective-C selector calls do not establish a unique runtime receiver.','Assembly boundaries follow otool labels and are not verified complete function body ranges.','Literal argument recovery is deliberately conservative: reset on branches and caller-clobbered registers.','Only arm64 was disassembled. x86_64 remains inventory-level.','No native application execution, decompiler output, source-project recovery, or behavior equivalence is claimed.'])
    (ROOT/f'native-{label}-analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    with (ROOT/f'native-{label}-methods.csv').open('w',newline='') as file:
        writer=csv.DictWriter(file,fieldnames=['class_name','kind','selector','address','metadata_line','name']);writer.writeheader();writer.writerows(methods)
    results[label]=result['counts']
print(json.dumps(results))
