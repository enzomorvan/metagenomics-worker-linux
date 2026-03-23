#!/bin/bash
# =============================================================================
# process_sample_v2_wrapper.sh
# Unified v2 pipeline — single DIAMOND search against unified database.
#
# Required env vars:
#   ACCESSION   - SRA accession (e.g., SRR3401482)
#   DB_DIR      - Path to DIAMOND databases directory
#   RESULTS_DIR - Path to store result TSV files
#   WORK_DIR    - Temporary working directory for this sample
#   THREADS     - Number of threads for DIAMOND/fastp (default: 12)
# =============================================================================
set -euo pipefail

ACCESSION="${ACCESSION:-${1:-}}"
if [[ -z "${ACCESSION}" ]]; then
    echo "Usage: ACCESSION=SRR12345 bash $0  (or: bash $0 SRR12345)"
    exit 1
fi

DB_DIR="${DB_DIR:?DB_DIR must be set}"
RESULTS_DIR="${RESULTS_DIR:?RESULTS_DIR must be set}"
WORK_DIR="${WORK_DIR:-/tmp/metagenomics_tmp_${ACCESSION}}"
THREADS="${THREADS:-12}"

# Subsampling: 2.5M reads per mate (5M total)
SUBSAMPLE_READS=2500000
SUBSAMPLE_LINES=$(( SUBSAMPLE_READS * 4 ))

# DIAMOND parameters
EVALUE="1e-10"
IDENTITY=50
QUERY_COV=50
MAX_TARGETS=1
BLOCK_SIZE="${BLOCK_SIZE:-1.0}"
INDEX_CHUNKS="${INDEX_CHUNKS:-2}"
OUTFMT="6"

# Unified v2 database
UNIFIED_DB="${DB_DIR}/unified_v2/unified_v2.dmnd"
UNIFIED_MAP="${DB_DIR}/unified_v2/unified_v2_id2gene.map"

# ---- dependency check -------------------------------------------------------
echo "=== [${ACCESSION}] Checking dependencies ==="
for tool in fastp diamond; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool not found in PATH."
        exit 1
    fi
done

if [[ ! -f "${UNIFIED_DB}" ]]; then
    echo "ERROR: Unified v2 database not found at ${UNIFIED_DB}"
    exit 1
fi
if [[ ! -f "${UNIFIED_MAP}" ]]; then
    echo "ERROR: Unified v2 id2gene map not found at ${UNIFIED_MAP}"
    exit 1
fi

mkdir -p "${RESULTS_DIR}" "${WORK_DIR}"

cleanup() {
    echo "=== [${ACCESSION}] Cleaning up ==="
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# =============================================================================
# STEP 1: Download raw reads
# =============================================================================
echo ""
STEP1_START=$(date +%s)
echo "=== [${ACCESSION}] Step 1: Downloading reads ==="

ENA_OK=0

# PREFER_SRA=1 skips ENA and goes straight to SRA toolkit (for networks where ENA is blocked)
if [[ "${PREFER_SRA:-0}" == "1" ]] && command -v prefetch &>/dev/null; then
    echo "  Using SRA toolkit (PREFER_SRA=1)..."
    ENA_OK=-1
fi

if [[ ${ENA_OK} -eq 0 ]]; then
echo "  Streaming from ENA (first ${SUBSAMPLE_READS} reads per mate)..."
ENA_RESP=$(curl -sf "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${ACCESSION}&result=read_run&fields=fastq_ftp" 2>/dev/null)
if [[ -n "${ENA_RESP}" ]]; then
    ENA_URLS=$(echo "${ENA_RESP}" | tail -1 | cut -f2 | tr ';' ' ')
    if [[ -z "${ENA_URLS}" ]]; then
        echo "  No FASTQ URLs on ENA for ${ACCESSION}"
        ENA_OK=-1
    fi
    STREAM_LINES=$(( SUBSAMPLE_READS * 4 * 2 ))
    for URL in ${ENA_URLS}; do
        FNAME=$(basename "${URL}" .gz)
        echo "  Streaming ${FNAME}..."
        curl -sf "https://${URL}" | gunzip -c | head -n ${STREAM_LINES} > "${WORK_DIR}/${FNAME}" || true
        FLINES=$(wc -l < "${WORK_DIR}/${FNAME}")
        if [[ ${FLINES} -lt 4 ]]; then
            echo "  WARNING: ${FNAME} is empty or failed"
            rm -f "${WORK_DIR}/${FNAME}"
            ENA_OK=-1
            break
        fi
        FLINES_CLEAN=$(( (FLINES / 4) * 4 ))
        if [[ ${FLINES_CLEAN} -lt ${FLINES} ]]; then
            head -n ${FLINES_CLEAN} "${WORK_DIR}/${FNAME}" > "${WORK_DIR}/${FNAME}.tmp"
            mv "${WORK_DIR}/${FNAME}.tmp" "${WORK_DIR}/${FNAME}"
        fi
        echo "  Got $(( FLINES_CLEAN / 4 )) reads"
    done

    if [[ -f "${WORK_DIR}/${ACCESSION}_1.fastq" ]] && [[ -f "${WORK_DIR}/${ACCESSION}_2.fastq" ]]; then
        R1_LINES=$(wc -l < "${WORK_DIR}/${ACCESSION}_1.fastq")
        R2_LINES=$(wc -l < "${WORK_DIR}/${ACCESSION}_2.fastq")
        if [[ ${R1_LINES} -ne ${R2_LINES} ]]; then
            MIN_LINES=$(( R1_LINES < R2_LINES ? R1_LINES : R2_LINES ))
            MIN_LINES=$(( (MIN_LINES / 4) * 4 ))
            echo "  Equalizing mates to $(( MIN_LINES / 4 )) reads each"
            head -n ${MIN_LINES} "${WORK_DIR}/${ACCESSION}_1.fastq" > "${WORK_DIR}/${ACCESSION}_1.fastq.tmp"
            mv "${WORK_DIR}/${ACCESSION}_1.fastq.tmp" "${WORK_DIR}/${ACCESSION}_1.fastq"
            head -n ${MIN_LINES} "${WORK_DIR}/${ACCESSION}_2.fastq" > "${WORK_DIR}/${ACCESSION}_2.fastq.tmp"
            mv "${WORK_DIR}/${ACCESSION}_2.fastq.tmp" "${WORK_DIR}/${ACCESSION}_2.fastq"
        fi
    fi
    if [[ ${ENA_OK} -ne -1 ]]; then
        ENA_OK=1
    fi
fi
fi  # end of ENA_OK==0 check (PREFER_SRA skips this)

if [[ ${ENA_OK} -ne 1 ]]; then
    if command -v prefetch &>/dev/null && command -v fasterq-dump &>/dev/null; then
        echo "  ENA failed, trying SRA toolkit..."
        if prefetch "${ACCESSION}" --output-directory "${WORK_DIR}" --max-size 50G 2>&1 | tail -5; then
            SRA_FILE="${WORK_DIR}/${ACCESSION}/${ACCESSION}.sra"
            if [[ -f "${SRA_FILE}" ]]; then
                fasterq-dump "${SRA_FILE}" --outdir "${WORK_DIR}" --split-3 --skip-technical --threads "${THREADS}" 2>&1 | tail -5
            fi
            rm -rf "${WORK_DIR}/${ACCESSION}"
        fi
    else
        echo "ERROR: ENA streaming failed and SRA toolkit not available"
        exit 1
    fi
fi

STEP1_END=$(date +%s)
echo "  Download time: $(( STEP1_END - STEP1_START ))s"

if [[ -f "${WORK_DIR}/${ACCESSION}_1.fastq" ]] && [[ -f "${WORK_DIR}/${ACCESSION}_2.fastq" ]]; then
    LAYOUT="paired"
    echo "  Layout: paired-end"
elif [[ -f "${WORK_DIR}/${ACCESSION}_1.fastq" ]] && [[ ! -f "${WORK_DIR}/${ACCESSION}_2.fastq" ]]; then
    mv "${WORK_DIR}/${ACCESSION}_1.fastq" "${WORK_DIR}/${ACCESSION}.fastq"
    LAYOUT="single"
    echo "  Layout: single-end (renamed from _1)"
elif [[ -f "${WORK_DIR}/${ACCESSION}.fastq" ]]; then
    LAYOUT="single"
    echo "  Layout: single-end"
else
    echo "ERROR: No FASTQ files produced for ${ACCESSION}"
    exit 1
fi

# =============================================================================
# STEP 2: Quality control with fastp
# =============================================================================
echo ""
STEP2_START=$(date +%s)
echo "=== [${ACCESSION}] Step 2: Quality trimming with fastp ==="

TRIMMED="${WORK_DIR}/${ACCESSION}_trimmed.fastq"

if [[ "${LAYOUT}" == "paired" ]]; then
    fastp \
        --in1 "${WORK_DIR}/${ACCESSION}_1.fastq" \
        --in2 "${WORK_DIR}/${ACCESSION}_2.fastq" \
        --out1 "${WORK_DIR}/${ACCESSION}_trimmed_1.fastq" \
        --out2 "${WORK_DIR}/${ACCESSION}_trimmed_2.fastq" \
        --qualified_quality_phred 20 \
        --length_required 50 \
        --thread "${THREADS}" \
        --json "${WORK_DIR}/${ACCESSION}_fastp.json" \
        --html /dev/null \
        2>&1 | tail -5

    rm -f "${WORK_DIR}/${ACCESSION}_1.fastq" "${WORK_DIR}/${ACCESSION}_2.fastq"

    if [[ ${SUBSAMPLE_READS} -gt 0 ]]; then
        echo "  Subsampling to ${SUBSAMPLE_READS} reads per mate..."
        head -n "${SUBSAMPLE_LINES}" "${WORK_DIR}/${ACCESSION}_trimmed_1.fastq" > "${WORK_DIR}/sub_1.fastq"
        head -n "${SUBSAMPLE_LINES}" "${WORK_DIR}/${ACCESSION}_trimmed_2.fastq" > "${WORK_DIR}/sub_2.fastq"
        cat "${WORK_DIR}/sub_1.fastq" "${WORK_DIR}/sub_2.fastq" > "${TRIMMED}"
        rm -f "${WORK_DIR}/sub_1.fastq" "${WORK_DIR}/sub_2.fastq"
    else
        cat "${WORK_DIR}/${ACCESSION}_trimmed_1.fastq" \
            "${WORK_DIR}/${ACCESSION}_trimmed_2.fastq" \
            > "${TRIMMED}"
    fi
    rm -f "${WORK_DIR}/${ACCESSION}_trimmed_1.fastq" "${WORK_DIR}/${ACCESSION}_trimmed_2.fastq"
else
    fastp \
        --in1 "${WORK_DIR}/${ACCESSION}.fastq" \
        --out1 "${TRIMMED}" \
        --qualified_quality_phred 20 \
        --length_required 50 \
        --thread "${THREADS}" \
        --json "${WORK_DIR}/${ACCESSION}_fastp.json" \
        --html /dev/null \
        2>&1 | tail -5

    rm -f "${WORK_DIR}/${ACCESSION}.fastq"

    if [[ ${SUBSAMPLE_READS} -gt 0 ]]; then
        SE_LINES=$(( SUBSAMPLE_READS * 2 * 4 ))
        echo "  Subsampling to $(( SUBSAMPLE_READS * 2 )) reads..."
        head -n "${SE_LINES}" "${TRIMMED}" > "${WORK_DIR}/sub_se.fastq"
        mv "${WORK_DIR}/sub_se.fastq" "${TRIMMED}"
    fi
fi

TOTAL_READS=$(( $(wc -l < "${TRIMMED}") / 4 ))
STEP2_END=$(date +%s)
echo "  Reads after trimming: ${TOTAL_READS}"
echo "  QC time: $(( STEP2_END - STEP2_START ))s"

# =============================================================================
# STEP 3: DIAMOND blastx against unified v2 database
# =============================================================================
echo ""
STEP3_START=$(date +%s)
echo "=== [${ACCESSION}] Step 3: DIAMOND blastx vs unified_v2 ==="

HITS="${WORK_DIR}/${ACCESSION}_unified_hits.tsv"
COUNTS="${RESULTS_DIR}/${ACCESSION}_unified_counts.tsv"

diamond blastx \
    --query "${TRIMMED}" \
    --db "${UNIFIED_DB}" \
    --out "${HITS}" \
    --evalue "${EVALUE}" \
    --id "${IDENTITY}" \
    --query-cover "${QUERY_COV}" \
    --max-target-seqs "${MAX_TARGETS}" \
    --outfmt "${OUTFMT}" \
    --threads "${THREADS}" \
    --block-size "${BLOCK_SIZE}" \
    --index-chunks "${INDEX_CHUNKS}" \
    2>&1 | tail -5

# Delete trimmed reads — no longer needed
rm -f "${TRIMMED}"

STEP3_END=$(date +%s)
echo "  DIAMOND time: $(( STEP3_END - STEP3_START ))s"

# =============================================================================
# STEP 4: Count hits per gene family
# =============================================================================
echo ""
echo "=== [${ACCESSION}] Step 4: Counting hits per gene family ==="

if [[ -s "${HITS}" ]]; then
    # The unified v2 seq IDs (DIAMOND col 2) are the map keys directly
    echo -e "gene_family\thit_count" > "${COUNTS}"
    awk -F'\t' 'BEGIN {
        while ((getline line < "'"${UNIFIED_MAP}"'") > 0) {
            split(line, f, "\t")
            map[f[1]] = f[2]
        }
    }
    {
        gene = map[$2]
        if (gene == "") gene = "unknown"
        print gene
    }' "${HITS}" | sort | uniq -c | sort -rn | \
    awk '{print $2"\t"$1}' >> "${COUNTS}"

    TOTAL_HITS=$(awk 'NR>1 {s+=$2} END {print s+0}' "${COUNTS}")
    GENE_FAMILIES=$(awk 'NR>1' "${COUNTS}" | wc -l)
    echo "  Total hits: ${TOTAL_HITS}"
    echo "  Gene families detected: ${GENE_FAMILIES}"
else
    echo -e "gene_family\thit_count" > "${COUNTS}"
    echo "  No hits found."
    TOTAL_HITS=0
fi

# =============================================================================
# STEP 5: Save per-sample statistics
# =============================================================================
echo ""
echo "=== [${ACCESSION}] Step 5: Saving statistics ==="

STATS_FILE="${RESULTS_DIR}/${ACCESSION}_stats.tsv"
{
    echo -e "accession\tlayout\ttotal_reads_trimmed\tunified_hits"
    echo -e "${ACCESSION}\t${LAYOUT}\t${TOTAL_READS}\t${TOTAL_HITS}"
} > "${STATS_FILE}"

STEP_END=$(date +%s)
echo "  Stats saved to: ${STATS_FILE}"
echo ""
echo "=== [${ACCESSION}] Pipeline v2 complete ==="
echo "  Total reads (trimmed): ${TOTAL_READS}"
echo "  Unified hits:          ${TOTAL_HITS}"
echo "  Download: $(( STEP1_END - STEP1_START ))s | QC: $(( STEP2_END - STEP2_START ))s | DIAMOND: $(( STEP3_END - STEP3_START ))s"
echo "STEP_TIMINGS:download=$(( STEP1_END - STEP1_START )),qc=$(( STEP2_END - STEP2_START )),diamond=$(( STEP3_END - STEP3_START ))"
