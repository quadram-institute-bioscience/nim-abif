# Package information
packageName = "abif"
version     = "0.2.0"
author      = "Andrea Telatin, Claude AI"
description = "ABIF (Applied Biosystems Information Format) parser for DNA sequencing data"
license     = "MIT"

# Dependencies
requires "nim >= 1.6.0"
srcDir = "src"
binDir = "bin"
namedBin = {
    "abi2fq": "abi2fq",
    "abimerge": "abimerge",
    "abimetadata": "abimetadata"
}.toTable()
# Skip directories that aren't part of the package
skipDirs = @["tests"]


# Tasks
task test, "Run the test suite":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abif.nim"
  exec "nim c -r tests/test_abi2fq.nim"
  exec "nim c -r tests/test_abimerge.nim"

task test_abif, "Run core library tests":
  exec "nim c -r tests/test_abif.nim"

task test_abi2fq, "Run abi2fq tool tests":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abi2fq.nim"

task test_abimerge, "Run abimerge tool tests":
  exec "nimble buildbin"
  exec "nim c -r tests/test_abimerge.nim"

task docs, "Generate documentation":
  exec "nim doc --project --out:docs src/abif.nim"

task buildbin, "Build all binaries to bin/ directory":
    exec "mkdir -p bin"
    exec "nim c -d:release --opt:speed -o:bin/abif src/abif.nim"
    exec "nim c -d:release --opt:speed -o:bin/abi2fq src/abi2fq.nim"
    exec "nim c -d:release --opt:speed -o:bin/abimerge src/abimerge.nim"
    exec "nim c -d:release --opt:speed -o:bin/abimetadata src/abimetadata.nim"
    echo "Binaries built to bin/ directory"

# Binaries
#bin = @["abif", "src/abi2fq", "src/abimerge", "src/abimetadata"]

# Before installing, compile the binaries
before install:
  exec "nim c -d:release --opt:speed src/abif.nim"
  exec "nim c -d:release --opt:speed src/abi2fq.nim"
  exec "nim c -d:release --opt:speed src/abimerge.nim"
  exec "nim c -d:release --opt:speed src/abimetadata.nim"
