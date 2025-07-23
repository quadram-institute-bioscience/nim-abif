import std/[os, strformat, strutils, parseopt, tables]
import ./abif

## This module provides a command-line tool for converting ABIF files to FASTQ or FASTA format
## with optional quality trimming.
## 
## The abi2fq tool extracts sequence and quality data from ABIF files,
## applies quality trimming to remove low-quality regions, and outputs
## in the standard FASTQ format or FASTA format (if --fasta is specified).
##
## Command-line usage:
##
## .. code-block:: none
##   abi2fq [options] <input.ab1> [output.fq]
##
## Options:
##   -h, --help                 Show help message
##   -w, --window=INT           Window size for quality trimming (default: 10)
##   -q, --quality=INT          Quality threshold 0-60 (default: 20)
##   -n, --no-trim              Disable quality trimming
##   -v, --verbose              Print additional information
##   --version                  Show version information
##   --fasta                    Output in FASTA format instead of FASTQ
##   -s, --split                Split ambiguous bases into two sequences
##
## Examples:
##
## .. code-block:: none
##   # Convert with default quality trimming
##   abi2fq input.ab1 output.fastq
##
##   # Convert without quality trimming
##   abi2fq -n input.ab1 output.fastq
##
##   # Convert with custom quality parameters
##   abi2fq -w 20 -q 30 input.ab1 output.fastq
##
##   # Convert to FASTA format
##   abi2fq --fasta input.ab1 output.fasta
##
##   # Split ambiguous bases into two sequences
##   abi2fq -s input.ab1 output.fastq

type
  Config* = object
    ## Configuration for the abi2fq tool.
    ## Contains command-line options and settings.
    inFile*: string         ## Path to the input ABIF file
    outFile*: string        ## Path to the output FASTQ file (or empty for stdout)
    windowSize*: int        ## Window size for quality trimming (default: 10)
    qualityThreshold*: int  ## Quality threshold 0-60 (default: 20)
    noTrim*: bool           ## Whether to disable quality trimming
    verbose*: bool          ## Whether to show verbose output
    showVersion*: bool      ## Whether to show version information
    fasta*: bool            ## Whether to output in FASTA format instead of FASTQ
    split*: bool            ## Whether to split ambiguous bases into two sequences

proc printHelp*() =
  ## Displays the help message for the abi2fq tool.
  ## Exits the program after displaying the message.
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
  --fasta                    Output in FASTA format instead of FASTQ
  -s, --split                Split ambiguous bases into two sequences

If output file is not specified, FASTQ will be written to STDOUT.
"""
  quit(0)

proc parseCommandLine*(): Config =
  ## Parses command-line arguments and returns a Config object.
  ##
  ## This procedure:
  ## - Initializes Config with default values
  ## - Processes command-line arguments
  ## - Validates parameter values
  ## - Handles special flags like --version and --help
  ##
  ## Returns:
  ##   A Config object with settings based on command-line arguments
  var p = initOptParser(commandLineParams())
  result = Config(
    windowSize: 10,
    qualityThreshold: 20,
    noTrim: false,
    verbose: false,
    showVersion: false,
    fasta: false,
    split: false
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
        if val.len > 0:
          result.qualityThreshold = parseInt(val)
          if result.qualityThreshold < 0 or result.qualityThreshold > 60:
            echo "Error: Quality threshold must be between 0 and 60"
            quit(1)
        else:
          echo "Error: Quality threshold requires a value"
          quit(1)
      of "n", "no-trim":
        result.noTrim = true
      of "v", "verbose":
        result.verbose = true
      of "version":
        result.showVersion = true
      of "fasta":
        result.fasta = true
      of "s", "split":
        result.split = true
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

proc trimSequence*(sequence: string, qualities: seq[int], 
                  windowSize: int, threshold: int): tuple[seq: string, qual: seq[int]] =
  ## Trims low-quality regions from the beginning and end of a sequence.
  ##
  ## Uses a sliding window approach to identify regions where the average
  ## quality score is below the threshold.
  ##
  ## Parameters:
  ##   sequence: The DNA sequence to trim
  ##   qualities: Quality scores for each base in the sequence
  ##   windowSize: Size of the sliding window for quality assessment
  ##   threshold: Quality threshold (bases with qualities below this are trimmed)
  ##
  ## Returns:
  ##   A tuple containing the trimmed sequence and its quality values
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

proc writeFastq*(sequence: string, qualities: seq[int], name: string, outFile: string = "", fasta: bool = false, splitSeq1: string = "", splitSeq2: string = "") =
  ## Writes sequence and quality data to a FASTQ or FASTA file.
  ##
  ## If outFile is empty, the data is written to stdout.
  ## If fasta is true, the output will be in FASTA format instead of FASTQ.
  ## If splitSeq1 and splitSeq2 are not empty, writes them as two separate records.
  ##
  ## Parameters:
  ##   sequence: The DNA sequence to write (used when not splitting)
  ##   qualities: Quality scores for each base in the sequence
  ##   name: The sample name for the header
  ##   outFile: Path to the output file (empty string for stdout)
  ##   fasta: Whether to output in FASTA format instead of FASTQ
  ##   splitSeq1: First sequence when splitting ambiguous bases
  ##   splitSeq2: Second sequence when splitting ambiguous bases
  
  var content: string
  
  # Create quality string
  var qualityString = ""
  for qv in qualities:
    qualityString.add(chr(qv + 33))
  
  if splitSeq1 != "" and splitSeq2 != "":
    # Output split sequences
    if fasta:
      content = &">{name}_1\n{splitSeq1}\n>{name}_2\n{splitSeq2}"
    else:
      content = &"@{name}_1\n{splitSeq1}\n+\n{qualityString}\n@{name}_2\n{splitSeq2}\n+\n{qualityString}"
  else:
    # Output single sequence
    if fasta:
      content = &">{name}\n{sequence}"
    else:
      content = &"@{name}\n{sequence}\n+\n{qualityString}"
  
  if outFile == "":
    # Write to stdout
    stdout.write(content & "\n")
  else:
    # Write to file
    writeFile(outFile, content & "\n")

proc splitAmbiguousBases*(sequence: string): tuple[seq1: string, seq2: string] =
  ## Splits ambiguous bases into two sequences.
  ##
  ## Splits sequence at every ambiguous base that represents exactly 2 alternatives.
  ## IUPAC ambiguity codes:
  ## - R = A or G
  ## - Y = C or T
  ## - S = G or C
  ## - W = A or T
  ## - K = G or T
  ## - M = A or C
  ##
  ## Parameters:
  ##   sequence: The DNA sequence to split
  ##
  ## Returns:
  ##   A tuple containing the two split sequences
  
  # Define mapping of ambiguity codes to their nucleotide options
  let ambiguityMap = {
    'R': @['A', 'G'],
    'Y': @['C', 'T'],
    'S': @['G', 'C'],
    'W': @['A', 'T'],
    'K': @['G', 'T'],
    'M': @['A', 'C']
  }.toTable
  
  var seq1 = ""
  var seq2 = ""
  
  for base in sequence:
    if base in ambiguityMap and ambiguityMap[base].len == 2:
      # Ambiguous base with exactly 2 options
      seq1.add(ambiguityMap[base][0])
      seq2.add(ambiguityMap[base][1])
    else:
      # Non-ambiguous or other ambiguous base
      seq1.add(base)
      seq2.add(base)
  
  return (seq1, seq2)

proc main*() =
  ## Main entry point for the abi2fq program.
  ##
  ## Handles command-line parsing, reads the input ABIF file,
  ## performs quality trimming if enabled, and outputs the result
  ## in FASTQ or FASTA format (depending on the --fasta option).
  let config = parseCommandLine()
  
  if config.verbose:
    echo &"Processing file: {config.inFile}"
    echo &"Window size: {config.windowSize}"
    echo &"Quality threshold: {config.qualityThreshold}"
    echo &"Trimming: {not config.noTrim}"
    echo &"Split ambiguous bases: {config.split}"
    if config.fasta:
      echo "Output format: FASTA"
    else:
      echo "Output format: FASTQ"
  
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
      # No trimming, but identify sections that would be trimmed and make them lowercase
      let trimmed = trimSequence(sequence, qualities, config.windowSize, config.qualityThreshold)
      
      if config.verbose:
        if trimmed.seq.len == 0:
          echo "Warning: Entire sequence was below quality threshold"
        elif trimmed.seq.len < sequence.len:
          echo &"Sections that would be trimmed: {sequence.len - trimmed.seq.len} bases"
          
      # Get indices for low quality regions
      var modifiedSeq = ""
      if trimmed.seq.len == 0:  # All sequence is below threshold
        modifiedSeq = sequence.toLowerAscii()
      else:
        # Find start position (same logic as in trimSequence)
        var startPos = 0
        for i in 0 .. (sequence.len - config.windowSize):
          var windowSum = 0
          for j in 0 ..< config.windowSize:
            windowSum += qualities[i + j]
          
          let windowAvg = windowSum / config.windowSize
          if windowAvg >= config.qualityThreshold.float:
            startPos = i
            break
        
        # Find end position (same logic as in trimSequence)
        var endPos = sequence.len
        for i in countdown(sequence.len - config.windowSize, 0):
          var windowSum = 0
          for j in 0 ..< config.windowSize:
            windowSum += qualities[i + j]
          
          let windowAvg = windowSum / config.windowSize
          if windowAvg >= config.qualityThreshold.float:
            endPos = i + config.windowSize
            break
        
        # Make trimmed regions lowercase
        if startPos > 0:
          modifiedSeq.add(sequence[0 ..< startPos].toLowerAscii())
        
        modifiedSeq.add(sequence[startPos ..< endPos])
        
        if endPos < sequence.len:
          modifiedSeq.add(sequence[endPos ..< sequence.len].toLowerAscii())
      
      if config.split:
        let split = splitAmbiguousBases(modifiedSeq)
        if config.verbose:
          echo "Splitting ambiguous bases into two sequences"
        writeFastq(modifiedSeq, qualities, sampleName, config.outFile, config.fasta, split.seq1, split.seq2)
      else:
        writeFastq(modifiedSeq, qualities, sampleName, config.outFile, config.fasta)
    else:
      # Trim low quality ends
      let trimmed = trimSequence(sequence, qualities, config.windowSize, config.qualityThreshold)
      
      if config.verbose:
        echo &"Trimmed sequence length: {trimmed.seq.len}"
        if trimmed.seq.len == 0:
          echo "Warning: Entire sequence was below quality threshold"
      
      if config.split:
        let split = splitAmbiguousBases(trimmed.seq)
        if config.verbose:
          echo "Splitting ambiguous bases into two sequences"
        writeFastq(trimmed.seq, trimmed.qual, sampleName, config.outFile, config.fasta, split.seq1, split.seq2)
      else:
        writeFastq(trimmed.seq, trimmed.qual, sampleName, config.outFile, config.fasta)
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()