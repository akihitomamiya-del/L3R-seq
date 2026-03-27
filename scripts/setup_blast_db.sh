#!/bin/bash
# setup_blast_db.sh -- Download and create BLAST databases for L3Rseq step 09
#
# Creates up to two BLAST databases:
#   1. Organelle DB  -- For translocation detection (e.g., mitochondrial genome)
#   2. Transcriptome DB -- For right-clip annotation (e.g., cDNA sequences)
#
# Usage:
#   bash scripts/setup_blast_db.sh [options]
#
# Modes:
#   Default (no flags):     Downloads Arabidopsis TAIR10 ChrM + cDNA
#   --organelle-fasta/url:  Use custom organelle genome (local file or URL)
#   --transcriptome-fasta/url: Use custom transcriptome (local file or URL)
#   --skip-organelle:       Skip organelle DB (for nuclear-only RNA editing)
#   --skip-transcriptome:   Skip transcriptome DB
#
# Examples:
#   # Arabidopsis (default)
#   bash scripts/setup_blast_db.sh
#
#   # Human (custom URLs)
#   bash scripts/setup_blast_db.sh \
#     --organelle-url "https://ftp.ensembl.org/.../Homo_sapiens.GRCh38.dna.chromosome.MT.fa.gz" \
#     --transcriptome-url "https://ftp.ensembl.org/.../Homo_sapiens.GRCh38.cdna.all.fa.gz"
#
#   # Local files
#   bash scripts/setup_blast_db.sh \
#     --organelle-fasta my_mtDNA.fa \
#     --transcriptome-fasta my_cDNA.fa
#
#   # Nuclear RNA editing only (no organelle DB)
#   bash scripts/setup_blast_db.sh --skip-organelle --transcriptome-fasta my_cDNA.fa
#
# Requirements: wget (for URL mode), makeblastdb (BLAST+), gunzip

set -euo pipefail

# Defaults: Arabidopsis TAIR10
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLAST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/resources/blast"

ORGANELLE_URL="https://ftp.ensemblgenomes.ebi.ac.uk/pub/plants/release-59/fasta/arabidopsis_thaliana/dna/Arabidopsis_thaliana.TAIR10.dna.chromosome.Mt.fa.gz"
ORGANELLE_FASTA=""
ORGANELLE_NAME="organelle"
ORGANELLE_DB_NAME="organelle_db"
SKIP_ORGANELLE=0

TRANSCRIPTOME_URL="https://www.arabidopsis.org/api/download-files/download?filePath=Genes/TAIR10_genome_release/TAIR10_blastsets/TAIR10_cdna_20101214_updated"
TRANSCRIPTOME_FASTA=""
TRANSCRIPTOME_NAME="transcriptome"
TRANSCRIPTOME_DB_NAME="transcriptome_db"
SKIP_TRANSCRIPTOME=0

# Backward compatibility: keep TAIR10 naming when using defaults
USE_DEFAULT_NAMING=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)                  BLAST_DIR="$2"; shift 2 ;;
        --organelle-fasta)      ORGANELLE_FASTA="$2"; USE_DEFAULT_NAMING=0; shift 2 ;;
        --organelle-url)        ORGANELLE_URL="$2"; USE_DEFAULT_NAMING=0; shift 2 ;;
        --organelle-name)       ORGANELLE_NAME="$2"; ORGANELLE_DB_NAME="${2}_db"; shift 2 ;;
        --transcriptome-fasta)  TRANSCRIPTOME_FASTA="$2"; USE_DEFAULT_NAMING=0; shift 2 ;;
        --transcriptome-url)    TRANSCRIPTOME_URL="$2"; USE_DEFAULT_NAMING=0; shift 2 ;;
        --transcriptome-name)   TRANSCRIPTOME_NAME="$2"; TRANSCRIPTOME_DB_NAME="${2}_db"; shift 2 ;;
        --skip-organelle)       SKIP_ORGANELLE=1; shift ;;
        --skip-transcriptome)   SKIP_TRANSCRIPTOME=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Use TAIR10 naming for backward compatibility when using defaults
if [ "$USE_DEFAULT_NAMING" -eq 1 ]; then
    ORGANELLE_NAME="TAIR10_ChrM"
    ORGANELLE_DB_NAME="TAIR10_ChrM_db"
    TRANSCRIPTOME_NAME="TAIR10_cDNA"
    TRANSCRIPTOME_DB_NAME="TAIR10_cdna_db"
fi

echo "Setting up BLAST databases in $BLAST_DIR ..."

# Check dependencies
if ! command -v makeblastdb &>/dev/null; then
    echo "ERROR: makeblastdb (BLAST+) is required but not found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: build BLAST DB from a FASTA file
# ---------------------------------------------------------------------------
build_db() {
    local fasta="$1"
    local db_name="$2"
    local label="$3"

    echo "  Building BLAST database ($label) ..."
    makeblastdb \
        -in "$fasta" \
        -out "$db_name" \
        -dbtype nucl \
        -parse_seqids \
        > "makeblastdb_${label}.log" 2>&1
    echo "  Done: $db_name"
}

# ---------------------------------------------------------------------------
# Helper: download and optionally decompress a FASTA
# ---------------------------------------------------------------------------
download_fasta() {
    local url="$1"
    local output="$2"

    echo "  Downloading: $url"
    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar "$url" -o "$output"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress "$url" -O "$output"
    else
        echo "ERROR: Neither curl nor wget found. Install one to download files." >&2
        exit 1
    fi

    if [ ! -s "$output" ]; then
        echo "  ERROR: Download failed or file is empty." >&2
        exit 1
    fi

    # Decompress if gzipped
    if [[ "$output" == *.gz ]]; then
        echo "  Decompressing ..."
        gunzip -f "$output"
        output="${output%.gz}"
    fi

    echo "$output"
}

# ---------------------------------------------------------------------------
# Organelle database (e.g., mitochondrial genome)
# ---------------------------------------------------------------------------
if [ "$SKIP_ORGANELLE" -eq 0 ]; then
    echo ""
    echo "=== Organelle database ($ORGANELLE_NAME) ==="
    mkdir -p "$BLAST_DIR/$ORGANELLE_NAME"
    cd "$BLAST_DIR/$ORGANELLE_NAME"

    if [ -f "${ORGANELLE_DB_NAME}.ndb" ] || [ -f "${ORGANELLE_DB_NAME}.nsq" ]; then
        echo "  Already exists, skipping. Delete $BLAST_DIR/$ORGANELLE_NAME to rebuild."
    elif [ -n "$ORGANELLE_FASTA" ]; then
        # Local file mode
        if [ ! -f "$ORGANELLE_FASTA" ]; then
            echo "  ERROR: Organelle FASTA not found: $ORGANELLE_FASTA" >&2
            exit 1
        fi
        cp "$ORGANELLE_FASTA" .
        build_db "$(basename "$ORGANELLE_FASTA")" "$ORGANELLE_DB_NAME" "$ORGANELLE_NAME"
    else
        # Download mode
        local_file="organelle_download.fa"
        [[ "$ORGANELLE_URL" == *.gz ]] && local_file="organelle_download.fa.gz"
        download_fasta "$ORGANELLE_URL" "$local_file"
        local_file="${local_file%.gz}"
        build_db "$local_file" "$ORGANELLE_DB_NAME" "$ORGANELLE_NAME"
    fi
else
    echo ""
    echo "=== Organelle database: SKIPPED (--skip-organelle) ==="
fi

# ---------------------------------------------------------------------------
# Transcriptome database (e.g., cDNA)
# ---------------------------------------------------------------------------
if [ "$SKIP_TRANSCRIPTOME" -eq 0 ]; then
    echo ""
    echo "=== Transcriptome database ($TRANSCRIPTOME_NAME) ==="
    mkdir -p "$BLAST_DIR/$TRANSCRIPTOME_NAME"
    cd "$BLAST_DIR/$TRANSCRIPTOME_NAME"

    if [ -f "${TRANSCRIPTOME_DB_NAME}.ndb" ] || [ -f "${TRANSCRIPTOME_DB_NAME}.nsq" ]; then
        echo "  Already exists, skipping. Delete $BLAST_DIR/$TRANSCRIPTOME_NAME to rebuild."
    elif [ -n "$TRANSCRIPTOME_FASTA" ]; then
        # Local file mode
        if [ ! -f "$TRANSCRIPTOME_FASTA" ]; then
            echo "  ERROR: Transcriptome FASTA not found: $TRANSCRIPTOME_FASTA" >&2
            exit 1
        fi
        cp "$TRANSCRIPTOME_FASTA" .
        build_db "$(basename "$TRANSCRIPTOME_FASTA")" "$TRANSCRIPTOME_DB_NAME" "$TRANSCRIPTOME_NAME"
    else
        # Download mode
        local_file="transcriptome_download.fa"
        [[ "$TRANSCRIPTOME_URL" == *.gz ]] && local_file="transcriptome_download.fa.gz"
        download_fasta "$TRANSCRIPTOME_URL" "$local_file"
        local_file="${local_file%.gz}"
        build_db "$local_file" "$TRANSCRIPTOME_DB_NAME" "$TRANSCRIPTOME_NAME"
    fi
else
    echo ""
    echo "=== Transcriptome database: SKIPPED (--skip-transcriptome) ==="
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "BLAST database setup complete."
[ "$SKIP_ORGANELLE" -eq 0 ] && echo "  Organelle DB:     $BLAST_DIR/$ORGANELLE_NAME/$ORGANELLE_DB_NAME"
[ "$SKIP_TRANSCRIPTOME" -eq 0 ] && echo "  Transcriptome DB: $BLAST_DIR/$TRANSCRIPTOME_NAME/$TRANSCRIPTOME_DB_NAME"
echo ""
echo "Use --blast-db and --blast-db2 flags in L3Rseq to point to these databases."
