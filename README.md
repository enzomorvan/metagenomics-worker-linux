# Metagenomics Distributed Worker (Linux)

Distributed compute worker for metagenomics sample processing. Downloads metagenomic samples from SRA/ENA, performs quality trimming (fastp), runs DIAMOND blastx against 4 databases (NCycDB, PlasticDB, Extended N-metabolism, Functional genes), and uploads results to a central coordinator.

## Quick Start

```bash
unzip metagenomics_worker_linux.zip
cd metagenomics_worker_linux
bash SETUP.sh
```

The setup installs Miniforge, DIAMOND, fastp, and SRA-tools via conda.

To run the GUI:
```bash
python3 -m worker.gui
```

Or headless (no GUI):
```bash
python3 -m worker
```

## Requirements

- Linux (Debian/Ubuntu/Fedora/etc.)
- Internet connection
- ~2 GB disk for tools, plus ~30 GB free for processing

## What Gets Installed

| Tool | Purpose | Source |
|------|---------|--------|
| Miniforge (conda) | Package manager | conda-forge |
| DIAMOND | Protein alignment (blastx) | bioconda |
| fastp | Quality trimming + adapter removal | bioconda |
| SRA-tools | Download from NCBI SRA | bioconda |

## GUI Features

- Thread count selector (1 to CPU cores)
- Start / Pause / Stop buttons
- Per-sample progress bar with time estimate
- Overall progress (all workers combined)
- CPU temperature monitoring

## Pipeline Per Sample

1. Download from SRA (prefetch + fasterq-dump), fallback to ENA streaming
2. Quality trim with fastp (Q20, min 50bp, auto adapter detection)
3. Subsample to 5M reads
4. DIAMOND blastx vs NCycDB (nitrogen cycling genes)
5. DIAMOND blastx vs PlasticDB (plastic degradation enzymes)
6. DIAMOND blastx vs Extended N-metabolism DB
7. DIAMOND blastx vs Functional gene DB
8. Count hits per gene family, upload results

## Coordinator

Results are sent to a central coordinator server. The coordinator URL and API key are pre-configured in the worker.

## Environment Variables

All optional — defaults are pre-configured:

| Variable | Default | Description |
|----------|---------|-------------|
| `COORDINATOR_URL` | (pre-set) | Coordinator server URL |
| `API_KEY` | (pre-set) | Authentication key |
| `WORKER_NAME` | hostname | Display name on dashboard |
| `WORK_DIR` | `~/distributed_compute` | Working directory |
| `THREADS` | 12 | Number of threads |
| `MIN_DISK_GB` | 30 | Minimum free disk to claim tasks |

## Troubleshooting

- **Download failures** — SRA toolkit issues fall back to ENA streaming automatically. Failed tasks auto-retry after 30 minutes.
- **Disk space** — Worker pauses when free disk drops below MIN_DISK_GB.
- **CPU overheating** — Reduce thread count in the GUI.
