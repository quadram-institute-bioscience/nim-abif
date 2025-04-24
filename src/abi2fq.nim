import std/[os, strformat, strutils, parseopt]
import ./abif
#import nimabif/packageinfo  # For NimblePkgVersion

type
  Config = object
    inFile: string
    outFile: string
    windowSize: int
    qualityThreshold: int
    noTrim: bool
    verbose: bool
    showVersion: bool

proc printHelp() =
  echo """
abi2fq - Convert ABI files to FASTQ with quality trimming

Usage:
  abi2fq [options] <input.ab1> [output.fq]

Options:
  -h, --help                 Show this help message
  -w, --window=INT           Window size for quality trimming (default: 10)
  -q, --quality=INT          Quality threshold 0-60 (default: 20)
  -n, --no-trim              Disable quality trimming
  -v, --verbose              Print additional information
  --version                  Show version information

If output file is not specified, FASTQ will be written to STDOUT.
"""
  quit(0)

proc parseCommandLine(): Config =
  var p = initOptParser(commandLineParams())
  result = Config(
    windowSize: 10,
    qualityThreshold: 20,
    noTrim: false,
    verbose: false,
    showVersion: false
  )
  
  var fileArgs: seq[string] = @[]
  
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      fileArgs.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        printHelp()
      of "w", "window":
        result.windowSize = parseInt(val)
        if result.windowSize < 1:
          echo "Error: Window size must be at least 1"
          quit(1)
      of "q", "quality":
        result.qualityThreshold = parseInt(val)
        if result.qualityThreshold < 0 or result.qualityThreshold > 60:
          echo "Error: Quality threshold must be between 0 and 60"
          quit(1)
      of "n", "no-trim":
        result.noTrim = true
      of "v", "verbose":
        result.verbose = true
      of "version":
        result.showVersion = true
      else:
        echo "Unknown option: ", key
        printHelp()
    of cmdEnd: assert(false)
  
  if result.showVersion:
    echo "abi2fq ", abifVersion()
    quit(0)
    
  if fileArgs.len < 1:
    echo "Error: Input file required"
    printHelp()
  
  result.inFile = fileArgs[0]
  if fileArgs.len > 1:
    result.outFile = fileArgs[1]

proc trimSequence(sequence: string, qualities: seq[int], 
                  windowSize: int, threshold: int): tuple[seq: string, qual: seq[int]] =
  # Check if sequence is too short for trimming
  if sequence.len < windowSize or qualities.len < windowSize:
    return (sequence, qualities)
  
  var startPos, endPos = 0
  
  # Find start position (trim low quality from beginning)
  for i in 0 .. (sequence.len - windowSize):
    var windowSum = 0
    for j in 0 ..< windowSize:
      windowSum += qualities[i + j]
    
    let windowAvg = windowSum / windowSize
    if windowAvg >= threshold.float:
      startPos = i
      break
  
  # Find end position (trim low quality from end)
  for i in countdown(sequence.len - windowSize, 0):
    var windowSum = 0
    for j in 0 ..< windowSize:
      windowSum += qualities[i + j]
    
    let windowAvg = windowSum / windowSize
    if windowAvg >= threshold.float:
      endPos = i + windowSize
      break
  
  # Handle case where entire sequence is below threshold
  if endPos <= startPos:
    return ("", @[])
  
  result.seq = sequence[startPos ..< endPos]
  result.qual = qualities[startPos ..< endPos]

proc writeFastq(sequence: string, qualities: seq[int], name: string, outFile: string = "") =
  # Convert quality values to Phred+33 format
  var qualityString = ""
  for qv in qualities:
    qualityString.add(chr(qv + 33))
  
  let fastqContent = &"@{name}\n{sequence}\n+\n{qualityString}"
  
  if outFile == "":
    # Write to stdout
    stdout.write(fastqContent & "\n")
  else:
    # Write to file
    writeFile(outFile, fastqContent & "\n")

proc main() =
  let config = parseCommandLine()
  
  if config.verbose:
    echo &"Processing file: {config.inFile}"
    echo &"Window size: {config.windowSize}"
    echo &"Quality threshold: {config.qualityThreshold}"
    echo &"Trimming: {not config.noTrim}"
  
  try:
    let trace = newABIFTrace(config.inFile)
    let sequence = trace.getSequence()
    let qualities = trace.getQualityValues()
    let sampleName = trace.getSampleName()
    
    if config.verbose:
      echo &"Sample name: {sampleName}"
      echo &"Original sequence length: {sequence.len}"
    
    if sequence.len == 0:
      echo "Error: No sequence data found in file"
      quit(1)
    
    if config.noTrim:
      # No trimming, use original sequence
      writeFastq(sequence, qualities, sampleName, config.outFile)
    else:
      # Trim low quality ends
      let trimmed = trimSequence(sequence, qualities, config.windowSize, config.qualityThreshold)
      
      if config.verbose:
        echo &"Trimmed sequence length: {trimmed.seq.len}"
        if trimmed.seq.len == 0:
          echo "Warning: Entire sequence was below quality threshold"
      
      writeFastq(trimmed.seq, trimmed.qual, sampleName, config.outFile)
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()