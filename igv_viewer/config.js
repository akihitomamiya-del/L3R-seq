// Shared configuration for the IGV viewer server and pileup module.

module.exports = {
  // Pipeline step directories to scan for BAM files.
  // Each entry maps a directory name to a track label and color.
  PIPELINE_STEPS: [
    { dir: "01_raw_bin", label: "raw bin reads", color: "#e8d5b7" },
    { dir: "02_consensus", label: "consensus", color: "#5dade2" },
    { dir: "07_map", label: "mapping (step 07)", color: "#b0b0b0" },
    { dir: "09_correct", label: "corrected (step 09)", color: "#f5e6ca" },
    { dir: "09_correct", file: "chimeric_rightclip.sort.bam", label: "chimeric (removed)", color: "#e74c3c" },
  ],

  // BGZF block size — used to read BAM headers for reference name detection.
  BGZF_BUFFER_SIZE: 65536,

  // FASTA line width — IGV.js byte-range math works best with uniform short lines.
  FASTA_WRAP_WIDTH: 80,
};
