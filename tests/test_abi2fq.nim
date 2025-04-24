import unittest
import os, osproc, strutils

proc runTests() =
  # Get absolute path to the project root directory
  let currentDir = getCurrentDir()
  let abifDir = if currentDir.endsWith("tests"): parentDir(currentDir) else: currentDir
  echo "ABIF directory: ", abifDir
  
  let binDir = abifDir / "bin"
  let abi2fqPath = binDir / "abi2fq"
  echo "Binary path: ", abi2fqPath
  
  suite "abi2fq Tests":
    
    test "abi2fq binary exists":
      # Build the binary
      let buildCmd = "cd " & abifDir & " && nimble buildbin"
      echo "Running build command: ", buildCmd
      discard execCmd(buildCmd)
      
      # Check if the binary exists
      check fileExists(abi2fqPath)
    

when isMainModule:
  runTests()