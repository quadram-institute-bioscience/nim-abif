import unittest
import os, strutils

proc projectRoot(): string =
  let currentDir = getCurrentDir()
  if currentDir.endsWith("tests"):
    parentDir(currentDir)
  else:
    currentDir

suite "docs chromatogram viewer":
  test "viewer is a portable single-page AB1 app":
    let htmlPath = projectRoot() / "docs" / "viewer.html"
    check fileExists(htmlPath)

    let html = readFile(htmlPath)
    check html.startsWith("<!doctype html>")
    check html.contains("id=\"file-input\"")
    check html.contains("id=\"trace-canvas\"")
    check html.contains("id=\"splitter\"")
    check html.contains("id=\"seq-text\"")
    check html.contains("function parseAbif")
    check html.contains("DATA9-DATA12")
    check html.contains("DATA1-DATA4")
    check html.contains("PBAS2")
    check html.contains("PCON2")
    check html.contains("PLOC2")
    check html.contains("centerOnBase")
    check html.contains("dragover")
    check html.contains("navigator.clipboard.writeText")
    check not html.contains("<script src=")
    check not html.contains("https://")
    check not html.contains("http://")

when isMainModule:
  discard
