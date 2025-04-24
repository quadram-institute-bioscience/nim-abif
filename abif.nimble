# Package information
packageName = "abif"
version     = "0.1.0"
author      = "Claude AI"
description = "ABIF (Applied Biosystems Information Format) parser for DNA sequencing data"
license     = "MIT"

# Dependencies
requires "nim >= 1.6.0"

# Skip directories that aren't part of the package
skipDirs = @["tests"]

# Tasks
task test, "Run the test suite":
  exec "nim c -o:tests/test_abif -r tests/test_abif.nim"
  exec "nim c -o:tests/test_abi2fq -r tests/test_abi2fq.nim"

task test_abif, "Run core library tests":
  exec "nim c -o:tests/test_abif -r tests/test_abif.nim"

task test_abi2fq, "Run abi2fq tool tests":
  exec "nim c -o:tests/test_abi2fq -r tests/test_abi2fq.nim"

task docs, "Generate documentation":
  exec "nim doc --project --out:docs abif.nim"

task build, "Build all binaries":
  exec "nim c -d:release --opt:speed -o:bin/abif abif.nim"
  exec "nim c -d:release --opt:speed -o:bin/abi2fq src/abi2fq.nim"

# Binaries
bin = @["bin/abif", "bin/abi2fq"]

# Before installing, compile the binaries
before install:
  exec "nim c -d:release --opt:speed -o:bin/abif abif.nim"
  exec "nim c -d:release --opt:speed -o:bin/abi2fq src/abi2fq.nim"
