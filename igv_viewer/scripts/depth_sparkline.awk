# depth_sparkline.awk — Generate text sparkline from samtools depth output.
# Expects -v width=N to set output width.
# Input: samtools depth -r <region> output (chr, pos, depth).
BEGIN { max = 0 }
{
  d[NR] = $3
  pos[NR] = $2
  if ($3 > max) max = $3
  n = NR
}
END {
  if (n == 0) exit
  step = int(n / width) + 1
  if (step < 1) step = 1
  chars = " ▁▂▃▄▅▆▇█"
  printf "  Coverage (%dx max): ", max
  for (i = 1; i <= n; i += step) {
    lvl = int(d[i] / max * 8)
    if (lvl > 8) lvl = 8
    printf "%s", substr(chars, lvl + 1, 1)
  }
  printf "\n  Region: %s:%d-%d\n", $1, pos[1], pos[n]
}
