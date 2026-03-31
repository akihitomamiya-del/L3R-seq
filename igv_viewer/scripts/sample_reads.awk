# sample_reads.awk — Show key SAM tags from sample reads.
# Input: SAM records (piped from samtools view | head -8).
BEGIN { FS = "\t" }
{
  name = $1; pos = $4; cigar = $6; tags = ""
  for (i = 12; i <= NF; i++) {
    if ($i ~ /^(EC|SC|NC|SJ|TL|3E):/) tags = tags " " $i
  }
  printf "  %-30s pos=%-5s cigar=%-20s%s\n", substr(name, 1, 30), pos, cigar, tags
}
