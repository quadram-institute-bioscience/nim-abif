import std/[os, streams]

proc readUint8(s: Stream): uint8 =
  result = cast[uint8](s.readChar())

# This program directly edits the SMPL1 tag in tests/bmr/01_F.ab1
# Based on the offset found by find_tag_offset.nim

proc main() =
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified.ab1"
  let tagValue = "raino_1-FOR"
  let newValue = "NewSampleName"
  
  # Pascal string tag SMPL1 at offset 231736
  let tagOffset = 231736
  
  echo "DIRECT TAG EDIT TEST"
  echo "  Input file: ", inputFile
  echo "  Output file: ", outputFile
  echo "  Tag: SMPL1"
  echo "  Original value: ", tagValue
  echo "  New value: ", newValue
  echo "  Offset: ", tagOffset
  
  # Create a copy of the file
  copyFile(inputFile, outputFile)
  
  # Open the copy for editing
  var file = newFileStream(outputFile, fmReadWrite)
  if file == nil:
    echo "Failed to open file: ", outputFile
    quit(1)
  
  # Seek to the tag offset
  file.setPosition(tagOffset)
  
  # First read the current value to verify
  let currentLength = file.readUint8()
  echo "  Current length byte: ", currentLength
  var currentValue = newString(currentLength.int)
  discard file.readData(addr currentValue[0], currentLength.int)
  echo "  Current value read from file: ", currentValue
  
  # Seek back to the tag offset
  file.setPosition(tagOffset)
  
  # Write the length byte (PString format)
  file.write(newValue.len.uint8)
  
  # Write the string content
  file.writeData(newValue.cstring, newValue.len)
  
  # If the new value is shorter than the old one, pad with nulls
  if newValue.len < tagValue.len:
    for i in 0..<(tagValue.len - newValue.len):
      file.write('\0')
  
  # Close the file
  file.close()
  
  echo "Tag modified successfully"
  echo "To verify: run `./tests/find_tag_offset tests/modified.ab1`"

when isMainModule:
  main()