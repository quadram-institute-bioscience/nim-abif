import unittest
import os, osproc, strutils

proc runTests() =
  suite "abi2fq Tests":
    
    test "abi2fq should handle valid ABI files":
      let validFile = "tests/3730.ab1"
      let outputFile = "tests/output.fq"
      
      # First build abi2fq if not present
      if not fileExists("../bin/abi2fq"):
        discard execCmd("nimble build")
      
      # Run abi2fq with the test file
      let exitCode = execCmd("../bin/abi2fq " & validFile & " " & outputFile)
      check exitCode == 0
      
      # Check that the output file exists
      check fileExists(outputFile)
      
      # Check the content of the output file
      let content = readFile(outputFile)
      check content.len > 0
      check content.startsWith("@")
      check content.contains("\n+\n")
      
      # Clean up
      removeFile(outputFile)
    
    test "abi2fq should handle quality trimming":
      let validFile = "tests/3730.ab1"
      let outputNoTrim = "tests/output_notrim.fq"
      let outputTrim = "tests/output_trim.fq"
      
      # First build abi2fq if not present
      if not fileExists("../bin/abi2fq"):
        discard execCmd("nimble build")
      
      # Run without trimming
      discard execCmd("../bin/abi2fq --no-trim " & validFile & " " & outputNoTrim)
      
      # Run with stringent trimming (high quality threshold)
      discard execCmd("../bin/abi2fq --quality=40 --window=20 " & validFile & " " & outputTrim)
      
      # Check that both files exist
      check fileExists(outputNoTrim)
      check fileExists(outputTrim)
      
      # The trimmed sequence should be shorter than the untrimmed one
      let contentNoTrim = readFile(outputNoTrim)
      let contentTrim = readFile(outputTrim)
      
      # Extract sequences from FASTQ format
      let seqNoTrim = contentNoTrim.splitLines()[1]
      let seqTrim = contentTrim.splitLines()[1]
      
      check seqTrim.len <= seqNoTrim.len
      
      # Clean up
      removeFile(outputNoTrim)
      removeFile(outputTrim)
    
    test "abi2fq should handle invalid files gracefully":
      let invalidFile = "tests/fake.ab1"
      
      # First build abi2fq if not present
      if not fileExists("../bin/abi2fq"):
        discard execCmd("nimble build")
      
      # Run with invalid file, should exit with non-zero status
      let exitCode = execCmd("../bin/abi2fq " & invalidFile)
      check exitCode != 0

when isMainModule:
  runTests()