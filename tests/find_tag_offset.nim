import std/[os, streams, endians]

# This program searches for the tag "SMPL1" in an ABIF file and prints its offset
# This is a specific utility to help with debugging the tag editing functionality

type
  ElementType = enum
    etByte = 1, etChar = 2, etWord = 3, etShort = 4, etLong = 5,
    etRational = 6, etFloat = 7, etDouble = 8, etDate = 10,
    etTime = 11, etThumb = 12, etBool = 13, etPoint = 14, etRect = 15,
    etVPoint = 16, etVRect = 17, etPString = 18, etCString = 19, etTag = 20

proc readInt16BE(s: Stream): int =
  var val: uint16 = s.readUint16()
  var res: uint16
  bigEndian16(addr res, addr val)
  result = cast[int16](res).int

proc readInt32BE(s: Stream): int =
  var val: uint32 = s.readUint32()
  var res: uint32
  bigEndian32(addr res, addr val)
  result = cast[int32](res).int

proc readUint8(s: Stream): uint8 =
  result = cast[uint8](s.readChar())

proc readStringBE(s: Stream, len: int): string =
  result = newString(len)
  if len > 0:
    discard s.readData(addr result[0], len)

proc main() =
  let filename = if paramCount() > 0: paramStr(1) else: "tests/bmr/01_F.ab1"
  let tagName = if paramCount() > 1: paramStr(2) else: "SMPL1"
  
  echo "Searching for tag ", tagName, " in file ", filename
  
  let file = newFileStream(filename, fmRead)
  if file == nil:
    echo "Failed to open file: ", filename
    quit(1)
  
  defer: file.close()
  
  # Check ABIF signature
  file.setPosition(0)
  let signature = file.readStringBE(4)
  if signature != "ABIF":
    echo "Not a valid ABIF file (signature: ", signature, ")"
    quit(1)
  
  # Read file version
  let version = readInt16BE(file)
  echo "ABIF version: ", version
  
  # Skip to directory offset position (26) and read it
  file.setPosition(26)
  let dataOffset = readInt32BE(file)
  echo "Directory offset: ", dataOffset

  # Skip to numElements position (18) and read it
  file.setPosition(18)
  let numElems = readInt32BE(file)
  echo "Number of directory entries: ", numElems
  
  # Now search all directory entries
  var found = false
  for i in 0..<numElems:
    let offset = dataOffset + (i * 28) # 28 bytes per directory entry
    file.setPosition(offset)
    
    let tag = file.readStringBE(4)
    let num = readInt32BE(file)
    let elemType = readInt16BE(file)
    let elemSize = readInt16BE(file)
    let elemNum = readInt32BE(file)
    let dataSize = readInt32BE(file)
    let dataOffset = readInt32BE(file)
    let dataHandle = readInt32BE(file)
    
    let fullTag = tag & $num
    
    # Check if this is the tag we're looking for
    if fullTag == tagName:
      echo "Found tag: ", fullTag
      echo "  Element type: ", cast[ElementType](elemType)
      echo "  Element size: ", elemSize
      echo "  Element num: ", elemNum
      echo "  Data size: ", dataSize
      
      # For small data (≤4 bytes), the data is stored directly in the dataOffset field
      let actualOffset = if dataSize <= 4: offset + 20 else: dataOffset
      echo "  Data offset: ", dataOffset, " (actual: ", actualOffset, ")"
      echo "  Data handle: ", dataHandle
      
      # If this is a string type, read and display the value
      if cast[ElementType](elemType) == etPString:
        file.setPosition(actualOffset)
        let length = readUint8(file)
        echo "  String length byte: ", length
        echo "  String start offset: ", actualOffset + 1
        if length > 0:
          let value = file.readStringBE(length.int)
          echo "  Value: \"", value, "\""
      elif cast[ElementType](elemType) == etCString:
        file.setPosition(actualOffset)
        var value = ""
        var c = file.readChar()
        while c != '\0' and value.len < dataSize:
          value.add(c)
          c = file.readChar()
        echo "  Value: \"", value, "\""
      
      found = true
      break
  
  if not found:
    echo "Tag ", tagName, " not found in file"

when isMainModule:
  main()