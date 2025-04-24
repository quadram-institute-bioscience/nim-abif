import std/[unittest, strutils, os]
import ../src/abimerge
import ../src/abif

# Test reverse and revcompl functions
test "Reverse function":
  check(reverseString("ACGT") == "TGCA")
  check(reverseString("") == "")
  check(reverseString("A") == "A")

test "Reverse complement function":
  check(revcompl("ACGT") == "ACGT")  # ACGT is its own reverse complement
  check(revcompl("AATTGC") == "GCAATT")
  check(revcompl("") == "")
  check(revcompl("N") == "N")

# Test Smith-Waterman alignment
test "Smith-Waterman alignment with perfect match":
  let 
    seq1 = "ACGTACGTACGT"
    seq2 = "ACGTACGTACGT"
    weights = swWeights(
      match: 10,
      mismatch: -8,
      gap: -10,
      gapopening: -10,
      minscore: 10
    )
  
  let alignment = simpleSmithWaterman(seq1, seq2, weights)
  check(alignment.score > 0)
  check(alignment.length == seq1.len)
  check(alignment.pctid == 100.0)

test "Smith-Waterman alignment with mismatch":
  let 
    seq1 = "ACGTACGTACGT"
    seq2 = "ACGTACGTNCGT"  # One mismatch
    weights = swWeights(
      match: 10,
      mismatch: -8,
      gap: -10,
      gapopening: -10,
      minscore: 10
    )
  
  let alignment = simpleSmithWaterman(seq1, seq2, weights)
  check(alignment.score > 0)
  check(alignment.length == seq1.len)
  check(alignment.pctid < 100.0)
  check(alignment.pctid > 90.0)  # One mismatch out of 12 should be >90%

test "Translate IUPAC function":
  check(translateIUPAC('A') == 'T')
  check(translateIUPAC('T') == 'A')
  check(translateIUPAC('G') == 'C')
  check(translateIUPAC('C') == 'G')
  check(translateIUPAC('N') == 'N')
  check(translateIUPAC('Y') == 'R')
  check(translateIUPAC('R') == 'Y')

when isMainModule:
  # Only run these tests if AB1 files exist
  if fileExists("tests/A_forward.ab1") and fileExists("tests/A_reverse.ab1"):
    test "Merge real AB1 traces":
      # Load forward trace
      let traceF = newABIFTrace("tests/A_forward.ab1")
      let seqF = traceF.getSequence()
      let qualF = traceF.getQualityValues()
      
      # Load reverse trace
      let traceR = newABIFTrace("tests/A_reverse.ab1")
      let seqR = traceR.getSequence()
      let qualR = traceR.getQualityValues()
      
      # Create config for merging
      let config = Config(
        minOverlap: 10,
        scoreMatch: 10,
        scoreMismatch: -8,
        scoreGap: -10,
        minScore: 50,
        pctId: 80.0,
        joinGap: 10,
        verbose: false
      )
      
      # Merge the sequences
      let merged = mergeSequences(seqF, qualF, seqR, qualR, config)
      
      # Check that we got a merged sequence
      check(merged.seq.len > 0)
      check(merged.qual.len == merged.seq.len)
      
      # Clean up
      traceF.close()
      traceR.close()
  
  # Run test using minimal sequences
  test "Merge test sequences":
    let 
      seqF = "ACGTACGTACGTACGTACGT"
      seqR = "TACGTACGTACGTACGTACG"  # Reverse of seqF (would be revcompl in real data)
      qualF = @[30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
      qualR = @[30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
      
    # Create config for merging
    let config = Config(
      minOverlap: 5,
      scoreMatch: 10,
      scoreMismatch: -8,
      scoreGap: -10,
      minScore: 10,
      pctId: 80.0,
      joinGap: 5,
      verbose: false
    )
    
    # Merge the sequences
    let merged = mergeSequences(seqF, qualF, seqR, qualR, config)
    
    # Should succeed with a merged sequence
    check(merged.seq.len > 0)