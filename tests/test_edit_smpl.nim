import std/[streams, os]
import ../src/abif
import ../src/abimetadata

proc testOriginalMethod() =
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified_original.ab1"
  let tagName = "SMPL1"
  let newValue = "NewSampleName"
  
  echo "TESTING ORIGINAL MODIFICATION METHOD - Modifying SMPL1"
  
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

proc testNewMethod() =
  let inputFile = "tests/bmr/01_F.ab1"
  let outputFile = "tests/modified_new.ab1"
  
  echo "\nTESTING NEW MODIFICATION METHOD"
  
  try:
    # Test case 1: Same-size modification (SMPL1)
    let trace1 = newABIFTrace(inputFile)
    let tagName1 = "SMPL1"
    let origValue1 = trace1.getData(tagName1)
    let newValue1 = "NewSample" # Roughly same length
    
    echo "Test 1: Same-size modification"
    echo "  Tag: ", tagName1
    echo "  Original value: ", origValue1
    echo "  New value: ", newValue1
    
    # Create a copy of the input file
    copyFile(inputFile, outputFile)
    
    # Modify the tag using our new implementation
    let result1 = modifyTag(trace1, tagName1, newValue1, outputFile)
    if result1:
      # Verify the change
      var modifiedTrace1 = newABIFTrace(outputFile)
      let modifiedValue1 = modifiedTrace1.getData(tagName1) 
      echo "  Result: Success"
      echo "  Modified value: ", modifiedValue1
      if modifiedValue1 == newValue1:
        echo "  PASS: Value matches expected"
      else:
        echo "  FAIL: Value doesn't match expected"
      modifiedTrace1.close()
    else:
      echo "  Result: Failed to modify tag"
    
    trace1.close()
    
    # Test case 2: Smaller modification
    let trace2 = newABIFTrace(inputFile)
    let tagName2 = "SMPL1" 
    let origValue2 = trace2.getData(tagName2)
    let newValue2 = "X" # Much shorter
    
    echo "\nTest 2: Smaller-size modification"
    echo "  Tag: ", tagName2
    echo "  Original value: ", origValue2
    echo "  New value: ", newValue2
    
    # Create a new copy of the input file
    removeFile(outputFile)
    copyFile(inputFile, outputFile)
    
    # Modify the tag
    let result2 = modifyTag(trace2, tagName2, newValue2, outputFile)
    if result2:
      # Verify the change
      var modifiedTrace2 = newABIFTrace(outputFile)
      let modifiedValue2 = modifiedTrace2.getData(tagName2)
      echo "  Result: Success"
      echo "  Modified value: ", modifiedValue2
      if modifiedValue2 == newValue2:
        echo "  PASS: Value matches expected"
      else:
        echo "  FAIL: Value doesn't match expected"
      modifiedTrace2.close()
    else:
      echo "  Result: Failed to modify tag"
    
    trace2.close()
    
    # Test case 3: Larger modification
    let trace3 = newABIFTrace(inputFile)
    let tagName3 = "SMPL1"
    let origValue3 = trace3.getData(tagName3)
    let newValue3 = "ThisIsAVeryLongSampleNameThatShouldRequireAppendingToTheEndOfTheFile"
    
    echo "\nTest 3: Larger-size modification"
    echo "  Tag: ", tagName3
    echo "  Original value: ", origValue3
    echo "  New value: ", newValue3
    
    # Create a new copy of the input file
    removeFile(outputFile)
    copyFile(inputFile, outputFile)
    
    # Modify the tag
    let result3 = modifyTag(trace3, tagName3, newValue3, outputFile)
    if result3:
      # Verify the change
      var modifiedTrace3 = newABIFTrace(outputFile)
      let modifiedValue3 = modifiedTrace3.getData(tagName3)
      echo "  Result: Success"
      echo "  Modified value: ", modifiedValue3
      if modifiedValue3 == newValue3:
        echo "  PASS: Value matches expected"
      else:
        echo "  FAIL: Value doesn't match expected"
      modifiedTrace3.close()
    else:
      echo "  Result: Failed to modify tag"
    
    trace3.close()
    
  except Exception as e:
    echo "Error: ", e.msg
    quit(1)

proc main() =
  # Uncomment to test original method
  # testOriginalMethod()
  
  # Test the new method
  testNewMethod()

when isMainModule:
  main()