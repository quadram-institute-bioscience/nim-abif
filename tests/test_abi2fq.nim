import unittest
import os, osproc, streams, strutils
import ../src/abi2fq
import ../src/abif

type CommandResult = tuple[output, errors: string, exitCode: int]

proc runCommand(command, workingDir: string, args: seq[string]): CommandResult =
  let process = startProcess(command, workingDir = workingDir, args = args,
    options = {poUsePath})
  result.output = process.outputStream.readAll()
  result.errors = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

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

    test "verbose FASTA keeps stdout machine-readable":
      let command = runCommand(abi2fqPath, abifDir,
        @["--verbose", "--fasta", "tests/A_forward.ab1"])

      check command.exitCode == 0
      check command.output.startsWith(">A\n")
      check not command.output.contains("Input file:")
      check command.errors.contains("Input file: tests/A_forward.ab1")
      check command.errors.contains("Output: STDOUT")
      check command.errors.contains("Output format: FASTA")
      check command.errors.contains("Quality trimming: enabled")
      check command.errors.contains("Window size: 10")
      check command.errors.contains("Quality threshold: 20")
      check command.errors.contains("Sample name: A")
      check command.errors.contains("Sequence length:")
      check command.errors.contains("Quality score count:")
      check command.errors.contains("Trimmed sequence length:")

    test "sequence and quality lengths must match":
      expect ValueError:
        validateSequenceAndQualities("ACGT", @[30, 30, 30])

    test "FASTQ qualities must fit Phred+33":
      expect ValueError:
        writeFastq("A", @[94], "sample", fasta = false)

    test "quality-free untrimmed FASTA is supported":
      let outputPath = getTempDir() / "abi2fq-quality-free.fasta"
      writeFastq("ACGT", @[], "sample", outputPath, fasta = true)
      check readFile(outputPath) == ">sample\nACGT\n"
      removeFile(outputPath)

    test "ambiguity modes handle standard IUPAC codes":
      check maskAmbiguousBases("ACGTRYSWKMBDHVN") == "ACGTNNNNNNNNNNN"
      check enumerateAmbiguousBases("MR", 4) == @["AA", "AG", "CA", "CG"]
      expect ValueError:
        discard enumerateAmbiguousBases("NN", 15)

    test "record names are safe and have a fallback":
      check sanitizeRecordName("sample\nname\t1", "trace") == "samplename1"
      check sanitizeRecordName("", "trace") == "trace"

    test "no-trim preserves the original sequence before splitting":
      let trace = newABIFTrace("tests/A_forward.ab1")
      let sequence = trace.getSequence()
      let sampleName = trace.getSampleName()
      trace.close()

      let command = runCommand(abi2fqPath, abifDir,
        @["--no-trim", "--fasta", "--split", "tests/A_forward.ab1"])
      let split = splitAmbiguousBases(sequence)
      let expected = ">" & sampleName & "_1\n" & split.seq1 & "\n>" &
        sampleName & "_2\n" & split.seq2 & "\n"

      check command.exitCode == 0
      check command.errors.contains("Warning: --split assigns arbitrary phase")
      check command.output == expected

    test "minimum output length is enforced after trimming":
      let command = runCommand(abi2fqPath, abifDir,
        @["--no-trim", "--min-length=10000", "tests/A_forward.ab1"])
      check command.exitCode != 0
      check command.output.len == 0
      check command.errors.contains("is below the minimum of 10000")

    test "mask ambiguity mode and explicit name affect FASTA output":
      let trace = newABIFTrace("tests/A_forward.ab1")
      let expectedSequence = maskAmbiguousBases(trace.getSequence())
      trace.close()

      let command = runCommand(abi2fqPath, abifDir,
        @["--no-trim", "--fasta", "--ambiguity=mask", "--name=custom",
          "tests/A_forward.ab1"])
      check command.exitCode == 0
      check command.errors.len == 0
      check command.output == ">custom\n" & expectedSequence & "\n"

    test "enumeration limit prevents combinatorial output":
      let command = runCommand(abi2fqPath, abifDir,
        @["--no-trim", "--fasta", "--ambiguity=enumerate",
          "--max-variants=1", "tests/A_forward.ab1"])
      check command.exitCode != 0
      check command.output.len == 0
      check command.errors.contains("Ambiguity expansion exceeds the maximum of 1 variants")

    test "invalid invocations fail without writing stdout":
      let missingInput = runCommand(abi2fqPath, abifDir, @[])
      check missingInput.exitCode != 0
      check missingInput.output.len == 0
      check missingInput.errors.contains("Error: Input file required")

      let unknownOption = runCommand(abi2fqPath, abifDir, @["--unknown"])
      check unknownOption.exitCode != 0
      check unknownOption.output.len == 0
      check unknownOption.errors.contains("Error: Unknown option: unknown")

      let invalidWindow = runCommand(abi2fqPath, abifDir,
        @["--window=invalid", "tests/A_forward.ab1"])
      check invalidWindow.exitCode != 0
      check invalidWindow.output.len == 0
      check invalidWindow.errors.contains("Error: Invalid window size: invalid")

      let missingWindow = runCommand(abi2fqPath, abifDir,
        @["--window", "tests/A_forward.ab1"])
      check missingWindow.exitCode != 0
      check missingWindow.output.len == 0
      check missingWindow.errors.contains("Error: Window size requires a value")

      let invalidQuality = runCommand(abi2fqPath, abifDir,
        @["--quality=invalid", "tests/A_forward.ab1"])
      check invalidQuality.exitCode != 0
      check invalidQuality.output.len == 0
      check invalidQuality.errors.contains("Error: Invalid quality threshold: invalid")

      let missingQuality = runCommand(abi2fqPath, abifDir,
        @["--quality", "tests/A_forward.ab1"])
      check missingQuality.exitCode != 0
      check missingQuality.output.len == 0
      check missingQuality.errors.contains("Error: Quality threshold requires a value")

      let extraArgument = runCommand(abi2fqPath, abifDir,
        @["tests/A_forward.ab1", "output.fq", "extra"])
      check extraArgument.exitCode != 0
      check extraArgument.output.len == 0
      check extraArgument.errors.contains("Error: Too many positional arguments")

when isMainModule:
  runTests()
