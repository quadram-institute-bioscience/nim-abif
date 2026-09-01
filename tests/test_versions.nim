import std/[os, osproc, streams, strutils, unittest]
import ../src/abif

type CommandResult = tuple[output, errors: string, exitCode: int]

proc projectRoot(): string =
  let currentDir = getCurrentDir()
  if currentDir.endsWith("tests"):
    parentDir(currentDir)
  else:
    currentDir

proc runCommand(command, workingDir: string, args: seq[string]): CommandResult =
  let process = startProcess(command, workingDir = workingDir, args = args,
    options = {poUsePath})
  result.output = process.outputStream.readAll()
  result.errors = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

suite "CLI version output":
  let root = projectRoot()
  let expectedVersion = abifVersion()
  type VersionCase = tuple[binary, expectedPrefix: string]
  let binaries: array[6, VersionCase] = [
    ("abi2fq", "abi2fq " & expectedVersion),
    ("abimerge", "abimerge " & expectedVersion),
    ("abimetadata", "abimetadata " & expectedVersion),
    ("abichromatogram", "abichromatogram version " & expectedVersion),
    ("abivalidate", "abivalidate " & expectedVersion),
    ("abiscreen", "abiscreen " & expectedVersion)
  ]

  for versionCase in binaries:
    test versionCase.binary & " reports the package version":
      let binPath = root / "bin" / (versionCase.binary & ExeExt)
      check fileExists(binPath)
      let command = runCommand(binPath, root, @["--version"])
      check command.exitCode == 0
      check (command.output & command.errors).strip().startsWith(versionCase.expectedPrefix)
