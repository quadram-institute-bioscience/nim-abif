import std/[os]

## A very simple hexadecimal editor to modify the SMPL1 tag
## This avoids any complex logic and just replaces bytes directly

proc main() =
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified.ab1"
  
  # Read the entire file into memory
  echo "Reading input file: ", inputFile
  let data = readFile(inputFile)
  
  # The target is the SMPL1 tag which starts at offset 231736
  # First byte is the length (11 for "raino_1-FOR"), followed by the actual string
  let offset = 231736
  
  # Show the current tag
  echo "Current tag at offset ", offset, ":"
  echo "  Length byte: ", ord(data[offset])
  echo "  Value: ", data[offset+1..<offset+1+ord(data[offset])]
  
  # Create a modified copy of the data
  var newData = data
  
  # Make sure our tag fits in the space available (original length was 11)
  var newValue = "NewSample"  # Length 9 - smaller than original 11
  echo "Changing tag to: ", newValue
  newData[offset] = char(newValue.len)  # New length byte
  
  # Write the new value
  for i in 0..<newValue.len:
    newData[offset+1+i] = newValue[i]
  
  # Write the modified data to the output file
  echo "Writing to output file: ", outputFile
  writeFile(outputFile, newData)
  
  echo "Done!"

when isMainModule:
  main()