# Package information
packageName = "abif"
version     = "0.2.0"
author      = "Andrea Telatin, Claude AI"
description = "ABIF (Applied Biosystems Information Format) parser for DNA sequencing data"
license     = "MIT"

# Dependencies
requires "nim >= 1.6.0", "nimsvg >= 0.1.0"

srcDir = "src"
binDir = "bin"
namedBin = {
    "abi2fq":          "abi2fq",
    "abimerge":        "abimerge",
    "abimetadata":     "abimetadata",
    "abichromatogram": "abichromatogram" 
}.toTable()
# Skip directories that aren't part of the package
skipDirs = @["tests"]


# Tasks
task test, "Run the test suite":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abif.nim"
  exec "nim c -r tests/test_abi2fq.nim"
  exec "nim c -r tests/test_abimerge.nim"
  exec "nim c -r tests/test_edit_smpl.nim"

task test_edit, "Run abimetadata edit tests":
  exec "nim c -r tests/test_edit_smpl.nim"

task test_abif, "Run core library tests":
  exec "nim c -r tests/test_abif.nim"

task test_abi2fq, "Run abi2fq tool tests":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abi2fq.nim"

task test_abimerge, "Run abimerge tool tests":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abimerge.nim"

# Get Nim version by executing a nim command
proc getNimVersionStr(): string =
  # Run nim -v and get the first line
  let (output, _) = gorgeEx("nim -v")
  let firstLine = output.splitLines()[0]
  # Extract version number
  let parts = firstLine.split(" ")
  for part in parts:
    if part[0].isDigit:
      return part
  return ""

# Parse version string into a sequence of integers
proc parseVersionStr(version: string): seq[int] =
  result = @[]
  for part in version.split("."):
    try:
      result.add(parseInt(part))
    except ValueError:
      # Handle cases like "1.6.0-rc1" by ignoring non-numeric parts
      let numPart = part.split("-")[0]
      if numPart.len > 0:
        result.add(parseInt(numPart))
      else:
        result.add(0)
  # Ensure we have at least 3 components (major, minor, patch)
  while result.len < 3:
    result.add(0)

# Compare version numbers
proc versionAtLeast(version: seq[int], major, minor, patch: int): bool =
  if version.len < 3:
    return false
  if version[0] > major:
    return true
  if version[0] == major and version[1] > minor:
    return true
  if version[0] == major and version[1] == minor and version[2] >= patch:
    return true
  return false

# Get current Nim version
let nimVersionStr = getNimVersionStr()
let nimVersion = parseVersionStr(nimVersionStr)
let isNim2OrLater = versionAtLeast(nimVersion, 2, 0, 0)
task docs, "Generate documentation":
 
  if isNim2OrLater:
    exec "nim doc --project --out:docs src/abif.nim"
    exec "nim doc --project --out:docs src/abi2fq.nim"
    exec "nim doc --project --out:docs src/abimerge.nim"
    exec "nim doc --project --out:docs src/abimetadata.nim"

task buildbin, "Build all binaries to bin/ directory":
    exec "mkdir -p bin"
    exec "nim c -d:release --opt:speed -o:bin/abif           src/abif.nim"
    exec "nim c -d:release --opt:speed -o:bin/abi2fq         src/abi2fq.nim"
    exec "nim c -d:release --opt:speed -o:bin/abimerge       src/abimerge.nim"
    exec "nim c -d:release --opt:speed -o:bin/abimetadata    src/abimetadata.nim"
    exec "nim c -d:release --opt:speed -o:bin/abichromatogram  src/abichromatogram.nim"
    echo "Binaries built to bin/ directory"

# Before installing, compile the binaries
before install:
  # Install nimsvg dependency first to ensure it's available
  exec "nimble install -y nimsvg"
  exec "nim c -d:release -d:danger --opt:speed src/abif.nim"
  exec "nim c -d:release -d:danger --opt:speed src/abi2fq.nim"
  exec "nim c -d:release -d:danger --opt:speed src/abimerge.nim"
  exec "nim c -d:release -d:danger --opt:speed src/abimetadata.nim"
  exec "nim c -d:release -d:danger --opt:speed src/demo_svg_from_abi.nim"
