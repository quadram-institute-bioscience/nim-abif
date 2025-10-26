import unittest
import strutils, os, streams
import ../src/abif

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

    test "Large directory offsets remain positive":
      proc setUint16BE(data: var string, pos: int, value: uint16) =
        data[pos] = chr(int(value shr 8))
        data[pos + 1] = chr(int(value and 0x00FF'u16))

      proc setUint32BE(data: var string, pos: int, value: uint32) =
        data[pos] = chr(int((value shr 24) and 0xFF'u32))
        data[pos + 1] = chr(int((value shr 16) and 0xFF'u32))
        data[pos + 2] = chr(int((value shr 8) and 0xFF'u32))
        data[pos + 3] = chr(int(value and 0xFF'u32))

      let tmpFile = "tests/tmp_large_offset.ab1"
      var contents = newString(64)
      for i in 0..<contents.len:
        contents[i] = '\0'

      contents[0] = 'A'
      contents[1] = 'B'
      contents[2] = 'I'
      contents[3] = 'F'

      setUint16BE(contents, 4, 1)
      setUint32BE(contents, 18, 1)
      setUint32BE(contents, 26, 32)

      let dirPos = 32
      contents[dirPos] = 'T'
      contents[dirPos + 1] = 'E'
      contents[dirPos + 2] = 'S'
      contents[dirPos + 3] = 'T'
      setUint32BE(contents, dirPos + 4, 1)
      setUint16BE(contents, dirPos + 8, uint16(ord(etLong)))
      setUint16BE(contents, dirPos + 10, 4)
      setUint32BE(contents, dirPos + 12, 2)
      setUint32BE(contents, dirPos + 16, 8)
      let largeOffset = 0x80000000'u32
      setUint32BE(contents, dirPos + 20, largeOffset)
      setUint32BE(contents, dirPos + 24, 0)

      writeFile(tmpFile, contents)

      var trace: ABIFTrace = nil
      try:
        trace = newABIFTrace(tmpFile)
        check trace.tags.hasKey("TEST1")
        let entry = trace.tags["TEST1"]
        check entry.dataOffset == int(largeOffset)
      finally:
        if trace != nil:
          trace.close()
        try:
          removeFile(tmpFile)
        except CatchableError:
          discard

when isMainModule:
  runTests()
