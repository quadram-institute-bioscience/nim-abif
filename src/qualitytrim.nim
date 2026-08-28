## This module provides quality-based sequence trimming functionality.
##
## Used by abi2fq and abimerge to trim low-quality regions from DNA sequences
## using a sliding window approach.

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
