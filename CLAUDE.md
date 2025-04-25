# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands
- Build all binaries: `nimble build` (or `nimble buildbin`) (outputs to bin/ directory)
- Build core binary: `nim c -d:release src/abif.nim`
- Build abi2fq: `nim c -d:release src/abi2fq.nim`
- Run ABIF converter: `./bin/abif [trace_file.ab1] [output_file]`
- Run FASTQ converter: `./bin/abi2fq [options] [trace_file.ab1] [output_file]`
- Run all tests: `nimble test`
- Run core tests: `nimble test_abif`
- Run abi2fq tests: `nimble test_abi2fq`
- Run single test: `nim c -r tests/test_abif.nim "Test Name"`
- Generate docs: `nimble docs`

## Code Style Guidelines
- **Imports**: Group standard library imports in brackets: `import std/[x, y, z]`
- **Formatting**: 2-space indentation, no trailing whitespace
- **Types**: Use descriptive type names with PascalCase; define proper enums
- **Naming**: camelCase for variables/procs, PascalCase for types/objects
- **Error Handling**: Use exceptions with descriptive messages
- **Binary I/O**: Always handle big-endian binary data correctly
- **Proc Signatures**: Public procedures should end with `*`
- **Documentation**: Document public APIs with comments
- **Memory Management**: Always close file streams after use