{.experimental: "codeReordering".}
import strutils
import sequtils
import critbits
import std/sha1
import sets
import tables
import hashes
import algorithm
import macros
import patty
import dali/utils/sortedset
import dali/utils/blob
import dali/utils/macromatch

# NOTE(akavel): this must be early, to make sure it's used, as codeReordering fails to move it
proc `<`(p1, p2: Prototype): bool =
  # echo "called <"
  if p1.ret != p2.ret:
    return p1.ret < p2.ret
  for i in 0 ..< min(p1.params.len, p2.params.len):
    if p1.params[i] != p2.params[i]:
      return p1.params[i] < p2.params[i]
  return p1.params.len < p2.params.len

converter toUint32[T: enum](s: set[T]): uint32 =
  for v in s:
    result = result or v.ord.uint32

# Potentially useful bibliography
#
# DEX:
# - https://github.com/corkami/pics/blob/master/binary/DalvikEXecutable.pdf
# - [dex-format]: https://source.android.com/devices/tech/dalvik/dex-format
# - https://blog.bugsnag.com/dex-and-d8/
# - http://benlynn.blogspot.com/2009/02/minimal-dalvik-executables_06.html
#
# APK:
# - https://fractalwrench.co.uk/posts/playing-apk-golf-how-low-can-an-android-app-go/
# - https://github.com/fractalwrench/ApkGolf
#
# Opcodes:
# - https://github.com/corkami/pics/blob/master/binary/opcodes_tables_compact.pdf
# - https://source.android.com/devices/tech/dalvik/dalvik-bytecode.html
#
# MORE:
# - https://github.com/JesusFreke/smali
# - https://github.com/linkedin/dexmaker
# - https://github.com/iBotPeaches/Apktool

variant Arg:  # Argument of an instruction of Dalvik bytecode
  RawX(raw4: uint4)
  RawXX(raw8: uint8)
  RawXXXX(raw16: uint16)
  RegX(reg4: uint4)
  RegXX(reg8: uint8)
  FieldXXXX(field16: Field)
  StringXXXX(string16: String)
  TypeXXXX(type16: Type)
  MethodXXXX(method16: Method)

variantp MaybeType:
  SomeType(typ: Type)
  NoType

variantp MaybeCode:
  SomeCode(code: Code)
  NoCode


type
  Dex* = ref object
    # Note: below fields are generally ordered from simplest to more complex
    # (in order of dependency)
    strings: CritBitTree[int]  # value: order of addition
    types: SortedSet[string]
    typeLists: seq[seq[Type]]
    # NOTE: prototypes must have no duplicates, TODO: and be sorted by:
    # (ret's type ID; args' type ID)
    prototypes: SortedSet[Prototype]
    # NOTE: fields must have no duplicates, TODO: and be sorted by:
    # (class type ID, field name's string ID, field's type ID)
    fields: SortedSet[tuple[class: Type, name: string, typ: Type]]
    # NOTE: methods must have no duplicates, TODO: and be sorted by:
    # (class type ID, name's string ID, prototype's proto ID)
    methods: SortedSet[tuple[class: Type, name: string, proto: Prototype]]
    classes*: seq[ClassDef]
  NotImplementedYetError* = object of CatchableError
  ConsistencyError* = object of CatchableError

  Field* = ref object
    class*: Type
    typ*: Type
    name*: String
  Type* = String
  String* = string
  Method* = ref object
    class*: Type
    prototype*: Prototype  # a.k.a. method signature
    name*: String
  Prototype* = ref object
    ret*: Type
    params*: TypeList
  TypeList* = seq[Type]

  uint4* = range[0..15]   # e.g. register v0..v15

func equals*(a, b: Method): bool =
  a.class == b.class and a.name == b.name and a.prototype.equals(b.prototype)
func equals*(a, b: Prototype): bool =
  a.ret == b.ret and a.params == b.params

type
  Instr* = ref object
    opcode: uint8
    args: seq[Arg]
  Code* = ref object
    registers*: uint16
    ins*: uint16
    outs*: uint16 # "the number of words of outgoing argument space required by this code for method invocation"
    # tries: ?
    # debug_info: ?
    instrs*: seq[Instr]

type
  ClassDef* = ref object
    class*: Type
    access*: set[Access]
    superclass*: MaybeType
    # interfaces: TypeList
    # sourcefile: String
    # annotations: ?
    class_data*: ClassData
    # static_values: ?
  ClassData* = ref object
    # static_fields*: ?
    # instance_fields*: ?
    direct_methods*: seq[EncodedMethod]
    virtual_methods*: seq[EncodedMethod]
  EncodedMethod* = ref object
    m*: Method
    access*: set[Access]
    code*: MaybeCode
  Access* = enum
    Public = 0x1
    Private = 0x2
    Protected = 0x4
    Static = 0x8
    Final = 0x10
    Synchronized = 0x20
    Varargs = 0x80
    Native = 0x100
    Interface = 0x200
    Abstract = 0x400
    Annotation = 0x2000
    Enum = 0x4000
    Constructor = 0x1_0000

proc hash*(proto: Prototype): Hash =
  var h: Hash = 0
  h = h !& hash(proto.ret)
  h = h !& hash(proto.params)
  result = !$h
func equals[T](a, b: seq[T]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if not a[i].equals(b[i]): return false
  return true
func equals*(a, b: Arg): bool =
  if a == b: return true
  if a.kind == b.kind:
    case a.kind
    of ArgKind.MethodXXXX: return a.method16.equals(b.method16)
    else: return false
  return false
func equals*(a, b: Instr): bool =
  a.opcode == b.opcode and a.args.equals(b.args)
func equals*(a, b: Code): bool =
  a.registers == b.registers and a.ins == b.ins and a.outs == b.outs and a.instrs.equals(b.instrs)
func equals*(a, b: MaybeCode): bool =
  a.kind == b.kind and (a.kind == MaybeCodeKind.NoCode or a.code.equals(b.code))
func equals*(a, b: EncodedMethod): bool =
  a.m.equals(b.m) and a.access == b.access and a.code.equals(b.code)
func equals*(a, b: ClassData): bool =
  a.direct_methods.equals(b.direct_methods) and a.virtual_methods.equals(b.virtual_methods)
func equals*(a, b: ClassDef): bool =
  a.class == b.class and a.access == b.access and a.superclass == b.superclass and a.class_data.equals(b.class_data)

proc newDex*(): Dex =
  new(result)

proc render*(dex: Dex): string =
  # stderr.write(dex.repr)
  dex.collect()

  # Storage for offsets where various sections of the file
  # start. Will be needed to render map_list.
  # NOTE: n is number of elements in the section, not length in bytes.
  var sections: seq[tuple[kind: uint16, pos: uint32, n: int]]

  # blob is the buffer where we will render the binary contents of the .dex file
  var blob: Blob

  # slots are places in the blob, where we can't put data immediately. That's
  # because the value that should be there depends on some data further along
  # in the file. We bookmark some space for them in the blob, for filling in
  # later, when we will know what to put in the slot.
  var slots: tuple[
    adlerSum: Slot32,
    fileSize: Slot32,
    mapOffset: Slot32,
    stringIdsOff: Slot32,
    typeIdsOff: Slot32,
    protoIdsOff: Slot32,
    fieldIdsOff: Slot32,
    methodIdsOff: Slot32,
    classDefsOff: Slot32,
    dataSize: Slot32,
    dataOff: Slot32,
    stringOffsets: seq[Slot32],
  ]
  slots.stringOffsets.setLen(dex.strings.len)

  # FIXME: ensure correct padding everywhere

  #-- Partially render header
  # Most of it can only be calculated after the rest of the segments.
  sections.add (0x0000'u16, blob.pos, 1)
  # TODO: handle various versions of targetSdkVersion file, not only 035
  blob.puts  "dex\n035\x00"       # Magic prefix
  blob.put32 >> slots.adlerSum
  blob.skip(20)                   # SHA1 sum; we will fill it much later
  blob.put32 >> slots.fileSize
  blob.put32 0x70                 # Header size
  blob.put32 0x12345678   # Endian constant
  blob.put32 0            # link_size
  blob.put32 0            # link_off
  blob.put32 >> slots.mapOffset
  blob.put32 dex.strings.len.uint32
  blob.put32 >> slots.stringIdsOff
  blob.put32 dex.types.len.uint32
  blob.put32 >> slots.typeIdsOff
  blob.put32 dex.prototypes.len.uint32
  blob.put32 >> slots.protoIdsOff
  blob.put32 dex.fields.len.uint32
  blob.put32 >> slots.fieldIdsOff
  blob.put32 dex.methods.len.uint32
  blob.put32 >> slots.methodIdsOff
  blob.put32 dex.classes.len.uint32
  blob.put32 >> slots.classDefsOff
  blob.put32 >> slots.dataSize
  blob.put32 >> slots.dataOff

  # stderr.write(blob.string.dumpHex)
  # stderr.write("\n")

  # blob.reserve(0x70 - blob.pos.int)

  #-- Partially render string_ids
  # We preallocate space for the list of string offsets. We cannot fill it yet, as its contents
  # will depend on the size of the other segments.
  sections.add (0x0001'u16, blob.pos, dex.strings.len)
  blob[slots.stringIdsOff] = blob.pos
  for i in 0 ..< dex.strings.len:
    blob.put32 >> slots.stringOffsets[i]

  # stderr.write(blob.string.dumpHex)
  # stderr.write("\n")

  #-- Render typeIDs.
  sections.add (0x0002'u16, blob.pos, dex.types.len)
  blob[slots.typeIdsOff] = blob.pos
  let stringIds = dex.stringsOrdering
  # dex.types are already stored sorted, same as dex.strings, so we don't need
  # to sort again by type IDs
  for t in dex.types:
    blob.put32 stringIds[dex.strings[t]].uint32

  #-- Partially render proto IDs.
  # We cannot fill offsets for parameters (type lists), as they'll depend on the size of the
  # segments inbetween.
  sections.add (0x0003'u16, blob.pos, dex.prototypes.len)
  blob[slots.protoIdsOff] = blob.pos
  var typeListOffsets: Slots32[seq[Type]]
  for p in dex.prototypes:
    blob.put32 stringIds[dex.strings[p.descriptor]].uint32
    blob.put32 dex.types.search(p.ret).uint32
    blob.put32 >>: slot
    typeListOffsets.add(p.params, slot)
    # echo p.ret, " ", p.params

  #-- Render field IDs
  if dex.fields.len > 0:
    sections.add (0x0004'u16, blob.pos, dex.fields.len)
    blob[slots.fieldIdsOff] = blob.pos
  for f in dex.fields:
    blob.put16 dex.types.search(f.class).uint16
    blob.put16 dex.types.search(f.typ).uint16
    blob.put32 stringIds[dex.strings[f.name]].uint32

  #-- Render method IDs
  sections.add (0x0005'u16, blob.pos, dex.methods.len)
  if dex.methods.len > 0:
    blob[slots.methodIdsOff] = blob.pos
  for m in dex.methods:
    # echo $m
    blob.put16 dex.types.search(m.class).uint16
    blob.put16 dex.prototypes.search(m.proto).uint16
    blob.put32 stringIds[dex.strings[m.name]].uint32

  #-- Partially render class defs.
  sections.add (0x0006'u16, blob.pos, dex.classes.len)
  blob[slots.classDefsOff] = blob.pos
  var classDataOffsets: Slots32[Type]
  const NO_INDEX = 0xffff_ffff'u32
  for c in dex.classes:
    blob.put32 dex.types.search(c.class).uint32
    blob.put32 c.access.uint32
    match c.superclass:
      SomeType(t):
        blob.put32 dex.types.search(t).uint32
      NoType:
        blob.put32 NO_INDEX
    blob.put32 0'u32      # TODO: interfaces_off
    blob.put32 NO_INDEX   # TODO: source_file_idx
    blob.put32 0'u32      # TODO: annotations_off
    blob.put32 >>: slot
    classDataOffsets.add(c.class, slot)
    blob.put32 0'u32      # TODO: static_values

  #-- Render code items
  let dataStart = blob.pos
  blob[slots.dataOff] = dataStart
  var
    codeItems = 0
    codeOffsets: Table[tuple[class: Type, name: string, proto: Prototype], uint32]
  for c in dex.classes:
    let cd = c.class_data
    for dm in cd.direct_methods & cd.virtual_methods:
      if dm.code.kind == MaybeCodeKind.SomeCode:
        codeItems.inc()
        let code = dm.code.code
        codeOffsets[dm.m.asTuple] = blob.pos
        blob.put16 code.registers
        blob.put16 code.ins
        blob.put16 code.outs
        blob.put16 0'u16   # TODO: tries_size
        blob.put32 0'u32   # TODO: debug_info_off
        blob.put32 >>: slot   # This shall be filled with size of instrs, in 16-bit code units
        dex.renderInstrs(blob, code.instrs, stringIds)
        blob[slot] = (blob.pos - slot.uint32 - 4) div 2
  if codeItems > 0:
    sections.add (0x2001'u16, dataStart, codeItems)

  #-- Render type lists
  blob.pad32()
  if dex.typeLists.len > 0:
    sections.add (0x1001'u16, blob.pos, dex.typeLists.len)
  for l in dex.typeLists:
    blob.pad32()
    typeListOffsets.setAll(l, blob.pos, blob)
    blob.put32 l.len.uint32
    for t in l:
      blob.put16 dex.types.search(t).uint16

  #-- Render strings data
  sections.add (0x2002'u16, blob.pos, dex.strings.len)
  for s in dex.stringsAsAdded:
    let slot = slots.stringOffsets[stringIds[dex.strings[s]]]
    blob[slot] = blob.pos
    # FIXME: MUTF-8: encode U+0000 as hex: C0 80
    # FIXME: MUTF-8: use CESU-8 to encode code-points from beneath Basic Multilingual Plane (> U+FFFF)
    # FIXME: length *in UTF-16 code units*, as ULEB128
    blob.put_uleb128 s.len.uint32
    blob.puts s & "\x00"

  #-- Render class data
  sections.add (0x2000'u16, blob.pos, dex.classes.len)
  for c in dex.classes:
    classDataOffsets.setAll(c.class, blob.pos, blob)
    let d = c.class_data
    blob.put_uleb128 0  # TODO: static_fields_size
    blob.put_uleb128 0  # TODO: instance_fields_size
    blob.put_uleb128 d.direct_methods.len.uint32
    blob.put_uleb128 d.virtual_methods.len.uint32
    # TODO: static_fields
    # TODO: instance_fields
    dex.renderEncodedMethods(blob, d.direct_methods, codeOffsets)
    dex.renderEncodedMethods(blob, d.virtual_methods, codeOffsets)

  #-- Render map_list
  blob.pad32()
  sections.add (0x1000'u16, blob.pos, 1)
  blob[slots.mapOffset] = blob.pos
  blob.put32 sections.len.uint32
  for s in sections:
    blob.put16 s.kind
    blob.skip(2)   # unused
    blob.put32 s.n.uint32
    blob.put32 s.pos

  #-- Fill remaining slots related to file size
  blob[slots.dataSize] = blob.pos - dataStart  # FIXME: round to 64?
  blob[slots.fileSize] = blob.pos
  #-- Fill checksums
  let sha1 = secureHash(blob.string.substr(0x20)).Sha1Digest
  for i in 0 ..< 20:
    blob.string[0x0c + i] = sha1[i].char
  blob[slots.adlerSum] = adler32(blob.string.substr(0x0c))
  # stderr.write(blob.string.dumpHex)
  # stderr.write("\n")

  return blob.string


proc collect(dex: Dex) =
  # Collect strings and all the things from classes.
  # (types, prototypes/signatures, fields, methods)
  for c in dex.classes:
    dex.addType(c.class)
    if c.superclass.kind == MaybeTypeKind.SomeType:
      dex.addType(c.superclass.typ)
    let cd = c.class_data
    for dm in cd.direct_methods & cd.virtual_methods:
      dex.addMethod(dm.m)
      if dm.code.kind == MaybeCodeKind.SomeCode:
        for instr in dm.code.code.instrs:
          for arg in instr.args:
            match arg:
              RawX(_): discard
              RawXX(_): discard
              RawXXXX(_): discard
              RegX(_): discard
              RegXX(_): discard
              FieldXXXX(f):
                dex.addField(f)
              StringXXXX(s):
                dex.addStr(s)
              TypeXXXX(t):
                dex.addType(t)
              MethodXXXX(m):
                dex.addMethod(m)

proc renderEncodedMethods(dex: Dex, blob: var Blob, methods: openArray[EncodedMethod], codeOffsets: Table[tuple[class: Type, name: string, proto: Prototype], uint32]) =
  var prev = 0
  for m in methods:
    let tupl = m.m.asTuple
    let idx = dex.methods.search(tupl)
    blob.put_uleb128 uint32(idx - prev)
    prev = idx
    blob.put_uleb128 m.access.toUint32
    if Native notin m.access and Abstract notin m.access:
      blob.put_uleb128 codeOffsets[tupl]
    else:
      blob.put_uleb128 0

proc renderInstrs(dex: Dex, blob: var Blob, instrs: openArray[Instr], stringIds: openArray[int]) =
  var
    high = true
  for instr in instrs:
    blob.putc instr.opcode.chr
    for arg in instr.args:
      # FIXME(akavel): padding
      match arg:
        RawX(v):
          blob.put4 v, high
          high = not high
        RawXX(v):
          blob.putc v.chr
        RawXXXX(v):
          blob.put16 v
        RegX(v):
          blob.put4 v, high
          high = not high
        RegXX(v):
          blob.putc v.chr
        FieldXXXX(v):
          blob.put16 dex.fields.search((v.class, v.name, v.typ)).uint16
        StringXXXX(v):
          blob.put16 stringIds[dex.strings[v]].uint16
        TypeXXXX(v):
          blob.put16 dex.types.search(v).uint16
        MethodXXXX(v):
          blob.put16 dex.methods.search((v.class, v.name, v.prototype)).uint16

proc move_result_object*(reg: uint8): Instr =
  return newInstr(0x0c, RegXX(reg))
proc return_void*(): Instr =
  return newInstr(0x0e, RawXX(0))
proc const_high16*(reg: uint8, highBits: uint16): Instr =
  return newInstr(0x15, RegXX(reg), RawXXXX(highBits))
proc const_string*(reg: uint8, s: String): Instr =
  return newInstr(0x1a, RegXX(reg), StringXXXX(s))
proc new_instance*(reg: uint8, t: Type): Instr =
  return newInstr(0x22, RegXX(reg), TypeXXXX(t))
proc sget_object*(reg: uint8, field: Field): Instr =
  return newInstr(0x62, RegXX(reg), FieldXXXX(field))

proc invoke_virtual*(regC: uint4, m: Method): Instr =
  return newInvoke1(0x6e, regC, m)
proc invoke_virtual*(regC: uint4, regD: uint4, m: Method): Instr =
  return newInvoke2(0x6e, regC, regD, m)

proc invoke_super*(regC: uint4, regD: uint4, m: Method): Instr =
  return newInvoke2(0x6f, regC, regD, m)

proc invoke_direct*(regC: uint4, m: Method): Instr =
  return newInvoke1(0x70, regC, m)
proc invoke_direct*(regC: uint4, regD: uint4, m: Method): Instr =
  return newInvoke2(0x70, regC, regD, m)

proc invoke_static*(regC: uint4, m: Method): Instr =
  return newInvoke1(0x71, regC, m)


proc newInvoke1(opcode: uint8, regC: uint4, m: Method): Instr =
  return newInstr(opcode, RawX(1), RawX(0), MethodXXXX(m), RawX(0), RegX(regC), RawXX(0))
proc newInvoke2(opcode: uint8, regC: uint4, regD: uint4, m: Method): Instr =
  return newInstr(opcode, RawX(2), RawX(0), MethodXXXX(m), RawX(regD), RegX(regC), RawXX(0))

proc newInstr(opcode: uint8, args: varargs[Arg]): Instr =
  ## NOTE: We're assuming little endian encoding of the
  ## file here; 8-bit args should be ordered in
  ## "swapped order" vs. the one listed in official
  ## Android bytecode spec (i.e., add lower byte first,
  ## higher byte later). On the other hand, 16-bit
  ## words should not have contents rotated (just fill
  ## them as in the spec).
  return Instr(opcode: opcode, args: @args)

proc addField(dex: Dex, f: Field) =
  dex.addType(f.class)
  dex.addType(f.typ)
  dex.addStr(f.name)
  dex.fields.incl((f.class, f.name, f.typ))

proc addMethod(dex: Dex, m: Method) =
  dex.addType(m.class)
  dex.addPrototype(m.prototype)
  dex.addStr(m.name)
  dex.methods.incl((m.class, m.name, m.prototype))

proc addPrototype(dex: Dex, proto: Prototype) =
  dex.addType(proto.ret)
  dex.addTypeList(proto.params)
  dex.prototypes.incl(proto)
  dex.addStr(proto.descriptor)

proc descriptor(proto: Prototype): string =
  proc typeChar(t: Type): string =
    if t.len==1 and t[0] in {'V','Z','B','S','C','I','J','F','D'}:
      return t
    elif t.len>=1 and t[0] in {'[','L'}:
      return "L"
    else:
      raise newException(ConsistencyError, "unexpected type in prototype: " & t)

  return (proto.ret & proto.params).map(typeChar).join

proc addTypeList(dex: Dex, ts: seq[Type]) =
  if ts.len == 0:
    return
  for t in ts:
    dex.addType(t)
  if ts notin dex.typeLists:
    dex.typeLists.add(ts)

proc addType(dex: Dex, t: Type) =
  dex.addStr(t)
  dex.types.incl(t)

proc addStr(dex: Dex, s: string) =
  if s.contains({'\x00', '\x80'..'\xFF'}):
    raise newException(NotImplementedYetError, "strings with 0x00 or 0x80..0xFF bytes are not yet supported")
  discard dex.strings.containsOrIncl(s, dex.strings.len)
  # "This list must be sorted by string contents, using UTF-16 code point
  # values (not in a locale-sensitive manner), and it must not contain any
  # duplicate entries." [dex-format] <- I think this is guaranteed by UTF-8 + CritBitTree type

proc stringsOrdering(dex: Dex): seq[int] =
  var i = 0
  result.setLen dex.strings.len
  for s, added in dex.strings:
    result[added] = i
    inc i

proc stringsAsAdded(dex: Dex): seq[string] =
  result.setLen dex.strings.len
  for s, added in dex.strings:
    result[added] = s

func asTuple(m: Method): tuple[class: Type, name: string, proto: Prototype] =
  return (class: m.class, name: m.name, proto: m.prototype)

proc adler32(s: string): uint32 =
  # https://en.wikipedia.org/wiki/Adler-32
  var a: uint32 = 1
  var b: uint32 = 0
  const MOD_ADLER = 65521
  for c in s:
    a = (a + c.uint32) mod MOD_ADLER
    b = (b + a) mod MOD_ADLER
  result = (b shl 16) or a

proc typeLetter(fullType: string): string =
  ## typeLetter returns a one-letter code of a Java/Android primitive type,
  ## as represented in bytecode. Returns empty string if the input type is not known.
  case fullType
  of "void": "V"
  of "boolean": "Z"
  of "byte": "B"
  of "char": "C"
  of "int": "I"
  of "long": "J"
  of "float": "F"
  of "double": "D"
  else: ""

proc handleJavaType(n: NimNode): NimNode =
  ## handleJavaType checks if n is an identifer corresponding to a Java type name.
  ## If yes, it returns a string literal with a one-letter code of this type. Otherwise,
  ## it returns a copy of the original node n.
  let coded = n.strVal.typeLetter
  if coded != "":
    result = newLit(coded)
  else:
    result = copyNimNode(n)

macro jproto*(prototype: untyped): untyped =
  ## jproto is a macro converting a prototype declaration into a dali Method object.
  ## Example:
  ##
  ##   let HelloWorld = "Lcom/hello/HelloWorld;"
  ##   let String = "Ljava/lang/String;"
  ##   jproc HelloWorld.hello(String, int): String
  ##   jproc HelloWorld.`<init>`()
  ##   # NOTE: jproc argument must not be parenthesized; the following does not work unfortunately:
  ##   # jproc(HelloWorld.hello(String, int): String)
  ##
  ## TODO: support Java array types, i.e. int[], int[][], etc.
  # echo proto.treeRepr
  # echo ret.treeRepr
  # result = nnkStmtList.newTree()
  # echo "----------------"
  var proto = prototype

  # Parse & verify that proto has correct syntax
  # ...return type if present
  var rett = newLit("V")
  if proto =~ Infix(Ident("->"), [], Ident(_)):
    rett = proto[2].handleJavaType
    proto = proto[1]
  # ...class & method name:
  if proto !~ Call(_):
    error "jproto expects a method declaration as an argument", proto
  if proto !~ Call(DotExpr(_), _):
    error "jproto expects dot-separated class & method name in the argument", proto
  if proto[0] !~ DotExpr(Ident(_), Ident(_)) and
    proto[0] !~ DotExpr(Ident(_), AccQuoted(_)):
    error "jproto expects exactly 2 dot-separated names in the argument", proto[0]
  # ... parameters list:
  for i in 1..<proto.len:
    if proto[i] !~ Ident(_):
      error "jproto expects type names as method parameters", proto[i]

  # Build parameters list
  var params: seq[NimNode]
  for i in 1..<proto.len:
    params.add proto[i].handleJavaType
  let paramsTree = newTree(nnkBracket, params)

  # Build result
  let class = copyNimNode(proto[0][0])
  let name = proto[0][1].collectProcName
  result = quote do:
    Method(
      class: `class`,
      name: `name`,
      prototype: Prototype(
        ret: `rett`,
        params: @ `paramsTree`))
  # echo "======"
  # echo result.repr

proc collectProcName*(n: NimNode): NimNode =
  if n =~ Ident(_):
    newLit(n.strVal)
  else:
    var buf = ""
    for it in n.items:
      buf.add it.strVal
    newLit(buf)

macro dclass*(header, body: untyped): untyped =
  dclass2ClassDef(header, body)

proc dclass2ClassDef(header, body: NimNode): NimNode =
  var h = parseDClassHeader(header)

  # Translate the class name to a string understood by Java bytecode. Do it
  # here as it'll be needed below.
  let classString = "L" & h.fullName.join("/") & ";"

  # Parse class body - a list of proc definitions
  if body !~ StmtList(_):
    error "expected a list of proc definitions", body
  var
    directMethods: seq[NimNode]
    virtualMethods: seq[NimNode]
  for procDef in body:
    let p = parseDClassProc(procDef)

    var instrs: seq[NimNode]
    if not p.native:
      # check proc body
      if p.body =~ Empty():
        continue
      if p.body !~ StmtList(_):
        error "unexpected syntax of proc body", p.body
      for stmt in p.body:
        case stmt.kind
        of nnkCall:
          instrs.add stmt
        of nnkCommand:
          var call = newTree(nnkCall)
          stmt.copyChildrenTo(call)
          call.copyLineInfo(stmt)
          instrs.add call
        of nnkIdent:
          instrs.add newCall(stmt)
        else:
          error "expected proc body to contain only Android assembly instructions", stmt

    # Rewrite the procedure as an EncodedMethod object
    let
      name = p.name.collectProcName
      paramsTree = newTree(nnkBracket, p.params)
      ret = p.ret
      procAccessTree = newTree(nnkCurly, p.pragmas)
      regsTree = newLit(p.regs)
      insTree = newLit(p.ins)
      outsTree = newLit(p.outs)
      codeTree =
        if instrs.len > 0:
          let instrsTree = newTree(nnkBracket, instrs)
          quote do:
            SomeCode(Code(
              registers: `regsTree`,
              ins: `insTree`,
              outs: `outsTree`,
              instrs: @`instrsTree`))
        else:
          quote do:
            NoCode()
    let enc = quote do:
      EncodedMethod(
        m: Method(
          class: `classString`,
          name: `name`,
          prototype: Prototype(
            ret: `ret`,
            params: @ `paramsTree`)),
        access: `procAccessTree`,
        code: `codeTree`)
    # echo enc.repr  # this prints Nim code - Thanks @disruptek on Nim chatroom for the hint!
    # echo enc.treeRepr
    if p.direct:
      directMethods.add enc
    else:
      virtualMethods.add enc

  # Render collected data into a ClassDef object
  let
    classTree = newLit(classString)
    accessTree = newTree(nnkCurly, h.pragmas)
    super = h.super
    superclassTree =
      if super =~ Empty():
        quote do:
          NoType()
      else:
        quote do:
          SomeType(`super`)
    directMethodsTree = newTree(nnkBracket, directMethods)
    virtualMethodsTree = newTree(nnkBracket, virtualMethods)
  # TODO: also, create a `let` identifer for the class name
  result = quote do:
    ClassDef(
      class: `classTree`,
      access: `accessTree`,
      superclass: `superclassTree`,
      class_data: ClassData(
        direct_methods: @`directMethodsTree`,
        virtual_methods: @`virtualMethodsTree`))



type DClassHeaderInfo = tuple
  super: NimNode         # nnkEmpty if no superclass declared
  pragmas: seq[NimNode]  # pragmas, with first letter modified to uppercase
  fullName: seq[string]  # Fully Qualified Class Name

proc parseDClassHeader(header: NimNode): DClassHeaderInfo =
  ## parseDClassHeader parses Java class header (class name & various modifiers)
  ## specified in Nim-like syntax.
  ## Example:
  ##
  ##     com.akavel.hello2.HelloActivity {.public.} of Activity
  ##
  ## corresponds to:
  ##
  ##     package com.akavel.hello2;
  ##     public class HelloActivity extends Activity { ... }

  # [com.foo.Bar {.public.}] of Activity
  result.super = newEmptyNode()
  var rest = header
  if header =~ Infix(Ident("of"), [], []):
    result.super = header[2]
    rest = header[1]

  # [com.foo.Bar] {.public.}
  if rest =~ PragmaExpr(_):
    if rest !~ PragmaExpr([], []):
      error "encountered unexpected syntax (too many words)", rest
    if rest !~ PragmaExpr([], Pragma(_)):
      error "expected pragmas list", rest[1]
    for p in rest[1]:
      if p !~ Ident(_):
        error "expected a simple pragma identifer", p
      let x = ident(p.strVal.capitalizeAscii)
      x.copyLineInfo(p)
      result.pragmas.add x
    rest = rest[0]

  # com.foo.[Bar]
  while rest =~ DotExpr(_):
    # TODO: allow and handle "$" character in class names
    if rest !~ DotExpr([], Ident(_)):
      error "expected 2+ dot-separated simple identifiers", rest
    result.fullName.add rest[1].strVal
    rest = rest[0]

  # [com.foo.]Bar
  if rest !~ Ident(_):
    error "expected dot-separated simple identifiers", rest
  result.fullname.add rest.strVal
  # After the processing above, fullName has unnatural, reversed order of segments; fix this
  reverse(result.fullname)

type DClassProcInfo = tuple
  name: NimNode
  pragmas: seq[NimNode]
  direct, native: bool
  regs, ins, outs: int
  params: seq[NimNode]
  ret: NimNode
  body: NimNode

proc parseDClassProc(procDef: NimNode): DClassProcInfo =
  if procDef !~ ProcDef(_):
    error "expected a proc definition", procDef
  # Parse proc header
  const
    # important indexes in nnkProcDef children,
    # see: https://nim-lang.org/docs/macros.html#statements-procedure-declaration
    i_name = 0
    i_params = 3
    i_pragmas = 4
    i_body = 6

  # proc name must be a simple identifier, or backtick-quoted name
  if procDef[i_name] !~ Ident(_) and procDef[i_name] !~ AccQuoted(_):
    error "expected a proc name to be a simple identifier, or a backtick-quoted name", procDef[0]
  result.name = procDef[i_name]

  if procDef[1] !~ Empty():
    error "unexpected term rewriting pattern", procDef[1]
  if procDef[2] !~ Empty():
    error "unexpected generic type param", procDef[2]
  # TODO: shouldn't below also contain Final???
  const directMethodPragmas = toHashSet(["Static", "Private", "Constructor"])
  if procDef[i_pragmas] =~ Pragma(_):
    for p in procDef[i_pragmas]:
      if p =~ Ident(_):
        let x = ident(p.strVal.capitalizeAscii)
        x.copyLineInfo(p)
        result.pragmas.add x
        if x.strVal in directMethodPragmas:
          result.direct = true
        elif x.strVal == "Native":
          result.native = true
      elif p =~ ExprColonExpr(Ident(_), IntLit(_)):
        case p[0].strVal
        of "regs": result.regs = p[1].intVal.int
        of "ins":  result.ins = p[1].intVal.int
        of "outs": result.outs = p[1].intVal.int
        else: error "expected one of: 'regs: N', 'ins: N', 'outs: N' or access pragmas", p[0]
      else:
        error "unexpected format of pragma", p
  # proc return type
  result.ret = newLit("V")  # 'void' by default
  if procDef[i_params][0] !~ Empty():
    result.ret = procDef[i_params][0].handleJavaType
  # check & collect proc params
  if procDef[i_params].len > 2: error "unexpected syntax of proc params (must be a list of type names)", procDef[i_params]
  if procDef[i_params].len == 2:
    let rawParams = procDef[i_params][1]
    if rawParams[^1] !~ Empty(): error "unexpected syntax of proc param (must be a name of a type)", rawParams[^1]
    if rawParams[^2] !~ Empty(): error "unexpected syntax of proc param (must be a name of a type)", rawParams[^2]
    for p in rawParams[0..^3]:
      result.params.add p.handleJavaType
  # copy proc body
  result.body = procDef[i_body]

