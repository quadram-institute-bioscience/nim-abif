import unittest
import strutils, os, streams
import ../abif

proc runTests() =
  suite "ABIF Trace Tests":
    
    test "Valid ABIF files should parse without errors":
      let validFiles = ["tests/3730.ab1", "tests/3100.ab1", "tests/310.ab1"]
      
      for file in validFiles:
        let trace = newABIFTrace(file)
        check trace != nil
        check trace.getSequence().len > 0
        check trace.getSampleName().len > 0
        
        # Check if the file starts with ABIF
        let stream = newFileStream(file)
        check stream != nil
        let signature = stream.readStr(4)
        check signature == "ABIF"
        stream.close()
        
        trace.close()
    
    test "Fake ABIF files should raise an IOError":
      let fakeFile = "tests/fake.ab1"
      expect IOError:
        discard newABIFTrace(fakeFile)
    
    test "Tag data access should work correctly":
      let trace = newABIFTrace("tests/3730.ab1")
      
      # Test some specific tag data
      check trace.getSequence().len > 0
      check trace.getSampleName().len > 0
      check trace.getQualityValues().len > 0
      
      # Check that sequence length matches quality values length
      check trace.getSequence().len == trace.getQualityValues().len
      
      # Check that we can get data from specific tags
      check trace.getData("PBAS2").len > 0
      check trace.getData("PCON2").len > 0
      
      trace.close()
    
    test "Test export functions":
      let trace = newABIFTrace("tests/3730.ab1")
      let testFastaFile = "test_output.fa"
      let testFastqFile = "test_output.fq"
      
      # Export as FASTA
      trace.exportFasta(testFastaFile)
      check fileExists(testFastaFile)
      
      # Export as FASTQ
      trace.exportFastq(testFastqFile)
      check fileExists(testFastqFile)
      
      # Clean up
      try:
        removeFile(testFastaFile)
        removeFile(testFastqFile)
      except CatchableError:
        discard
      
      trace.close()
    
    test "Test getTagNames function":
      let trace = newABIFTrace("tests/3730.ab1")
      let tagNames = trace.getTagNames()
      
      # Should have at least a few tags
      check tagNames.len > 0
      
      # Check for commonly expected tags
      var hasBaseTags = false
      for tag in tagNames:
        if tag.startsWith("PBAS") or tag.startsWith("DATA"):
          hasBaseTags = true
          break
      
      check hasBaseTags
      trace.close()

when isMainModule:
  runTests()