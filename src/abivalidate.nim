import std/[os, strformat, strutils, parseopt, sequtils, times, algorithm]
import readfx
import ./abif

## This module provides a command-line tool for validating ABI sequences against
## a reference FASTA file using Smith-Waterman alignment and variant calling.
##
## The abivalidate tool loads reference sequences from a FASTA file, then aligns
## each ABI sequence against the references to find the best match. If no suitable
## alignment is found in the forward orientation, it automatically tries the 
## reverse complement. It performs variant calling and outputs results in VCF format.
##
## Command-line usage:
##
## .. code-block:: none
##   abivalidate -r reference.fasta -o output.vcf file1.ab1 file2.ab1 ...
##
## Options:
##   -r, --reference FILE       Reference FASTA file (required)
##   -o, --output FILE          Output VCF file (required)
##   -h, --help                 Show help message
##   --version                  Show version information
##   --min-identity FLOAT       Minimum alignment identity (default: 0.80)
##   --min-coverage FLOAT       Minimum coverage of ABI sequence (default: 0.90)
##   --score-match INT          Score for match (default: 10)
##   --score-mismatch INT       Score for mismatch (default: -8)
##   --score-gap INT            Score for gap (default: -10)
##   -v, --verbose              Verbose output
##   -t, --table                Output summary table

type
  Config = object
    referenceFile: string
    outputFile: string
    abiFiles: seq[string]
    minIdentity: float
    minCoverage: float
    scoreMatch: int
    scoreMismatch: int
    scoreGap: int
    verbose: bool
    summaryTable: bool

  RefSequence = object
    name: string
    sequence: string

  AlignmentResult = object
    refName: string
    refStart: int
    refEnd: int
    abiStart: int
    abiEnd: int
    score: int
    identity: float
    coverage: float
    alignment: string
    refAligned: string
    abiAligned: string

  Variant = object
    chrom: string
    pos: int
    refAllele: string
    altAllele: string
    quality: float
    sample: string
  
  AlignmentSummary = object
    sampleName: string
    refName: string
    refStart: int
    refEnd: int
    identity: float
    coverage: float
    variants: int
    isReverseComplement: bool

proc showHelp() =
  echo """
abivalidate - Validate ABI sequences against reference FASTA

Usage:
  abivalidate -r reference.fasta -o output.vcf file1.ab1 [file2.ab1 ...]

Options:
  -r, --reference FILE       Reference FASTA file (required)
  -o, --output FILE          Output VCF file (required)
  -h, --help                 Show this help message
  --version                  Show version information
  --min-identity FLOAT       Minimum alignment identity (default: 0.80)
  --min-coverage FLOAT       Minimum coverage of ABI sequence (default: 0.90)
  --score-match INT          Score for match (default: 10)
  --score-mismatch INT       Score for mismatch (default: -8)
  --score-gap INT            Score for gap (default: -10)
  -v, --verbose              Verbose output
  -t, --table                Output summary table

Examples:
  abivalidate -r reference.fa -o variants.vcf sample1.ab1 sample2.ab1
  abivalidate -r ref.fa -o out.vcf --min-identity 0.85 *.ab1
  abivalidate -r ref.fa -o out.vcf --table *.ab1
"""

proc showVersion() =
  echo fmt"abivalidate {abifVersion()}"

proc parseArgs(): Config =
  result = Config(
    minIdentity: 0.80,
    minCoverage: 0.90,
    scoreMatch: 10,
    scoreMismatch: -8,
    scoreGap: -10,
    verbose: false,
    summaryTable: false
  )
  
  var p = initOptParser(commandLineParams())
  
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "r", "reference":
        result.referenceFile = p.val
      of "o", "output":
        result.outputFile = p.val
      of "h", "help":
        showHelp()
        quit(0)
      of "version":
        showVersion()
        quit(0)
      of "min-identity":
        result.minIdentity = parseFloat(p.val)
      of "min-coverage":
        result.minCoverage = parseFloat(p.val)
      of "score-match":
        result.scoreMatch = parseInt(p.val)
      of "score-mismatch":
        result.scoreMismatch = parseInt(p.val)
      of "score-gap":
        result.scoreGap = parseInt(p.val)
      of "v", "verbose":
        result.verbose = true
      of "t", "table":
        result.summaryTable = true
      else:
        echo fmt"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      result.abiFiles.add(p.key)

  if result.referenceFile == "":
    echo "Error: Reference file (-r) is required"
    quit(1)
  if result.outputFile == "":
    echo "Error: Output file (-o) is required"
    quit(1)
  if result.abiFiles.len == 0:
    echo "Error: At least one ABI file is required"
    quit(1)

proc loadReference(filename: string): seq[RefSequence] =
  result = @[]
  for record in readFQ(filename):
    result.add(RefSequence(name: record.name, sequence: record.sequence))

proc smithWaterman(seq1, seq2: string, matchScore, mismatchScore, gapScore: int): AlignmentResult =
  let m = seq1.len
  let n = seq2.len
  
  # Initialize scoring matrix
  var matrix = newSeqWith(m + 1, newSeq[int](n + 1))
  var maxScore = 0
  var maxI = 0
  var maxJ = 0
  
  # Fill scoring matrix
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
  
  # Traceback to get alignment
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
    let left = if j > 0: matrix[i][j-1] else: 0
    
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

proc reverseComplement(seq: string): string =
  ## Simple reverse complement function
  result = ""
  for i in countdown(seq.len - 1, 0):
    case seq[i].toUpperAscii:
    of 'A': result.add('T')
    of 'T': result.add('A')
    of 'C': result.add('G')
    of 'G': result.add('C')
    else: result.add('N')  # For ambiguous bases

proc findBestAlignment(abiSeq: string, references: seq[RefSequence], config: Config): (RefSequence, AlignmentResult) =
  var bestRef: RefSequence
  var bestAlignment: AlignmentResult
  var bestScore = -1
  
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
  
  # If no good alignment found, try reverse complement
  if bestScore == -1:
    let revCompSeq = reverseComplement(abiSeq)
    
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
  
  if bestScore == -1:
    raise newException(ValueError, "No suitable alignment found")
  
  (bestRef, bestAlignment)

proc isAmbiguousBaseCompatible(ambiguousBase: char, refBase: char): bool =
  ## Check if an ambiguous base from ABI is compatible with reference base
  case ambiguousBase.toUpperAscii:
  of 'R': refBase.toUpperAscii in {'A', 'G'}  # A or G
  of 'Y': refBase.toUpperAscii in {'C', 'T'}  # C or T
  of 'S': refBase.toUpperAscii in {'G', 'C'}  # G or C
  of 'W': refBase.toUpperAscii in {'A', 'T'}  # A or T
  of 'K': refBase.toUpperAscii in {'G', 'T'}  # G or T
  of 'M': refBase.toUpperAscii in {'A', 'C'}  # A or C
  of 'B': refBase.toUpperAscii in {'C', 'G', 'T'}  # not A
  of 'D': refBase.toUpperAscii in {'A', 'G', 'T'}  # not C
  of 'H': refBase.toUpperAscii in {'A', 'C', 'T'}  # not G
  of 'V': refBase.toUpperAscii in {'A', 'C', 'G'}  # not T
  of 'N': true  # N matches anything
  else: false

proc isValidNucleotide(base: char): bool =
  ## Check if base is a valid nucleotide (A, T, G, C)
  base.toUpperAscii in {'A', 'T', 'G', 'C'}

proc callVariants(alignment: AlignmentResult, sampleName: string): seq[Variant] =
  result = @[]
  var refPos = alignment.refStart
  
  # Simple approach: only call SNVs, skip complex indels for now
  for i in 0..<alignment.refAligned.len:
    let refBase = alignment.refAligned[i]
    let abiBase = alignment.abiAligned[i]
    
    if refBase != '-' and abiBase != '-':
      # Both bases present - check for SNV
      let refUpper = refBase.toUpperAscii
      let abiUpper = abiBase.toUpperAscii
      
      # Only process valid nucleotides
      if isValidNucleotide(refUpper) and isValidNucleotide(abiUpper):
        if refUpper != abiUpper:
          # Check if it's an ambiguous base that's compatible
          if not isAmbiguousBaseCompatible(abiUpper, refUpper):
            # Real SNV - not compatible ambiguous base
            result.add(Variant(
              chrom: alignment.refName,
              pos: refPos + 1,  # VCF is 1-based
              refAllele: $refUpper,
              altAllele: $abiUpper,
              quality: 60.0,
              sample: sampleName
            ))
      
      # Always increment reference position for non-gap reference bases
      inc refPos
    elif refBase != '-':
      # Reference has base, ABI has gap - still increment ref position
      inc refPos
    # For ABI insertions (refBase == '-'), don't increment refPos

proc writeVCF(variants: seq[Variant], outputFile: string, referenceFile: string) =
  var file = open(outputFile, fmWrite)
  defer: file.close()
  
  # Write VCF header
  file.writeLine("##fileformat=VCFv4.2")
  file.writeLine("##fileDate=" & now().format("yyyyMMdd"))
  file.writeLine(fmt"##source=abivalidate-{abifVersion()}")
  file.writeLine(fmt"##reference={referenceFile}")
  
  # Format fields
  file.writeLine("##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">")
  file.writeLine("##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Read Depth\">")
  
  # Get unique samples
  let samples = variants.mapIt(it.sample).deduplicate().sorted()
  
  # Group variants by position and alleles to avoid duplicates
  var variantMap: seq[tuple[chrom: string, pos: int, refAllele: string, altAllele: string, samples: seq[string]]] = @[]
  
  for variant in variants:
    let key = (variant.chrom, variant.pos, variant.refAllele, variant.altAllele)
    var found = false
    
    for i in 0..<variantMap.len:
      if variantMap[i].chrom == key[0] and variantMap[i].pos == key[1] and 
         variantMap[i].refAllele == key[2] and variantMap[i].altAllele == key[3]:
        variantMap[i].samples.add(variant.sample)
        found = true
        break
    
    if not found:
      variantMap.add((key[0], key[1], key[2], key[3], @[variant.sample]))
  
  # Write header line
  let headerCols = @["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"] & samples
  file.writeLine(headerCols.join("\t"))
  
  # Write consolidated variant records
  for varEntry in variantMap:
    let cols = @[
      varEntry.chrom,
      $varEntry.pos,
      ".",  # ID
      varEntry.refAllele,
      varEntry.altAllele,
      "60.0",
      "PASS",  # FILTER
      ".",     # INFO
      "GT:DP"  # FORMAT
    ]
    
    # Add genotype calls for each sample
    var gtCols: seq[string] = @[]
    for sample in samples:
      if sample in varEntry.samples:
        gtCols.add("1/1:1")  # Homozygous alt call with depth 1
      else:
        gtCols.add("./.:0")  # Missing with depth 0
    
    file.writeLine((cols & gtCols).join("\t"))

proc processABIFile(filename: string, references: seq[RefSequence], config: Config): seq[Variant] =
  try:
    let trace = newABIFTrace(filename)
    defer: trace.close()
    
    let sequence = trace.getSequence()
    let sampleName = extractFilename(filename).replace(".ab1", "")
    
    if config.verbose:
      echo fmt"Processing {sampleName}: {sequence.len} bp"
    
    let (bestRef, alignment) = findBestAlignment(sequence, references, config)
    
    if config.verbose:
      echo fmt"  Best match: {bestRef.name} (identity: {alignment.identity:.3f}, coverage: {alignment.coverage:.3f})"
    
    result = callVariants(alignment, sampleName)
    
    if config.verbose:
      echo fmt"  Found {result.len} variants"
    
  except Exception as e:
    echo fmt"Error processing {filename}: {e.msg}"
    result = @[]

proc main() =
  let config = parseArgs()
  
  if config.verbose:
    echo fmt"Loading reference sequences from {config.referenceFile}..."
  
  let references = loadReference(config.referenceFile)
  
  if config.verbose:
    echo fmt"Loaded {references.len} reference sequences"
  
  var allVariants: seq[Variant] = @[]
  
  for abiFile in config.abiFiles:
    if not fileExists(abiFile):
      echo fmt"Warning: File {abiFile} does not exist, skipping"
      continue
    
    let variants = processABIFile(abiFile, references, config)
    allVariants.add(variants)
  
  # Sort variants by chromosome and position
  allVariants.sort(proc(a, b: Variant): int =
    let chromCmp = cmp(a.chrom, b.chrom)
    if chromCmp != 0: chromCmp else: cmp(a.pos, b.pos)
  )
  
  if config.verbose:
    echo fmt"Writing {allVariants.len} variants to {config.outputFile}..."
  
  writeVCF(allVariants, config.outputFile, config.referenceFile)
  
  echo fmt"Analysis complete. Found {allVariants.len} variants in {config.abiFiles.len} samples."

when isMainModule:
  main()