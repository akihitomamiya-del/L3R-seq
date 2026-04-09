"""BLAST subprocess wrapper for L3Rseq step 09 chimera detection.

Replaces ``scripts/09b_blast_rightclip.sh``. Runs ``blastn`` (via
``subprocess.run``) on batches of right-clipped sequences against two
reference databases:

1. **ChrM** database — detects translocations to the organellar reference.
   Hits set the ``TL`` tag to 1; the read is still walk-corrected.
2. **cDNA** database — detects PCR chimeras. Only queries that missed ChrM
   are searched. Hits mark the read as a chimera; it goes to the chimeric
   BAM instead of being walk-corrected.

Semantics match the bash exactly:

- If ``queries`` is empty → empty result, no FASTA written.
- If ``chrm_db`` is missing → empty result, no FASTA written (bash
  gates the entire BLAST phase on ChrM DB presence via ``blast_available``).
- If ``chrm_db`` exists but ``cdna_db`` is missing → ChrM-only search.
- If both exist → ChrM first, then cDNA for reads that didn't hit ChrM.

All BLAST I/O is file-based; intermediate files are left in ``workdir`` and
their paths returned so the orchestrator can preserve them alongside the
corrected BAM (matches ``scripts/09_tail_correct.sh:461-469`` which copies
the raw results into the sample output dir).
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

#: blastn tabular output columns for the ChrM search. Matches
#: ``scripts/09b_blast_rightclip.sh:42``.
_CHRM_OUTFMT = (
    "6 qseqid sseqid pident length mismatch gapopen "
    "qstart qend sstart send evalue bitscore"
)

#: cDNA output adds one more column (``stitle``) for the subject title.
#: Matches ``scripts/09b_blast_rightclip.sh:69``.
_CDNA_OUTFMT = _CHRM_OUTFMT + " stitle"


@dataclass(frozen=True)
class BatchBlastResult:
    """Result of :func:`run_batch_blast`.

    Attributes:
        chrm_hits: Read indices (from the query tuples) that had ChrM hits.
            Empty frozenset when no ChrM search ran.
        cdna_hits: Read indices that had cDNA hits (among reads without
            ChrM hits). Empty frozenset when no cDNA search ran.
        query_fasta_path: Path to the built query FASTA, or ``None`` if no
            BLAST ran. The orchestrator should copy this to
            ``{sample}/blast_rightclip_queries.fa`` for inspection when not
            ``None``.
        chrm_raw_path: Path to the raw ChrM tabular output, or ``None``.
            Copied to ``{sample}/blast_chrm_results.txt``.
        cdna_raw_path: Path to the raw cDNA tabular output, or ``None``.
            Copied to ``{sample}/blast_cdna_results.txt``.
    """

    chrm_hits: frozenset[int]
    cdna_hits: frozenset[int]
    query_fasta_path: Path | None
    chrm_raw_path: Path | None
    cdna_raw_path: Path | None


def _blast_db_exists(db_path: Path | None) -> bool:
    """Check if a BLAST DB exists.

    BLAST DBs consist of multiple files (``.nhr``, ``.nin``, ``.nsq``, …) —
    the bash version uses ``ls "${db_path}"*`` to check for any of them.
    This equivalent checks whether any file in ``db_path.parent`` starts
    with the DB basename.
    """
    if db_path is None:
        return False
    parent = db_path.parent
    if not parent.exists():
        return False
    prefix = db_path.name
    return any(p.name.startswith(prefix) and p.is_file() for p in parent.iterdir())


def _write_query_fasta(queries: list[tuple[int, str]], path: Path) -> None:
    """Write the query batch as FASTA with ``>Rightclip_<idx>`` headers.

    Format matches ``scripts/09b_blast_rightclip.sh:22``::

        >Rightclip_<idx>
        <sequence>
    """
    with path.open("w") as fh:
        for read_idx, seq in queries:
            fh.write(f">Rightclip_{read_idx}\n{seq}\n")


def _parse_hits(tabular_path: Path) -> frozenset[int]:
    """Extract unique read indices from a blastn tabular output file.

    The first column (``qseqid``) has the form ``Rightclip_<idx>``. Returns
    a frozenset of the parsed integer indices, matching the bash pipeline
    ``cut -f1 | sort -u`` in ``scripts/09b_blast_rightclip.sh:47,76``.
    """
    hits: set[int] = set()
    if not tabular_path.exists():
        return frozenset()
    with tabular_path.open() as fh:
        for line in fh:
            if not line or line.startswith("#"):
                continue
            qseqid = line.split("\t", 1)[0]
            if qseqid.startswith("Rightclip_"):
                try:
                    hits.add(int(qseqid[len("Rightclip_") :]))
                except ValueError:
                    continue
    return frozenset(hits)


def _run_blastn(
    blastn: str,
    db: Path,
    query: Path,
    out: Path,
    outfmt: str,
) -> None:
    """Run ``blastn`` once. stderr is suppressed and failures are tolerated.

    Matches the bash ``|| true`` fallthrough in
    ``scripts/09b_blast_rightclip.sh:43,71``: if blastn crashes or produces
    no output, the orchestrator still continues — reads just get walk-
    corrected without BLAST filtering.
    """
    subprocess.run(  # noqa: S603  (blastn is a trusted binary)
        [
            blastn, "-task", "megablast",
            "-db", str(db),
            "-query", str(query),
            "-outfmt", outfmt,
            "-out", str(out),
        ],
        check=False,
        stderr=subprocess.DEVNULL,
    )


def _empty_result() -> BatchBlastResult:
    return BatchBlastResult(
        chrm_hits=frozenset(),
        cdna_hits=frozenset(),
        query_fasta_path=None,
        chrm_raw_path=None,
        cdna_raw_path=None,
    )


def run_batch_blast(
    queries: list[tuple[int, str]],
    chrm_db: Path | None,
    cdna_db: Path | None,
    workdir: Path,
    blastn: str = "blastn",
) -> BatchBlastResult:
    """Run batch BLAST against ChrM and cDNA DBs on a set of rightclip queries.

    Mirrors ``scripts/09b_blast_rightclip.sh:25-80`` with the bash's
    ``init_blast_batch`` / ``collect_blast_query`` / ``lookup_*`` functions
    folded into a single call: the caller passes the full query list and
    gets back frozensets to use with ``in`` checks.

    Args:
        queries: List of ``(read_idx, rightclip_seq)`` tuples. ``read_idx``
            must be unique per query. Empty list short-circuits to an
            empty result.
        chrm_db: Path to the ChrM BLAST DB (no file extension). ``None`` or
            missing DB disables all BLAST — matches the bash
            ``blast_available`` gate at ``scripts/09_tail_correct.sh:322``.
        cdna_db: Path to the cDNA BLAST DB. Only searched for reads that
            had no ChrM hit. ``None`` or missing DB disables cDNA search.
        workdir: Directory for intermediate files (query FASTA, raw outputs).
            Must already exist.
        blastn: blastn executable path. Defaults to ``"blastn"`` (must be on
            PATH — step 09's conda env NanoporeMap includes BLAST+).

    Returns:
        :class:`BatchBlastResult` with the two hit sets and paths to the
        preserved intermediate files (or ``None`` paths when no BLAST ran).
    """
    if not queries:
        return _empty_result()

    if not _blast_db_exists(chrm_db):
        return _empty_result()

    # chrm_db is guaranteed non-None from this point
    assert chrm_db is not None

    query_fasta = workdir / "blast_batch.fa"
    _write_query_fasta(queries, query_fasta)

    # ChrM search (primary)
    chrm_raw = workdir / "batch_blast_chrm_raw.txt"
    _run_blastn(blastn, chrm_db, query_fasta, chrm_raw, _CHRM_OUTFMT)
    chrm_hits = _parse_hits(chrm_raw)

    # cDNA search (optional, only for reads that missed ChrM)
    cdna_hits: frozenset[int] = frozenset()
    cdna_raw: Path | None = None
    if _blast_db_exists(cdna_db):
        assert cdna_db is not None
        missed_chrm = [q for q in queries if q[0] not in chrm_hits]
        if missed_chrm:
            no_chrm_fasta = workdir / "batch_no_chrm.fa"
            _write_query_fasta(missed_chrm, no_chrm_fasta)
            cdna_raw = workdir / "batch_blast_cdna.txt"
            _run_blastn(blastn, cdna_db, no_chrm_fasta, cdna_raw, _CDNA_OUTFMT)
            cdna_hits = _parse_hits(cdna_raw)

    return BatchBlastResult(
        chrm_hits=chrm_hits,
        cdna_hits=cdna_hits,
        query_fasta_path=query_fasta,
        chrm_raw_path=chrm_raw,
        cdna_raw_path=cdna_raw,
    )
