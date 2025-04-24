import std/[streams, tables, strformat, endians]

type
  ElementType = enum
    etByte = 1, etChar = 2, etWord = 3, etShort = 4, etLong = 5,
    etRational = 6, etFloat = 7, etDouble = 8, etDate = 10,
    etTime = 11, etThumb = 12, etBool = 13, etPoint = 14, etRect = 15,
    etVPoint = 16, etVRect = 17, etPString = 18, etCString = 19, etTag = 20
  
  DirectoryEntry = object
    tagName: string
    tagNum: int
    elemType: ElementType
    elemSize: int
    elemNum: int
    dataSize: int
    dataOffset: int
    dataHandle: int
    
  ABIFTrace* = ref object
    stream: FileStream
    version: int
    numElems: int
    dataOffset: int
    tags: TableRef[string, DirectoryEntry]
    data: TableRef[string, string]

const
  Extract = {
    "TUBE1": "well",
    "DySN1": "dye",
    "GTyp1": "polymer",
    "MODL1": "model",
    "RUND1": "run_start_date",
    "RUND2": "run_finish_date",
    "RUND3": "data_collection_start_date",
    "RUND4": "data_collection_finish_date",
    "RUNT1": "run_start_time",
    "RUNT2": "run_finish_time",
    "RUNT3": "data_collection_start_time",
    "RUNT4": "data_collection_finish_time",
    "DATA1": "raw1",
    "DATA2": "raw2",
    "DATA3": "raw3",
    "DATA4": "raw4",
    "PLOC2": "tracepeaks",
    "FWO_1": "baseorder",
    "PBAS2": "sequence",
    "PCON2": "quality",
    "SMPL1": "name"
  }.toTable

proc readInt16BE(s: Stream): int =
  var val: uint16 = s.readUint16()
  var res: uint16
  bigEndian16(addr res, addr val)
  result = cast[int16](res).int
  # Adjust for negative values
  if result > 32767:
    result -= 65536

proc readInt32BE(s: Stream): int =
  var val: uint32 = s.readUint32()
  var res: uint32
  bigEndian32(addr res, addr val)
  result = cast[int32](res).int
  # Adjust for negative values
  if result > 2147483647:
    result -= 4294967296

proc readStringBE(s: Stream, len: int): string =
  result = newString(len)
  if len > 0:
    discard s.readData(addr result[0], len)

proc readUint8(s: Stream): uint8 =
  result = cast[uint8](s.readChar())

proc readEntry(s: Stream, offset: int): DirectoryEntry =
  s.setPosition(offset)
  
  result.tagName = s.readStringBE(4)
  
  var tagNum = readInt32BE(s)
  result.tagNum = tagNum
  
  var elemType = readInt16BE(s)
  result.elemType = cast[ElementType](elemType)
  
  var elemSize = readInt16BE(s)
  result.elemSize = elemSize
  
  var elemNum = readInt32BE(s)
  result.elemNum = elemNum
  
  var dataSize = readInt32BE(s)
  result.dataSize = dataSize
  
  var dataOffset = readInt32BE(s)
  result.dataOffset = dataOffset
  
  var dataHandle = readInt32BE(s)
  result.dataHandle = dataHandle
  
  # For small data items (<=4 bytes), the data is stored in the dataOffset field
  if result.dataSize <= 4:
    result.dataOffset = offset + 20

proc unpackData(trace: ABIFTrace, entry: DirectoryEntry): string =
  let s = trace.stream
  s.setPosition(entry.dataOffset)
  
  case entry.elemType
  of etByte:
    result = newString(entry.elemNum)
    discard s.readData(addr result[0], entry.elemNum)
  of etChar:
    result = s.readStringBE(entry.elemNum)
  of etWord, etShort:
    var values = newSeq[int](entry.elemNum)
    for i in 0..<entry.elemNum:
      values[i] = readInt16BE(s)
    result = $values
  of etLong:
    var values = newSeq[int](entry.elemNum)
    for i in 0..<entry.elemNum:
      values[i] = readInt32BE(s)
    result = $values
  of etFloat:
    var values = newSeq[float32](entry.elemNum)
    for i in 0..<entry.elemNum:
      var val: uint32 = s.readUint32()
      var res: float32
      bigEndian32(addr res, addr val)
      values[i] = res
    result = $values
  of etDouble:
    var values = newSeq[float64](entry.elemNum)
    for i in 0..<entry.elemNum:
      var val: uint64 = s.readUint64()
      var res: float64
      bigEndian64(addr res, addr val)
      values[i] = res
    result = $values
  of etDate:
    if entry.elemNum == 1:
      let year = readInt16BE(s)
      let month = readUint8(s)
      let day = readUint8(s)
      result = $year & "-" & $month & "-" & $day
    else:
      var dates = newSeq[string](entry.elemNum)
      for i in 0..<entry.elemNum:
        let year = readInt16BE(s)
        let month = readUint8(s)
        let day = readUint8(s)
        dates[i] = $year & "-" & $month & "-" & $day
      result = $dates
  of etTime:
    if entry.elemNum == 1:
      let hour = readUint8(s)
      let minute = readUint8(s)
      let second = readUint8(s)
      let hsecond = readUint8(s)
      result = &"{hour}:{minute}:{second}.{hsecond}"
    else:
      var times = newSeq[string](entry.elemNum)
      for i in 0..<entry.elemNum:
        let hour = readUint8(s)
        let minute = readUint8(s)
        let second = readUint8(s)
        let hsecond = readUint8(s)
        times[i] = &"{hour}:{minute}:{second}.{hsecond}"
      result = $times
  of etBool:
    if entry.elemNum == 1:
      result = if readUint8(s) == 0: "false" else: "true"
    else:
      var bools = newSeq[bool](entry.elemNum)
      for i in 0..<entry.elemNum:
        bools[i] = readUint8(s) != 0
      result = $bools
  of etPString:
    let length = readUint8(s)
    result = s.readStringBE(length.int)
  of etCString:
    result = ""
    var c = s.readChar()
    while c != '\0' and result.len < entry.dataSize:
      result.add(c)
      c = s.readChar()
  else:
    # For unsupported types, just read the raw data
    result = s.readStringBE(entry.dataSize)

proc newABIFTrace*(filename: string, trimming: bool = false): ABIFTrace =
  result = ABIFTrace(
    stream: newFileStream(filename, fmRead),
    tags: newTable[string, DirectoryEntry](),
    data: newTable[string, string]()
  )
  
  if result.stream == nil:
    raise newException(IOError, "Could not open file: " & filename)
  
  # Check ABIF signature
  result.stream.setPosition(0)
  let signature = result.stream.readStringBE(4)
  if signature != "ABIF":
    raise newException(IOError, "Input is not a valid ABIF trace file")
  
  # Read file version
  result.version = readInt16BE(result.stream)
  
  # Skip to numElements position (18) and read it
  result.stream.setPosition(18)
  result.numElems = readInt32BE(result.stream)
  
  # Skip to dataOffset position (26) and read it
  result.stream.setPosition(26)
  result.dataOffset = readInt32BE(result.stream)
  
  # Read all directory entries and store them
  for i in 0..<result.numElems:
    let offset = result.dataOffset + (i * 28) # 28 bytes per directory entry
    let entry = readEntry(result.stream, offset)
    let key = entry.tagName & $entry.tagNum
    result.tags[key] = entry
    
    # Only extract data from tags we care about
    if Extract.hasKey(key):
      let extractedKey = Extract[key]
      result.data[extractedKey] = unpackData(result, entry)

proc close*(trace: ABIFTrace) =
  if trace.stream != nil:
    trace.stream.close()

proc getTagNames*(trace: ABIFTrace): seq[string] =
  for key in trace.tags.keys:
    result.add(key)

proc getData*(trace: ABIFTrace, tag: string): string =
  if trace.tags.hasKey(tag):
    return unpackData(trace, trace.tags[tag])
  return ""

proc getSequence*(trace: ABIFTrace): string =
  if trace.data.hasKey("sequence"):
    return trace.data["sequence"]
  return trace.getData("PBAS2")

proc getQualityValues*(trace: ABIFTrace): seq[int] =
  var qualityStr: string
  if trace.data.hasKey("quality"):
    qualityStr = trace.data["quality"]
  else:
    qualityStr = trace.getData("PCON2")
  
  result = newSeq[int](qualityStr.len)
  for i, c in qualityStr:
    result[i] = ord(c)

proc getSampleName*(trace: ABIFTrace): string =
  if trace.data.hasKey("name"):
    return trace.data["name"]
  return trace.getData("SMPL1")

proc exportFasta*(trace: ABIFTrace, outFile: string = "") =
  let sequence = trace.getSequence()
  if sequence.len == 0:
    return
  
  let name = trace.getSampleName()
  var id = outFile
  if id == "":
    id = "trace"
  
  let contents = &">{id} {name}\n{sequence}\n"
  
  let fileName = if outFile == "": "trace.fa" else: outFile
  writeFile(fileName, contents)

proc exportFastq*(trace: ABIFTrace, outFile: string = "") =
  let sequence = trace.getSequence()
  if sequence.len == 0:
    return
  
  let name = trace.getSampleName()
  var id = outFile
  if id == "":
    id = "trace"
  
  var quality = ""
  for qv in trace.getQualityValues():
    quality.add(chr(qv + 33))  # Convert to Phred+33 format
  
  let contents = &"@{id} {name}\n{sequence}\n+\n{quality}\n"
  
  let fileName = if outFile == "": "trace.fq" else: outFile
  writeFile(fileName, contents)

when isMainModule:
  import os
  
  if paramCount() < 1:
    echo "Usage: abif <trace_file.ab1> [output_file]"
    quit(1)
  
  let inFile = paramStr(1)
  var outFile = ""
  if paramCount() >= 2:
    outFile = paramStr(2)
  
  try:
    let trace = newABIFTrace(inFile)
    echo "File version: ", trace.version
    echo "Sample name: ", trace.getSampleName()
    echo "Sequence length: ", trace.getSequence().len
    
    # Export as FASTA
    trace.exportFasta(outFile)
    echo "Exported FASTA file"
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()