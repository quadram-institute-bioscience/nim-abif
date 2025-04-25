import std/[streams, os]
import ../abif

proc main() =
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified.ab1"
  let tagName = "SMPL1"
  let newValue = "NewSampleName"
  
  echo "TESTING TAG MODIFICATION - Modifying SMPL1"
  
  try:
    var trace = newABIFTrace(inputFile)
    
    # Check if the tag exists by getting all tag names
    let tagNames = trace.getTagNames()
    if tagName in tagNames:
      echo "Original value of ", tagName, ": ", trace.getData(tagName)
      
      # Create a copy of the input file
      copyFile(trace.fileName, outputFile)
      
      # Open the output file for writing
      var outStream = newFileStream(outputFile, fmReadWrite)
      if outStream == nil:
        echo "Error: Could not open output file for writing"
        quit(1)
        
      # Since we can't directly access the tags table, we need to find the tag another way
      # For SMPL1, we know it's a PString type
      let entry = DirectoryEntry(tagName: "SMPL", tagNum: 1, elemType: etPString)
      echo "Tag offset: ", entry.dataOffset, ", Tag type: ", entry.elemType
      
      # Position at the data offset for this tag
      outStream.setPosition(entry.dataOffset)
      
      # For pString, write length byte first
      if entry.elemType == etPString:
        if newValue.len > 255:
          echo "Error: Pascal string cannot exceed 255 characters"
          outStream.close()
          quit(1)
        outStream.write(newValue.len.uint8)
        outStream.writeData(newValue.cstring, newValue.len)
      
      outStream.close()
      echo "Wrote new value to ", outputFile
      
      # Verify the change
      var modifiedTrace = newABIFTrace(outputFile)
      echo "New value: ", modifiedTrace.getData(tagName)
      modifiedTrace.close()
    else:
      echo "Error: Tag ", tagName, " not found in file"
      quit(1)
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()