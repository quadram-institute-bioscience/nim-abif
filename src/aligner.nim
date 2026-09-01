## Shared local-alignment engine used by `abivalidate` and `abiscreen`.
##
## Extracted from `abivalidate.nim` so both tools share one Smith-Waterman
## implementation, one reverse-complement/orientation-retry strategy, and one
## IUPAC ambiguity-code decoder instead of duplicating them.

import std/[strutils, sequtils]
import readfx

type
  RefSequence* = object
    name*: string
    sequence*: string

  AlignmentResult* = object
    refName*: string
    refStart*: int
    refEnd*: int
    abiStart*: int
    abiEnd*: int
    score*: int
    identity*: float
    coverage*: float
    alignment*: string
    refAligned*: string
    abiAligned*: string
    isReverseComplement*: bool

  AlignConfig* = object
    minIdentity*: float
    minCoverage*: float
    scoreMatch*: int
    scoreMismatch*: int
    scoreGap*: int

proc defaultAlignConfig*(): AlignConfig =
  AlignConfig(minIdentity: 0.80, minCoverage: 0.90,
              scoreMatch: 10, scoreMismatch: -8, scoreGap: -10)

proc loadReference*(filename: string): seq[RefSequence] =
  ## Loads named sequences from a (multi-)FASTA file.
  result = @[]
  for record in readFQ(filename):
    result.add(RefSequence(name: record.name, sequence: record.sequence))

proc smithWaterman*(seq1, seq2: string, matchScore, mismatchScore, gapScore: int): AlignmentResult =
  ## Local alignment of seq2 against seq1 (typically reference, abi read).
  let m = seq1.len
  let n = seq2.len

  var matrix = newSeqWith(m + 1, newSeq[int](n + 1))
  var maxScore = 0
  var maxI = 0
  var maxJ = 0

  for i in 1..m:
    for j in 1..n:
      let match = if seq1[i-1] == seq2[j-1]: matchScore else: mismatchScore
      let diagonal = matrix[i-1][j-1] + match
      let up = matrix[i-1][j] + gapScore
      let left = matrix[i][j-1] + gapScore

      matrix[i][j] = max(0, max(diagonal, max(up, left)))

      if matrix[i][j] > maxScore:
        maxScore = matrix[i][j]
        maxI = i
        maxJ = j

  var alignedSeq1 = ""
  var alignedSeq2 = ""
  var alignment = ""
  var i = maxI
  var j = maxJ
  var matches = 0
  var alignLen = 0

  while i > 0 and j > 0 and matrix[i][j] > 0:
    let current = matrix[i][j]
    let diagonal = if i > 0 and j > 0: matrix[i-1][j-1] else: 0
    let up = if i > 0: matrix[i-1][j] else: 0
    let left {.used.} = if j > 0: matrix[i][j-1] else: 0

    let match = if seq1[i-1] == seq2[j-1]: matchScore else: mismatchScore

    if i > 0 and j > 0 and current == diagonal + match:
      alignedSeq1 = seq1[i-1] & alignedSeq1
      alignedSeq2 = seq2[j-1] & alignedSeq2
      if seq1[i-1] == seq2[j-1]:
        alignment = "|" & alignment
        inc matches
      else:
        alignment = "." & alignment
      inc alignLen
      dec i
      dec j
    elif i > 0 and current == up + gapScore:
      alignedSeq1 = seq1[i-1] & alignedSeq1
      alignedSeq2 = "-" & alignedSeq2
      alignment = " " & alignment
      inc alignLen
      dec i
    else:
      alignedSeq1 = "-" & alignedSeq1
      alignedSeq2 = seq2[j-1] & alignedSeq2
      alignment = " " & alignment
      inc alignLen
      dec j

  let identity = if alignLen > 0: matches.float / alignLen.float else: 0.0
  let coverage = alignedSeq2.replace("-", "").len.float / seq2.len.float

  result = AlignmentResult(
    refStart: i,
    refEnd: maxI - 1,
    abiStart: j,
    abiEnd: maxJ - 1,
    score: maxScore,
    identity: identity,
    coverage: coverage,
    alignment: alignment,
    refAligned: alignedSeq1,
    abiAligned: alignedSeq2
  )

proc reverseComplement*(sequence: string): string =
  ## Simple reverse complement function
  result = ""
  for i in countdown(sequence.len - 1, 0):
    case sequence[i].toUpperAscii:
    of 'A': result.add('T')
    of 'T': result.add('A')
    of 'C': result.add('G')
    of 'G': result.add('C')
    else: result.add('N')  # For ambiguous bases

proc findBestAlignment*(abiSeq: string, abiQual: seq[int], references: seq[RefSequence],
                         config: AlignConfig): (RefSequence, AlignmentResult, seq[int]) =
  ## Finds the best alignment of an ABI sequence against reference sequences.
  ##
  ## Tries forward orientation first, then reverse complement if no good
  ## alignment is found. Returns the best reference, alignment result, and
  ## the quality scores in the same orientation as the aligned sequence
  ## (reversed if reverse complement was used).
  var bestRef: RefSequence
  var bestAlignment: AlignmentResult
  var bestScore = -1
  var bestQual: seq[int] = abiQual

  # Try forward orientation first
  for refSeq in references:
    let alignment = smithWaterman(refSeq.sequence, abiSeq,
                                 config.scoreMatch, config.scoreMismatch, config.scoreGap)

    if alignment.score > bestScore and
       alignment.identity >= config.minIdentity and
       alignment.coverage >= config.minCoverage:
      bestScore = alignment.score
      bestRef = refSeq
      bestAlignment = alignment
      bestAlignment.refName = refSeq.name
      bestAlignment.isReverseComplement = false
      bestQual = abiQual

  # If no good alignment found, try reverse complement
  if bestScore == -1:
    let revCompSeq = reverseComplement(abiSeq)

    # Reverse quality scores to match the reverse-complemented sequence
    var revQual = newSeq[int](abiQual.len)
    for i in 0..<abiQual.len:
      revQual[i] = abiQual[abiQual.high - i]

    for refSeq in references:
      let alignment = smithWaterman(refSeq.sequence, revCompSeq,
                                   config.scoreMatch, config.scoreMismatch, config.scoreGap)

      if alignment.score > bestScore and
         alignment.identity >= config.minIdentity and
         alignment.coverage >= config.minCoverage:
        bestScore = alignment.score
        bestRef = refSeq
        bestAlignment = alignment
        bestAlignment.refName = refSeq.name
        bestAlignment.isReverseComplement = true
        bestQual = revQual

  if bestScore == -1:
    raise newException(ValueError, "No suitable alignment found")

  (bestRef, bestAlignment, bestQual)

proc iupacAlleles*(base: char): set[char] =
  ## Decodes an IUPAC nucleotide code into the set of alleles it represents.
  ## Unknown/invalid codes decode to the empty set.
  case base.toUpperAscii:
  of 'A': {'A'}
  of 'C': {'C'}
  of 'G': {'G'}
  of 'T': {'T'}
  of 'R': {'A', 'G'}
  of 'Y': {'C', 'T'}
  of 'S': {'G', 'C'}
  of 'W': {'A', 'T'}
  of 'K': {'G', 'T'}
  of 'M': {'A', 'C'}
  of 'B': {'C', 'G', 'T'}
  of 'D': {'A', 'G', 'T'}
  of 'H': {'A', 'C', 'T'}
  of 'V': {'A', 'C', 'G'}
  of 'N': {'A', 'C', 'G', 'T'}
  else: {}

proc isAmbiguousBaseCompatible*(ambiguousBase: char, refBase: char): bool =
  ## Check if an ambiguous base from ABI is compatible with reference base
  refBase.toUpperAscii in iupacAlleles(ambiguousBase)

proc isValidNucleotide*(base: char): bool =
  ## Check if base is a valid nucleotide (A, T, G, C)
  base.toUpperAscii in {'A', 'T', 'G', 'C'}
