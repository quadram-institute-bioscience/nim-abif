import std/[os, strformat, strutils, parseopt]
import ./abif
export abif.sanitizeRecordName
import ./qualitytrim

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
##   -s, --split                Emit two arbitrarily phased sequences (legacy)
##   --min-length=INT           Minimum output length after trimming (default: 1)
##   --ambiguity=MODE           preserve, mask, or enumerate (default: preserve)
##   --max-variants=INT         Maximum enumerated sequences (default: 256)
##   --name=ID                  Override the output record name
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
##
##   # Mask ambiguity codes without trimming
##   abi2fq --no-trim --ambiguity=mask input.ab1 output.fastq
##
##   # Enumerate ambiguity combinations, with a safety limit
##   abi2fq --fasta --ambiguity=enumerate --max-variants=64 input.ab1 output.fasta
##
##   # Reject reads shorter than 100 bases after trimming
##   abi2fq --min-length=100 input.ab1 output.fastq

type
  AmbiguityMode* = enum
    ## Controls how IUPAC ambiguity codes are represented in output sequences.
    amPreserve, amMask, amEnumerate

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
    split*: bool            ## Whether to use legacy arbitrary two-sequence phasing
    minLength*: int         ## Minimum sequence length after trimming
    ambiguityMode*: AmbiguityMode ## How to handle IUPAC ambiguity codes
    maxVariants*: int       ## Maximum number of enumerated ambiguity variants
    recordName*: string     ## Optional output record name override

proc printHelp*(exitCode: int = 0) =
  ## Displays the help message for the abi2fq tool.
  ## Exits the program after displaying the message.
  stderr.writeLine("""
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
  -s, --split                Emit two arbitrarily phased sequences (legacy)
  --min-length=INT           Minimum output length after trimming (default: 1)
  --ambiguity=MODE           preserve, mask, or enumerate (default: preserve)
  --max-variants=INT         Maximum enumerated sequences (default: 256)
  --name=ID                  Override the output record name

If output file is not specified, sequence output is written to STDOUT.
Untrimmed FASTA conversion does not require quality scores.
""")
  quit(exitCode)

proc quitWithError(message: string) =
  stderr.writeLine("Error: " & message)
  quit(1)

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
    split: false,
    minLength: 1,
    ambiguityMode: amPreserve,
    maxVariants: 256
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
        if val.len == 0:
          quitWithError("Window size requires a value")
        try:
          result.windowSize = parseInt(val)
        except ValueError:
          quitWithError("Invalid window size: " & val)
        if result.windowSize < 1:
          quitWithError("Window size must be at least 1")
      of "q", "quality":
        if val.len > 0:
          try:
            result.qualityThreshold = parseInt(val)
          except ValueError:
            quitWithError("Invalid quality threshold: " & val)
          if result.qualityThreshold < 0 or result.qualityThreshold > 60:
            quitWithError("Quality threshold must be between 0 and 60")
        else:
          quitWithError("Quality threshold requires a value")
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
      of "min-length":
        if val.len == 0:
          quitWithError("Minimum length requires a value")
        try:
          result.minLength = parseInt(val)
        except ValueError:
          quitWithError("Invalid minimum length: " & val)
        if result.minLength < 0:
          quitWithError("Minimum length must be at least 0")
      of "ambiguity":
        case val.toLowerAscii()
        of "preserve": result.ambiguityMode = amPreserve
        of "mask": result.ambiguityMode = amMask
        of "enumerate": result.ambiguityMode = amEnumerate
        else: quitWithError("Ambiguity mode must be preserve, mask, or enumerate")
      of "max-variants":
        if val.len == 0:
          quitWithError("Maximum variants requires a value")
        try:
          result.maxVariants = parseInt(val)
        except ValueError:
          quitWithError("Invalid maximum variants: " & val)
        if result.maxVariants < 1:
          quitWithError("Maximum variants must be at least 1")
      of "name":
        if val.len == 0:
          quitWithError("Record name requires a value")
        result.recordName = val
      else:
        stderr.writeLine("Error: Unknown option: " & key)
        printHelp(1)
    of cmdEnd: assert(false)
  
  if result.showVersion:
    stderr.writeLine("abi2fq " & abifVersion())
    quit(0)
    
  if fileArgs.len < 1:
    stderr.writeLine("Error: Input file required")
    printHelp(1)
  if fileArgs.len > 2:
    quitWithError("Too many positional arguments")
  if result.split and result.ambiguityMode != amPreserve:
    quitWithError("--split cannot be combined with --ambiguity")
  
  result.inFile = fileArgs[0]
  if fileArgs.len > 1:
    result.outFile = fileArgs[1]

proc validateSequenceAndQualities*(sequence: string, qualities: seq[int]) =
  ## Ensures every called base has a corresponding quality score.
  if sequence.len != qualities.len:
    raise newException(ValueError,
      &"Sequence and quality lengths differ ({sequence.len} bases, {qualities.len} quality scores)")

proc validateQualityRange*(qualities: seq[int]) =
  ## Ensures quality scores can be represented using standard Phred+33 FASTQ.
  for i, quality in qualities:
    if quality < 0 or quality > 93:
      raise newException(ValueError,
        &"Quality score at position {i + 1} is outside the FASTQ range 0-93: {quality}")

proc writeRecords(sequences: seq[string], qualities: seq[int], name: string,
                  outFile: string, fasta: bool) =
  var content = ""
  var qualityString = ""
  let safeName = sanitizeRecordName(name, "unnamed")

  if not fasta:
    validateQualityRange(qualities)
    for quality in qualities:
      qualityString.add(chr(quality + 33))

  for i, sequence in sequences:
    if not fasta:
      validateSequenceAndQualities(sequence, qualities)
    let recordName = if sequences.len == 1: safeName else: safeName & "_" & $(i + 1)
    if content.len > 0:
      content.add('\n')
    if fasta:
      content.add(&">{recordName}\n{sequence}")
    else:
      content.add(&"@{recordName}\n{sequence}\n+\n{qualityString}")

  if outFile == "":
    stdout.write(content & "\n")
  else:
    writeFile(outFile, content & "\n")

proc writeFastq*(sequence: string, qualities: seq[int], name: string, outFile: string = "", fasta: bool = false, splitSeq1: string = "", splitSeq2: string = "") =
  ## Writes sequence and quality data to a FASTQ or FASTA file.
  ##
  ## If outFile is empty, the data is written to stdout.
  ## If fasta is true, the output will be in FASTA format instead of FASTQ.
  ## If splitSeq1 and splitSeq2 are not empty, writes them as two separate records.
  ##
  ## Parameters:
  ##   sequence: The DNA sequence to write (used when not splitting)
  ##   qualities: Quality scores for each base; optional for FASTA output
  ##   name: The sample name for the header
  ##   outFile: Path to the output file (empty string for stdout)
  ##   fasta: Whether to output in FASTA format instead of FASTQ
  ##   splitSeq1: First sequence when splitting ambiguous bases
  ##   splitSeq2: Second sequence when splitting ambiguous bases
  
  if splitSeq1 != "" and splitSeq2 != "":
    writeRecords(@[splitSeq1, splitSeq2], qualities, name, outFile, fasta)
  else:
    writeRecords(@[sequence], qualities, name, outFile, fasta)

proc splitAmbiguousBases*(sequence: string): tuple[seq1: string, seq2: string] =
  ## Splits ambiguous bases into two sequences.
  ##
  ## This legacy operation assigns arbitrary phase when multiple ambiguous positions
  ## are present. Prefer maskAmbiguousBases or enumerateAmbiguousBases when phase is
  ## unknown. Splits every ambiguous base that represents exactly two alternatives.
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
  
  result = ("", "")
  for base in sequence:
    let alternatives = case base.toUpperAscii()
      of 'R': "AG"
      of 'Y': "CT"
      of 'S': "GC"
      of 'W': "AT"
      of 'K': "GT"
      of 'M': "AC"
      else: ""
    if alternatives.len == 2:
      result.seq1.add(alternatives[0])
      result.seq2.add(alternatives[1])
    else:
      result.seq1.add(base)
      result.seq2.add(base)

proc maskAmbiguousBases*(sequence: string): string =
  ## Replaces standard IUPAC ambiguity codes with N.
  const AmbiguousBases = {'R', 'Y', 'S', 'W', 'K', 'M', 'B', 'D', 'H', 'V', 'N'}
  for base in sequence:
    if base.toUpperAscii() in AmbiguousBases:
      result.add('N')
    else:
      result.add(base)

proc ambiguityAlternatives(base: char): string =
  case base.toUpperAscii()
  of 'R': "AG"
  of 'Y': "CT"
  of 'S': "GC"
  of 'W': "AT"
  of 'K': "GT"
  of 'M': "AC"
  of 'B': "CGT"
  of 'D': "AGT"
  of 'H': "ACT"
  of 'V': "ACG"
  of 'N': "ACGT"
  else: $base

proc enumerateAmbiguousBases*(sequence: string, maxVariants: int): seq[string] =
  ## Expands all standard IUPAC alternatives up to maxVariants sequences.
  if maxVariants < 1:
    raise newException(ValueError, "Maximum variants must be at least 1")

  result = @[""]
  for base in sequence:
    let alternatives = ambiguityAlternatives(base)
    if result.len > maxVariants div alternatives.len:
      raise newException(ValueError,
        &"Ambiguity expansion exceeds the maximum of {maxVariants} variants")
    var expanded = newSeqOfCap[string](result.len * alternatives.len)
    for prefix in result:
      for alternative in alternatives:
        expanded.add(prefix & alternative)
    result = expanded

proc main*() =
  ## Main entry point for the abi2fq program.
  ##
  ## Handles command-line parsing, reads the input ABIF file,
  ## performs quality trimming if enabled, and outputs the result
  ## in FASTQ or FASTA format (depending on the --fasta option).
  let config = parseCommandLine()
  
  if config.verbose:
    let outputDestination = if config.outFile == "": "STDOUT" else: config.outFile
    let outputFormat = if config.fasta: "FASTA" else: "FASTQ"
    let trimmingStatus = if config.noTrim: "disabled" else: "enabled"
    let ambiguityMode = case config.ambiguityMode
      of amPreserve: "preserve"
      of amMask: "mask"
      of amEnumerate: "enumerate"
    stderr.writeLine(&"Input file: {config.inFile}")
    stderr.writeLine(&"Output: {outputDestination}")
    stderr.writeLine(&"Output format: {outputFormat}")
    stderr.writeLine(&"Quality trimming: {trimmingStatus}")
    stderr.writeLine(&"Window size: {config.windowSize}")
    stderr.writeLine(&"Quality threshold: {config.qualityThreshold}")
    stderr.writeLine(&"Minimum output length: {config.minLength}")
    stderr.writeLine(&"Ambiguity mode: {ambiguityMode}")
    if config.ambiguityMode == amEnumerate:
      stderr.writeLine(&"Maximum variants: {config.maxVariants}")
    stderr.writeLine(&"Split ambiguous bases: {config.split}")
  
  try:
    let trace = newABIFTrace(config.inFile)
    defer: trace.close()
    let sequence = trace.getSequence()
    let qualities = trace.getQualityValues()
    let configuredName = if config.recordName.len > 0: config.recordName else: trace.getSampleName()
    let sampleName = sanitizeRecordName(configuredName, splitFile(config.inFile).name)

    if not (config.fasta and config.noTrim):
      validateSequenceAndQualities(sequence, qualities)
    
    if config.verbose:
      stderr.writeLine(&"Sample name: {sampleName}")
      stderr.writeLine(&"Sequence length: {sequence.len}")
      stderr.writeLine(&"Quality score count: {qualities.len}")
    
    if sequence.len == 0:
      stderr.writeLine("Error: No sequence data found in file")
      quit(1)
    
    var outputSequence: string
    var outputQualities: seq[int]
    if config.noTrim:
      outputSequence = sequence
      outputQualities = qualities
    else:
      let trimmed = trimSequence(sequence, qualities, config.windowSize, config.qualityThreshold)
      outputSequence = trimmed.seq
      outputQualities = trimmed.qual
      if config.verbose:
        stderr.writeLine(&"Trimmed sequence length: {trimmed.seq.len}")

    if outputSequence.len < config.minLength:
      raise newException(ValueError,
        &"Output sequence length {outputSequence.len} is below the minimum of {config.minLength}")

    var outputSequences: seq[string]
    if config.split:
      stderr.writeLine("Warning: --split assigns arbitrary phase across ambiguous positions")
      let split = splitAmbiguousBases(outputSequence)
      outputSequences = @[split.seq1, split.seq2]
    else:
      case config.ambiguityMode
      of amPreserve:
        outputSequences = @[outputSequence]
      of amMask:
        outputSequences = @[maskAmbiguousBases(outputSequence)]
      of amEnumerate:
        outputSequences = enumerateAmbiguousBases(outputSequence, config.maxVariants)

    if config.verbose:
      stderr.writeLine(&"Output records: {outputSequences.len}")
      stderr.writeLine(&"Record name: {sampleName}")
    writeRecords(outputSequences, outputQualities, sampleName, config.outFile, config.fasta)
    
  except:
    stderr.writeLine("Error: " & getCurrentExceptionMsg())
    quit(1)

when isMainModule:
  main()
