{.experimental: "codeReordering".}
import hashes
import options

import patty


variantp Arg:  # Argument of an instruction of Dalvik bytecode
  RawX(raw4: uint4)
  RawXX(raw8: uint8)
  RawXXXX(raw16: uint16)
  RegX(reg4: uint4)
  RegXX(reg8: uint8)
  FieldXXXX(field16: Field)
  StringXXXX(string16: String)
  TypeXXXX(type16: Type)
  MethodXXXX(method16: Method)

variantp EncodedValue:
  EVArray(elems: seq[EncodedValue])
  EVType(typ: Type)


type
  Field* = object
    class*: Type
    typ*: Type
    name*: String
  Type* = String
  String* = string
  Method* = object
    class*: Type
    prototype*: Prototype  # a.k.a. method signature
    name*: String
  Prototype* = object
    ret*: Type
    params*: TypeList
  TypeList* = seq[Type]

  uint4* = range[0..15]   # e.g. register v0..v15

type
  Instr* = object
    opcode*: uint8
    args*: seq[Arg]
  Code* = ref object  # NOTE: nil is OK here
    registers*: uint16
    ins*: uint16
    outs*: uint16 # "the number of words of outgoing argument space required by this code for method invocation"
    # tries: ?
    # debug_info: ?
    instrs*: seq[Instr]

type
  ClassDef* = object
    class*: Type
    access*: set[Access]
    superclass*: Option[Type]
    interfaces*: TypeList
    # sourcefile: String
    # annotations: ?
    class_data*: ClassData
    # static_values: ?
  ClassData* = ref object  # NOTE: nil is OK here
    # static_fields*: ?
    #TODO: add some tests for rendered instance_fields
    instance_fields*: seq[EncodedField]
    direct_methods*: seq[EncodedMethod]
    virtual_methods*: seq[EncodedMethod]
  EncodedField* = object
    f*: Field
    access*: set[Access]
  EncodedMethod* = object
    m*: Method
    access*: set[Access]
    annotations*: seq[AnnotationItem]
    code*: Code
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
  AnnotationItem* = tuple
    visibility: Visibility
    encoded_annotation: EncodedAnnotation
  Visibility* = enum
    VisSystem = 0x02
  EncodedAnnotation* = object
    typ*: Type
    elems*: seq[AnnotationElement]
  AnnotationElement* = object
    name*: string
    value*: EncodedValue

  NotImplementedYetError* = object of CatchableError
  ConsistencyError* = object of CatchableError

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
    of ArgKind.MethodXXXX: return a.method16 == b.method16
    else: return false
  return false
func equals*(a, b: Code): bool =
  (a == nil and b == nil) or (a.registers == b.registers and a.ins == b.ins and a.outs == b.outs and a.instrs == b.instrs)
func equals*(a, b: EncodedMethod): bool =
  a.m == b.m and a.access == b.access and a.code.equals(b.code)
func equals*(a, b: ClassData): bool =
  a.direct_methods.equals(b.direct_methods) and a.virtual_methods.equals(b.virtual_methods)
func equals*(a, b: ClassDef): bool =
  a.class == b.class and a.access == b.access and a.superclass == b.superclass and a.class_data.equals(b.class_data)
