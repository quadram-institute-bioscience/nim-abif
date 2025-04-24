import unittest
import os, osproc, strutils

proc runTests() =
  # Get absolute path to the bin directory with abif as parent
  let abifDir = "/Users/telatina/git/abif"
  echo "ABIF directory: ", abifDir
  
  let binDir = abifDir / "bin"
  let abi2fqPath = binDir / "abi2fq"
  echo "Binary path: ", abi2fqPath
  
  suite "abi2fq Tests":
    
    test "abi2fq binary exists":
      # Build the binary
      discard execCmd("cd " & abifDir & " && nimble buildbin")
      
      # Check if the binary exists
      check fileExists(abi2fqPath)
    

when isMainModule:
  runTests()