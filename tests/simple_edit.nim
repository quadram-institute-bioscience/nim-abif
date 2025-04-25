import std/[os, streams]

## A very simple program to edit the SMPL1 tag in an ABIF file

proc main() =
  # Set up the files and parameters
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified.ab1"
  let newValue = "NewSampleName"
  let tagOffset = 231736  # Found previously with find_tag_offset.nim
  
  echo "Simple tag editor"
  echo "Input file: ", inputFile
  echo "Output file: ", outputFile
  
  # First make a copy of the file
  echo "Copying file..."
  copyFile(inputFile, outputFile)
  
  # Open the output file for modification
  echo "Opening output file..."
  var file = open(outputFile, fmReadWrite)
  
  # Move to the tag position (SMPL1 tag's data starts at offset 231736)
  echo "Seeking to position ", tagOffset, "..."
  file.setFilePos(tagOffset)
  
  # Write the new length byte (Pascal string)
  echo "Writing length byte: ", newValue.len, "..."
  var lengthByte: char = char(newValue.len)
  discard file.writeBuffer(addr lengthByte, 1)
  
  # Write the new string content
  echo "Writing new value: ", newValue, "..."
  discard file.writeBuffer(cstring(newValue), newValue.len)
  
  # Close the file
  file.close()
  
  echo "Done!"
  
when isMainModule:
  main()