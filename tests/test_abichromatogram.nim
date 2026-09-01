import unittest
import os, osproc, streams, strutils, times
import ../src/abif
import ../src/abichromatogram

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

proc ensureChromatogramBinary(abifDir, binPath: string) =
  let sourcePath = abifDir / "src" / "abichromatogram.nim"
  if fileExists(binPath) and
      getLastModificationTime(binPath) >= getLastModificationTime(sourcePath):
    return

  createDir(binPath.parentDir)
  let cacheDir = getTempDir() / "abif-test-abichromatogram-nimcache"
  let process = startProcess("nim", workingDir = abifDir, args = @[
    "c",
    "-d:release",
    "--opt:speed",
    "--nimcache:" & cacheDir,
    "-o:" & binPath,
    "src/abichromatogram.nim"
  ], options = {poUsePath})
  let output = process.outputStream.readAll()
  let errors = process.errorStream.readAll()
  let exitCode = process.waitForExit()
  process.close()

  doAssert exitCode == 0, output & errors

proc runTests() =
  let abifDir = projectRoot()
  let fixture = abifDir / "tests" / "A_forward.ab1"
  let binPath = abifDir / "bin" / ("abichromatogram" & ExeExt)

  suite "abichromatogram HTML output":
    test "HTML escaping is safe for generated text":
      check htmlEscape("<A&B \"sample\">") == "&lt;A&amp;B &quot;sample&quot;&gt;"

    test "renderer embeds the scrollable viewer without external dependencies":
      let trace = newABIFTrace(fixture)
      try:
        let data = getTraceData(trace)
        let html = renderChromatogramHtml(
          trace,
          data,
          fixture,
          width = 640,
          height = 320,
          startPos = 500,
          endPos = 900,
          downsample = 2,
          highlights = @[newHighlightRegion(620, 680)]
        )

        check html.startsWith("<!doctype html>")
        check html.contains("const TRACE = {")
        check html.contains("\"channels\":{\"A\":[")
        check html.contains("id=\"trace-canvas\"")
        check html.contains("id=\"splitter\"")
        check html.contains("id=\"seq-text\"")
        check html.contains("centerOnBase")
        check html.contains("Base order (FWO_1)")
        check html.contains("Trace channels")
        check html.contains("Trace metadata")
        check html.contains(htmlEscape(trace.getSampleName()))
        check not html.contains("https://")
      finally:
        trace.close()

    test "--html writes a portable HTML file without default SVG side effects":
      ensureChromatogramBinary(abifDir, binPath)
      let tmpDir = getTempDir() / "abichromatogram-html-only-test"
      if dirExists(tmpDir):
        removeDir(tmpDir)
      createDir(tmpDir)

      try:
        let htmlPath = tmpDir / "trace.html"
        let defaultSvgPath = tmpDir / "chromatogram.svg"
        let command = runCommand(binPath, tmpDir, @[
          fixture,
          "--html",
          htmlPath,
          "--width",
          "640",
          "--height",
          "320",
          "--highlight",
          "620-680"
        ])

        check command.exitCode == 0
        check command.errors.len == 0
        check command.output.contains("Exported HTML chromatogram to: " & htmlPath)
        check fileExists(htmlPath)
        check not fileExists(defaultSvgPath)

        let html = readFile(htmlPath)
        check html.contains("id=\"trace-canvas\"")
        check html.contains("id=\"splitter\"")
        check html.contains("centerOnBase")
        check html.contains("Trace metadata")
        check not html.contains("https://")
      finally:
        if dirExists(tmpDir):
          removeDir(tmpDir)

    test "--html can be combined with explicit SVG output":
      ensureChromatogramBinary(abifDir, binPath)
      let tmpDir = getTempDir() / "abichromatogram-html-and-svg-test"
      if dirExists(tmpDir):
        removeDir(tmpDir)
      createDir(tmpDir)

      try:
        let htmlPath = tmpDir / "trace.html"
        let svgPath = tmpDir / "trace.svg"
        let command = runCommand(binPath, tmpDir, @[
          fixture,
          "-o",
          svgPath,
          "--html",
          htmlPath,
          "--width",
          "640",
          "--height",
          "320"
        ])

        check command.exitCode == 0
        check command.errors.len == 0
        check command.output.contains("Exported SVG chromatogram to: " & svgPath)
        check command.output.contains("Exported HTML chromatogram to: " & htmlPath)
        check fileExists(htmlPath)
        check fileExists(svgPath)
        check readFile(htmlPath).contains("id=\"trace-canvas\"")
        check readFile(svgPath).contains("<svg")
      finally:
        if dirExists(tmpDir):
          removeDir(tmpDir)

when isMainModule:
  runTests()
