import std/[os, strformat, strutils, parseopt]
import ./abif

## This module provides a command-line tool for merging two ABI trace files 
## (forward and reverse) into a single sequence.
##
## The abimerge tool uses Smith-Waterman local alignment to find the overlapping
## region between forward and reverse sequences, then merges them to create a 
## consensus sequence with improved accuracy.
##
## Command-line usage:
##
## .. code-block:: none
##   abimerge [options] <input_F.ab1> <input_R.ab1> [output.fastq]
##
## Options:
##   -h, --help                 Show help message
##   -m, --min-overlap INT      Minimum overlap length for merging (default: 20)
##   -o, --output STRING        Output file name (default: STDOUT)
##   -j, --join INT             Join with gap of INT Ns if no overlap detected
##   --score-match INT          Score for a match (default: 10)
##   --score-mismatch INT       Score for a mismatch (default: -8)
##   --score-gap INT            Score for a gap (default: -10)
##   --min-score INT            Minimum alignment score (default: 80)
##   --pct-id FLOAT             Minimum percentage identity (default: 85)
##
## Examples:
##
## .. code-block:: none
##   # Merge two ABIF files with default settings
##   abimerge forward.ab1 reverse.ab1 merged.fastq
##
##   # Merge with custom alignment parameters
##   abimerge --min-overlap 30 --score-match 12 forward.ab1 reverse.ab1 merged.fastq
##
##   # Join sequences with N gap if no overlap
##   abimerge -j 10 forward.ab1 reverse.ab1 merged.fastq

type
  swAlignment* = object
    ## Represents a Smith-Waterman alignment between two sequences.
    top*: string      ## The first sequence in the alignment
    bottom*: string   ## The second sequence in the alignment
    middle*: string   ## The alignment representation (|, ., or space)
    score*: int       ## The alignment score
    length*: int      ## The length of the alignment
    pctid*: float
    queryStart*, queryEnd*, targetStart*, targetEnd*: int

type
  swWeights* = object
    ## Scoring parameters for Smith-Waterman alignment.
    match*: int       ## Score for matching bases
    mismatch*: int    ## Penalty for mismatched bases
    gap*: int         ## Penalty for gap extension
    gapopening*: int  ## Penalty for opening a gap
    minscore*: int    ## Minimum score for accepting an alignment

let
  swDefaults* = swWeights(
    match:       6,
    mismatch:   -4,
    gap:        -6,
    gapopening: -6,
    minscore:    1 )


# Forward declarations
proc reverseString*(str: string): string

proc makeMatrix*[T](rows, cols: int, initValue: T): seq[seq[T]] =
  var result: seq[seq[T]] = newSeq[seq[T]](rows)
  for i in 0..<rows:
    result[i] = newSeq[T](cols)
    for j in 0..<cols:
      result[i][j] = initValue
  return result

# Reverse string
proc reverseString*(str: string): string =
  result = ""
  for index in countdown(str.high, 0):
    result.add(str[index])

proc simpleSmithWaterman*(alpha, beta: string, weights: swWeights): swAlignment =
  const
    cNone    = -1
    cUp      = 1
    cLeft    = 2
    cDiag    = 3
    mismatchChar = ' '
    matchChar    = '|'

  var
    swMatrix: seq[seq[int]]
    swHelper: seq[seq[int]]
    iMax, jMax, scoreMax = -1

  swMatrix = makeMatrix(len(alpha) + 1, len(beta) + 1, 0)
  swHelper = makeMatrix(len(alpha) + 1, len(beta) + 1, -1)

  for i in 0..len(alpha):
    for j in 0..len(beta):
      if i == 0 or j == 0:
        swMatrix[i][j] = 0
        swHelper[i][j] = cNone
      else:
        let
          score = if alpha[i - 1] == beta[j - 1]: weights.match
                 else: weights.mismatch
          top = swMatrix[i][j - 1] + weights.gap
          left = swMatrix[i - 1][j] + weights.gap
          diag = swMatrix[i - 1][j - 1] + score

        if diag < 0 and left < 0 and top < 0:
          swMatrix[i][j] = 0
          swHelper[i][j] = cNone
          continue

        if diag >= top:
          if diag >= left:
            swMatrix[i][j] = diag
            swHelper[i][j] = cDiag
          else:
            swMatrix[i][j] = left
            swHelper[i][j] = cLeft
        else:
          if top >= left:
            swMatrix[i][j] = top
            swHelper[i][j] = cUp
          else:
            swMatrix[i][j] = left
            swHelper[i][j] = cLeft

        if swMatrix[i][j] > scoreMax:
          scoreMax = swMatrix[i][j]
          iMax = i
          jMax = j


  # Find alignment (path)
  var
    matchString = ""
    alignString1 = ""
    alignString2 = ""
    I = iMax
    J = jMax
    matchCount, totCount = 0


  result.queryEnd    = 0
  result.targetEnd   = 0
  result.length      = 0
  result.score       = scoreMax

  if scoreMax < weights.minscore:
    return

  while true:
    if swHelper[I][J] == cNone:
      result.queryStart  = I
      result.targetStart = J
      result.queryEnd    += I
      result.targetEnd   += J
      break
    elif swHelper[I][J] == cDiag:
      alignString1 &= alpha[I-1]
      alignString2 &= beta[J-1]
      result.queryEnd += 1
      result.targetEnd += 1
      result.length += 1
      if alpha[I-1] == beta[J-1]:
        matchString  &= matchChar
        matchCount += 1
        totCount   += 1
      else:
        matchString  &= mismatchChar
        totCount   += 1
      I -= 1
      J -= 1

    elif swHelper[I][J] == cLeft:
      alignString1 &= alpha[I-1]
      alignString2 &= "-"
      matchString  &= " "
      result.queryEnd += 1
      I -= 1
      totCount   += 1
    else:
      alignString1 &= "-"
      matchString  &= " "
      alignString2 &= beta[J-1]
      result.targetEnd += 1
      J -= 1
      totCount   += 1


  result.top = reverseString(alignString1)
  result.bottom = reverseString(alignString2)
  result.middle = reverseString(matchString)
  result.pctid  = 100 * matchCount / totCount


proc translateIUPAC*(c: char): char =
  const
    inputBase = "ATUGCYRSWKMBDHVN"
    rcBase    = "TAACGRYSWMKVHDBN"
  let
    base = toUpperAscii(c)
  let o = inputBase.find(base)
  if o >= 0:
    return rcBase[o]
  else:
    return base

proc matchIUPAC*(a, b: char): bool =
  # a=primer; b=read
  let
    metachars = @['Y','R','S','W','K','M','B','D','H','V']

  if b == 'N':
    return false
  elif a == b or a == 'N':
    return true
  elif a in metachars:
    if a == 'Y' and (b == 'C' or b == 'T'):
      return true
    if a == 'R' and (b == 'A' or b == 'G'):
      return true
    if a == 'S' and (b == 'G' or b == 'C'):
      return true
    if a == 'W' and (b == 'A' or b == 'T'):
      return true
    if a == 'K' and (b == 'T' or b == 'G'):
      return true
    if a == 'M' and (b == 'A' or b == 'C'):
      return true
    if a == 'B' and (b != 'A'):
      return true
    if a == 'D' and (b != 'C'):
      return true
    if a == 'H' and (b != 'G'):
      return true
    if a == 'V' and (b != 'T'):
      return true
  return false


# Reverse complement
proc revcompl*(s: string): string =
  result = ""
  let rev = reverseString(s)
  for c in rev:
      result &= c.translateIUPAC

type
  Config* = object
    inputFileF*: string
    inputFileR*: string
    outputFile*: string
    minOverlap*: int
    scoreMatch*: int
    scoreMismatch*: int
    scoreGap*: int
    minScore*: int
    pctId*: float
    joinGap*: int
    verbose*: bool
    windowSize*: int     # Window size for quality trimming
    qualityThreshold*: int   # Quality threshold for trimming
    noTrim*: bool        # Whether to disable quality trimming
    showVersion*: bool   # Whether to show version information

proc printHelp() =
  echo """
abimerge - Merge forward and reverse AB1 trace files

Usage:
  abimerge [options] <input_F.ab1> <input_R.ab1> [output.fastq]

Options:
  -h, --help                 Show this help message
  -m, --min-overlap INT      Minimum overlap length for merging (default: 20)
  -o, --output STRING        Output file name (default: STDOUT)
  -j, --join INT             If no overlap is detected join the two sequences with a gap of INT Ns
                             (reverse complement the second sequence)
  Quality Trimming Options:
  -w, --window=INT           Window size for quality trimming (default: 4)
  -q, --quality=INT          Quality threshold 0-60 (default: 22)
  -n, --no-trim              Disable quality trimming

  Smith-Waterman options:
   --score-match INT         Score for a match [default: 10]
   --score-mismatch INT      Score for a mismatch [default: -8]
   --score-gap INT           Score for a gap [default: -10]
   --min-score INT           Minimum alignment score [default: 80]
   --pct-id FLOAT            Minimum percentage of identity [default: 85]
   -v, --verbose             Print additional information
   --version                 Show version information
"""
  quit(0)

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

proc parseCommandLine(): Config =
  var p = initOptParser(commandLineParams())
  result = Config(
    minOverlap: 20,
    scoreMatch: 10,
    scoreMismatch: -8,
    scoreGap: -10,
    minScore: 80,
    pctId: 85.0,
    joinGap: 0,
    verbose: false,
    outputFile: "",
    windowSize: 4,       # Default window size for quality trimming
    qualityThreshold: 22, # Default quality threshold
    noTrim: false,        # Enable trimming by default
    showVersion: false    # Don't show version by default
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
      of "m", "min-overlap":
        result.minOverlap = parseInt(val)
        if result.minOverlap < 1:
          echo "Error: Minimum overlap must be at least 1"
          quit(1)
      of "o", "output":
        result.outputFile = val
      of "j", "join":
        result.joinGap = parseInt(val)
        if result.joinGap < 0:
          echo "Error: Join gap must not be negative"
          quit(1)
      # Quality trimming options
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
      # Smith-Waterman options
      of "score-match":
        result.scoreMatch = parseInt(val)
      of "score-mismatch":
        result.scoreMismatch = parseInt(val)
      of "score-gap":
        result.scoreGap = parseInt(val)
      of "min-score":
        result.minScore = parseInt(val)
      of "pct-id":
        result.pctId = parseFloat(val)
        if result.pctId < 0 or result.pctId > 100:
          echo "Error: Percent identity must be between 0 and 100"
          quit(1)
      of "v", "verbose":
        result.verbose = true
      of "version":
        result.showVersion = true
      else:
        echo "Unknown option: ", key
        printHelp()
    of cmdEnd: assert(false)
  
  if result.showVersion:
    echo "abimerge ", abifVersion()
    quit(0)
    
  if fileArgs.len < 2:
    echo "Error: Both forward and reverse input files are required"
    printHelp()
  
  result.inputFileF = fileArgs[0]
  result.inputFileR = fileArgs[1]
  
  if fileArgs.len > 2:
    result.outputFile = fileArgs[2]

type
  ReadOrientation = enum
    Unknown, Innie, Outie, SameStrand

proc mergeSequences*(forwardSeq: string, forwardQual: seq[int], 
                     reverseSeq: string, reverseQual: seq[int],
                     config: Config): tuple[seq: string, qual: seq[int]] =
  # First, we'll try multiple alignments to determine the read orientation
  # Possibilities:
  # 1. Innie orientation (5'->3' and 3'<-5'):  ----> <---- (standard)
  # 2. Outie orientation (5'->3' and 5'->3'):  ----> ---->  (reverse is not reverse complemented)
  # 3. Same strand (3'<-5' and 3'<-5'):        <---- <---- (both should be reverse complemented)
  
  # Set up smith-waterman weights
  let weights = swWeights(
    match: config.scoreMatch,
    mismatch: config.scoreMismatch,
    gap: config.scoreGap,
    gapopening: config.scoreGap,
    minscore: config.minScore
  )
  
  # Prepare different sequence combinations for alignment
  let forwardSeqOrig = forwardSeq
  let reverseSeqOrig = reverseSeq
  let reverseSeqRC = revcompl(reverseSeq)
  let forwardSeqRC = revcompl(forwardSeq)
  
  # Create reversed quality arrays (same order as the revcompl sequences)
  var reverseQualReversed = newSeq[int](reverseQual.len)
  var forwardQualReversed = newSeq[int](forwardQual.len)
  
  for i in 0..<reverseQual.len:
    reverseQualReversed[i] = reverseQual[reverseQual.high - i]
  
  for i in 0..<forwardQual.len:
    forwardQualReversed[i] = forwardQual[forwardQual.high - i]
  
  # Try all possible alignments
  let alignInnie = simpleSmithWaterman(forwardSeqOrig, reverseSeqRC, weights)     # standard forward+revcomp(reverse)
  let alignOutie = simpleSmithWaterman(forwardSeqOrig, reverseSeqOrig, weights)   # forward+reverse (non-rc)
  let alignSameStrand = simpleSmithWaterman(forwardSeqRC, reverseSeqRC, weights)  # revcomp(forward)+revcomp(reverse)
  
  # Determine the best alignment score and corresponding orientation
  var bestScore = alignInnie.score
  var bestOrientation = ReadOrientation.Innie
  var bestAlignment = alignInnie
  
  if alignOutie.score > bestScore:
    bestScore = alignOutie.score
    bestOrientation = ReadOrientation.Outie
    bestAlignment = alignOutie
  
  if alignSameStrand.score > bestScore:
    bestScore = alignSameStrand.score
    bestOrientation = ReadOrientation.SameStrand
    bestAlignment = alignSameStrand
  
  if config.verbose:
    echo "Alignment scores for different orientations:"
    echo "  Innie (standard orientation): ", alignInnie.score
    echo "  Outie (forward-forward): ", alignOutie.score
    echo "  Same strand (reverse-reverse): ", alignSameStrand.score
    echo "Best orientation: ", bestOrientation
    
    echo "Smith-Waterman best alignment:"
    echo "Score: ", bestAlignment.score
    echo "Percent identity: ", bestAlignment.pctid, "%"
    echo "Query start: ", bestAlignment.queryStart, ", end: ", bestAlignment.queryEnd
    echo "Target start: ", bestAlignment.targetStart, ", end: ", bestAlignment.targetEnd
    echo "Alignment length: ", bestAlignment.length
    echo "Alignment:"
    echo bestAlignment.top
    echo bestAlignment.middle
    echo bestAlignment.bottom
  
  # Now define working sequences and qualities based on the best orientation
  var workingForwardSeq: string
  var workingReverseSeq: string
  var workingForwardQual: seq[int]
  var workingReverseQual: seq[int]
  
  case bestOrientation:
    of ReadOrientation.Innie:
      workingForwardSeq = forwardSeqOrig
      workingReverseSeq = reverseSeqRC
      workingForwardQual = forwardQual
      workingReverseQual = reverseQualReversed
      if config.verbose:
        echo "Using Innie orientation (standard: forward read and reverse complemented reverse read)"
    
    of ReadOrientation.Outie:
      workingForwardSeq = forwardSeqOrig
      workingReverseSeq = reverseSeqOrig
      workingForwardQual = forwardQual
      workingReverseQual = reverseQual
      if config.verbose:
        echo "Using Outie orientation (both reads in forward orientation)"
    
    of ReadOrientation.SameStrand:
      workingForwardSeq = forwardSeqRC
      workingReverseSeq = reverseSeqRC
      workingForwardQual = forwardQualReversed
      workingReverseQual = reverseQualReversed
      if config.verbose:
        echo "Using Same Strand orientation (both reads reverse complemented)"
    
    else:
      # Should never happen
      workingForwardSeq = forwardSeqOrig
      workingReverseSeq = reverseSeqRC
      workingForwardQual = forwardQual
      workingReverseQual = reverseQualReversed
  
  # Check if alignment meets criteria
  if bestScore < config.minScore or 
     bestAlignment.pctid < config.pctId or 
     bestAlignment.length < config.minOverlap:
    
    if config.verbose:
      echo "Alignment did not meet criteria for merging"
    
    # If no valid overlap and join gap is specified, concatenate with Ns
    if config.joinGap > 0:
      if config.verbose:
        echo "Joining sequences with ", config.joinGap, " Ns"
      
      # Join sequences based on the best orientation
      case bestOrientation:
        of ReadOrientation.Innie:
          result.seq = workingForwardSeq & repeat('N', config.joinGap) & workingReverseSeq
          result.qual = workingForwardQual
          for i in 0..<config.joinGap:
            result.qual.add(0)  # Add quality 0 for gap bases
          result.qual = result.qual & workingReverseQual
        of ReadOrientation.Outie:
          result.seq = workingForwardSeq & repeat('N', config.joinGap) & workingReverseSeq
          result.qual = workingForwardQual
          for i in 0..<config.joinGap:
            result.qual.add(0)  # Add quality 0 for gap bases
          result.qual = result.qual & workingReverseQual
        of ReadOrientation.SameStrand:
          result.seq = workingForwardSeq & repeat('N', config.joinGap) & workingReverseSeq
          result.qual = workingForwardQual
          for i in 0..<config.joinGap:
            result.qual.add(0)  # Add quality 0 for gap bases
          result.qual = result.qual & workingReverseQual
        else:
          # Default fallback
          result.seq = workingForwardSeq & repeat('N', config.joinGap) & workingReverseSeq
          result.qual = workingForwardQual
          for i in 0..<config.joinGap:
            result.qual.add(0)  # Add quality 0 for gap bases
          result.qual = result.qual & workingReverseQual
    else:
      # Return empty if no valid overlap and no join gap specified
      return (seq: "", qual: @[])
  
  else:
    # We have a valid overlap, merge the sequences
    # The merged sequence consists of:
    # 1. Non-overlapping part of the first sequence
    # 2. The overlapping region with consensus bases
    # 3. Non-overlapping part of the second sequence
    
    if config.verbose:
      echo "Merging with overlap:"
      echo "  Forward sequence positions: 0..", bestAlignment.queryStart, " + ", bestAlignment.queryStart, "..", bestAlignment.queryEnd
      echo "  Reverse sequence positions: 0..", bestAlignment.targetStart, " + ", bestAlignment.targetEnd, "..", workingReverseSeq.len

    # Initialize the merged sequence and quality arrays 
    var mergedSeq = ""
    var mergedQual: seq[int] = @[]
    
    # Important: We must consider that the Smith-Waterman alignment might start
    # in the middle of both sequences. We need to determine which non-overlapping
    # part to use at the beginning.
    
    if config.verbose:
      if bestAlignment.targetStart > 0:
        echo "  Found non-overlapping sequence at start of reverse read (bases 0..", bestAlignment.targetStart-1, ")"
      if bestAlignment.queryStart > 0:
        echo "  Found non-overlapping sequence at start of forward read (bases 0..", bestAlignment.queryStart-1, ")"
    
    # For all orientations, include the non-overlapping parts at the beginning
    
    # First, add the beginning of the reverse sequence (if it starts before the overlap)
    if bestAlignment.targetStart > 0:
      let reversePrefix = workingReverseSeq[0..<bestAlignment.targetStart]
      if config.verbose:
        echo "  Adding beginning of reverse sequence (", reversePrefix.len, " bases)"
      mergedSeq.add(reversePrefix)
      
      # Add quality scores for this segment
      if bestOrientation == ReadOrientation.Innie:  # Standard orientation with reverse complemented reverse read
        # For the quality scores in reverse complemented reads, we need to remap the indices
        for i in 0..<bestAlignment.targetStart:
          if i < workingReverseQual.len:
            mergedQual.add(workingReverseQual[i])
          else:
            mergedQual.add(0)  # Default quality if out of bounds
      else:  # Outie or SameStrand
        # For non-RC reads, quality scores are in the same order
        mergedQual.add(workingReverseQual[0..<min(bestAlignment.targetStart, workingReverseQual.len)])
        # Pad with zeros if needed
        if bestAlignment.targetStart > workingReverseQual.len:
          for i in 0..<(bestAlignment.targetStart - workingReverseQual.len):
            mergedQual.add(0)
    
    # Then, add the beginning of the forward sequence (if it starts before the overlap)
    if bestAlignment.queryStart > 0:
      let forwardPrefix = workingForwardSeq[0..<bestAlignment.queryStart]
      if config.verbose:
        echo "  Adding beginning of forward sequence (", forwardPrefix.len, " bases)"
      mergedSeq.add(forwardPrefix)
      
      # Add quality scores for this segment
      if bestOrientation == ReadOrientation.SameStrand: # Both reads RC'd
        # For the quality scores in reverse complemented reads, we need to remap the indices
        for i in 0..<bestAlignment.queryStart:
          if i < workingForwardQual.len:
            mergedQual.add(workingForwardQual[i])
          else:
            mergedQual.add(0)  # Default quality if out of bounds
      else:  # Innie or Outie
        # For non-RC reads, quality scores are in the same order
        mergedQual.add(workingForwardQual[0..<min(bestAlignment.queryStart, workingForwardQual.len)])
        # Pad with zeros if needed
        if bestAlignment.queryStart > workingForwardQual.len:
          for i in 0..<(bestAlignment.queryStart - workingForwardQual.len):
            mergedQual.add(0)
    
    # 2. Handle the overlapping region with consensus
    let fAlignStart = bestAlignment.queryStart
    let rAlignStart = bestAlignment.targetStart
    
    # Process the aligned region
    for i in 0..<bestAlignment.length:
      let fPos = fAlignStart + i
      let rPos = rAlignStart + i
      
      # Get the correct quality position based on orientation
      var forwardQualPos, reverseQualPos: int
      
      if bestOrientation == ReadOrientation.SameStrand:
        forwardQualPos = i  # Both reads RC'd, so quality is already flipped
      else:
        forwardQualPos = fPos  # Standard order
      
      if bestOrientation == ReadOrientation.Innie:
        reverseQualPos = i  # RC'd reverse read, quality is already flipped
      else:
        reverseQualPos = rPos  # Standard order
      
      if fPos < workingForwardSeq.len and rPos < workingReverseSeq.len:
        if workingForwardSeq[fPos] == workingReverseSeq[rPos]:
          # Bases match, use the base with higher quality
          mergedSeq.add(workingForwardSeq[fPos])
          
          if forwardQualPos < workingForwardQual.len and reverseQualPos < workingReverseQual.len:
            mergedQual.add(max(workingForwardQual[forwardQualPos], workingReverseQual[reverseQualPos]))
          elif forwardQualPos < workingForwardQual.len:
            mergedQual.add(workingForwardQual[forwardQualPos])
          elif reverseQualPos < workingReverseQual.len:
            mergedQual.add(workingReverseQual[reverseQualPos])
          else:
            mergedQual.add(0)  # Default quality if both out of bounds
        else:
          # Bases don't match, use the base with higher quality
          if forwardQualPos < workingForwardQual.len and reverseQualPos < workingReverseQual.len:
            if workingForwardQual[forwardQualPos] >= workingReverseQual[reverseQualPos]:
              mergedSeq.add(workingForwardSeq[fPos])
              mergedQual.add(workingForwardQual[forwardQualPos])
            else:
              mergedSeq.add(workingReverseSeq[rPos])
              mergedQual.add(workingReverseQual[reverseQualPos])
          elif forwardQualPos < workingForwardQual.len:
            mergedSeq.add(workingForwardSeq[fPos])
            mergedQual.add(workingForwardQual[forwardQualPos])
          elif reverseQualPos < workingReverseQual.len:
            mergedSeq.add(workingReverseSeq[rPos])
            mergedQual.add(workingReverseQual[reverseQualPos])
          else:
            mergedSeq.add('N')  # Default base if both out of bounds
            mergedQual.add(0)   # Default quality if both out of bounds
    
    # 3. Add non-aligned parts after the alignment
    
    # Add the trailing part of the reverse sequence
    if bestAlignment.targetEnd < workingReverseSeq.len:
      let rSuffix = workingReverseSeq[bestAlignment.targetEnd..<workingReverseSeq.len]
      if config.verbose:
        echo "  Adding trailing part of reverse sequence (", rSuffix.len, " bases)"
      mergedSeq.add(rSuffix)
      
      # Add quality scores for the reverse trailing part
      if bestOrientation == ReadOrientation.Innie:  # Standard orientation with RC'd reverse read
        # For the quality scores in reverse complemented reads, we need to remap the indices
        for i in 0..<rSuffix.len:
          let qualPos = workingReverseQual.len - (bestAlignment.targetEnd + i) - 1
          if qualPos >= 0 and qualPos < workingReverseQual.len:
            mergedQual.add(workingReverseQual[qualPos])
          else:
            mergedQual.add(0)  # Default quality if out of bounds
      else:  # Outie or SameStrand
        # For non-RC reads, quality scores are in the same order
        let qualStartPos = bestAlignment.targetEnd
        if qualStartPos < workingReverseQual.len:
          mergedQual.add(workingReverseQual[qualStartPos..<workingReverseQual.len])
        # Pad with zeros if needed
        if rSuffix.len > workingReverseQual.len - qualStartPos:
          for i in 0..<(rSuffix.len - (workingReverseQual.len - qualStartPos)):
            mergedQual.add(0)
      
    # Add the trailing part of the forward sequence 
    if bestAlignment.queryEnd < workingForwardSeq.len:
      let fSuffix = workingForwardSeq[bestAlignment.queryEnd..<workingForwardSeq.len]
      if config.verbose:
        echo "  Adding trailing part of forward sequence (", fSuffix.len, " bases)"
      mergedSeq.add(fSuffix)
      
      # Add quality scores for the forward trailing part
      if bestOrientation == ReadOrientation.SameStrand:
        # For RC'd reads, handle quality indices properly
        for i in 0..<fSuffix.len:
          let qualPos = workingForwardQual.len - (bestAlignment.queryEnd + i) - 1
          if qualPos >= 0 and qualPos < workingForwardQual.len:
            mergedQual.add(workingForwardQual[qualPos])
          else:
            mergedQual.add(0)
      else:
        # Standard orientation
        let qualStartPos = bestAlignment.queryEnd
        if qualStartPos < workingForwardQual.len:
          mergedQual.add(workingForwardQual[qualStartPos..<workingForwardQual.len])
        # Pad with zeros if needed
        if fSuffix.len > workingForwardQual.len - qualStartPos:
          for i in 0..<(fSuffix.len - (workingForwardQual.len - qualStartPos)):
            mergedQual.add(0)
    
    result.seq = mergedSeq
    result.qual = mergedQual

proc writeFastq(sequence: string, qualities: seq[int], name: string, outFile: string = "") =
  # Convert quality values to Phred+33 format
  var qualityString = ""
  for qv in qualities:
    qualityString.add(chr(qv + 33))
  
  let fastqContent = &"@{name}_merged\n{sequence}\n+\n{qualityString}"
  
  if outFile == "":
    # Write to stdout
    stdout.write(fastqContent & "\n")
  else:
    # Write to file
    writeFile(outFile, fastqContent & "\n")

proc main() =
  let config = parseCommandLine()
  
  if config.verbose:
    echo "Processing files:"
    echo "  Forward: ", config.inputFileF
    echo "  Reverse: ", config.inputFileR
    echo "  Output: ", if config.outputFile == "": "STDOUT" else: config.outputFile
    echo "Parameters:"
    echo "  Minimum overlap: ", config.minOverlap
    echo "  Match score: ", config.scoreMatch
    echo "  Mismatch score: ", config.scoreMismatch
    echo "  Gap score: ", config.scoreGap
    echo "  Minimum score: ", config.minScore
    echo "  Minimum percent identity: ", config.pctId, "%"
    if config.joinGap > 0:
      echo "  Join gap: ", config.joinGap, " Ns"
    echo "Quality trimming:"
    echo "  Window size: ", config.windowSize
    echo "  Quality threshold: ", config.qualityThreshold
    echo "  Trimming enabled: ", not config.noTrim
  
  try:
    # Load the forward trace
    let traceF = newABIFTrace(config.inputFileF)
    var seqF = traceF.getSequence()
    var qualF = traceF.getQualityValues()
    let nameF = traceF.getSampleName()
    
    # Load the reverse trace
    let traceR = newABIFTrace(config.inputFileR)
    var seqR = traceR.getSequence()
    var qualR = traceR.getQualityValues()
    let nameR = traceR.getSampleName()
    
    if config.verbose:
      echo "Original sequences:"
      echo "  Forward sequence length: ", seqF.len
      echo "  Reverse sequence length: ", seqR.len
      echo "  Forward sample name: ", nameF
      echo "  Reverse sample name: ", nameR
    
    # Quality trimming before merging
    if not config.noTrim:
      # Trim forward sequence
      let trimmedF = trimSequence(seqF, qualF, config.windowSize, config.qualityThreshold)
      seqF = trimmedF.seq
      qualF = trimmedF.qual
      
      # Trim reverse sequence
      let trimmedR = trimSequence(seqR, qualR, config.windowSize, config.qualityThreshold)
      seqR = trimmedR.seq
      qualR = trimmedR.qual
      
      if config.verbose:
        echo "After quality trimming:"
        echo "  Forward sequence length: ", seqF.len
        echo "  Reverse sequence length: ", seqR.len
      
      # Check if sequences are too short after trimming
      if seqF.len < config.windowSize or seqR.len < config.windowSize:
        echo "Error: Sequences too short after quality trimming."
        echo "Consider using -n/--no-trim to disable trimming or lowering the quality threshold."
        quit(1)
    
    # Merge the sequences
    let merged = mergeSequences(seqF, qualF, seqR, qualR, config)
    
    if merged.seq.len == 0:
      echo "Error: Failed to merge sequences. No valid overlap found."
      if config.joinGap == 0:
        echo "Consider using --join option to concatenate sequences."
      quit(1)
    
    if config.verbose:
      echo "Merged sequence length: ", merged.seq.len
    
    # Use sample name from forward read as the merged read name
    let mergedName = nameF
    
    # Write output FASTQ
    writeFastq(merged.seq, merged.qual, mergedName, config.outputFile)
    
    # Close traces
    traceF.close()
    traceR.close()
    
  except:
    echo "Error: ", getCurrentExceptionMsg()
    quit(1)

when isMainModule:
    main()