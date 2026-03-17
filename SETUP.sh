#!/bin/bash
# =============================================================================
# ONE-COMMAND WORKER SETUP
# Installs everything needed to run the metagenomics worker:
#   1. Miniforge (lightweight conda) — if not already installed
#   2. Bioinformatics tools: DIAMOND, fastp, SRA-tools
#   3. Python dependencies: requests
#   4. Creates a ready-to-run launcher script
#
# Usage (copy-paste this entire line):
#   curl -fsSL http://YOUR_VPS_IP:8000/api/setup/worker.sh | bash
#
# Or run locally:
#   bash setup_worker.sh
# =============================================================================
set -euo pipefail

echo "============================================"
echo "  Metagenomics Worker — Automated Setup"
echo "============================================"
echo ""

# ---- Configuration (edit these or pass as env vars) -------------------------
COORDINATOR_URL="${COORDINATOR_URL:-http://194.164.206.175/compute}"
API_KEY="${API_KEY:-jhyPOTYST8E_xyjEAyRJ1LWrMRoZeE33kV6fW9pgIQA}"
WORKER_NAME="${WORKER_NAME:-$(hostname)}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"
INSTALL_DIR="${HOME}/distributed_compute"

# ---- Detect platform --------------------------------------------------------
IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
    echo "Detected: Windows (WSL2)"
else
    echo "Detected: Linux"
fi

# ---- Step 1: Install Miniforge (conda) if needed ----------------------------
echo ""
echo "[1/4] Checking conda..."

CONDA_DIR="${HOME}/miniforge3"
CONDA_BIN="${CONDA_DIR}/bin/conda"

if command -v conda &>/dev/null; then
    echo "  conda already installed: $(conda --version)"
    CONDA_BIN="$(which conda)"
    CONDA_DIR="$(conda info --base)"
elif [[ -f "${CONDA_BIN}" ]]; then
    echo "  Miniforge found at ${CONDA_DIR}"
else
    echo "  Installing Miniforge (this takes ~2 minutes)..."
    ARCH=$(uname -m)
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${ARCH}.sh"
    INSTALLER="/tmp/miniforge_installer.sh"

    curl -fsSL "${MINIFORGE_URL}" -o "${INSTALLER}"
    bash "${INSTALLER}" -b -p "${CONDA_DIR}" > /dev/null 2>&1
    rm -f "${INSTALLER}"

    # Add to shell profile
    "${CONDA_DIR}/bin/conda" init bash > /dev/null 2>&1 || true
    if [[ -f "${HOME}/.zshrc" ]]; then
        "${CONDA_DIR}/bin/conda" init zsh > /dev/null 2>&1 || true
    fi

    echo "  Miniforge installed."
fi

# Make conda available in this script
eval "$("${CONDA_DIR}/bin/conda" shell.bash hook)"

# ---- Step 2: Create conda environment with bioinformatics tools -------------
echo ""
echo "[2/4] Setting up bioinformatics environment..."

ENV_NAME="metagenomics"

if conda env list | grep -q "^${ENV_NAME} "; then
    echo "  Environment '${ENV_NAME}' already exists — updating..."
    conda install -n "${ENV_NAME}" -y -q \
        -c bioconda -c conda-forge \
        diamond fastp sra-tools python requests > /dev/null 2>&1
else
    echo "  Creating environment '${ENV_NAME}' with DIAMOND, fastp, SRA-tools..."
    echo "  (This may take 5-10 minutes on first install)"
    conda create -n "${ENV_NAME}" -y -q \
        -c bioconda -c conda-forge \
        diamond fastp sra-tools python requests > /dev/null 2>&1
fi

# Activate and verify
conda activate "${ENV_NAME}"

echo ""
echo "  Verifying installations:"
echo "    diamond  $(diamond version 2>&1 | head -1)"
echo "    fastp    $(fastp --version 2>&1 | head -1)"
echo "    prefetch $(prefetch --version 2>&1 | head -1 || echo 'OK')"
echo "    python   $(python3 --version)"

# ---- Step 3: Download worker files from coordinator -------------------------
echo ""
echo "[3/4] Setting up worker directory..."

mkdir -p "${INSTALL_DIR}"

# If coordinator URL is set, download worker files from it
if [[ -n "${COORDINATOR_URL}" ]]; then
    echo "  Downloading worker files from coordinator..."
    for f in worker/__init__.py worker/worker.py worker/config.py worker/executor.py \
             worker/uploader.py worker/__main__.py process_sample_wrapper.sh; do
        dir="${INSTALL_DIR}/$(dirname "$f")"
        mkdir -p "$dir"
        curl -fsSL "${COORDINATOR_URL}/api/setup/file/${f}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -o "${INSTALL_DIR}/${f}" 2>/dev/null || true
    done
    chmod +x "${INSTALL_DIR}/process_sample_wrapper.sh" 2>/dev/null || true
    echo "  Files downloaded."
else
    echo "  NOTE: Set COORDINATOR_URL to auto-download worker files."
    echo "  For now, copy the 'worker/' directory and 'process_sample_wrapper.sh'"
    echo "  to: ${INSTALL_DIR}/"
fi

# ---- Step 4: Create launcher script -----------------------------------------
echo ""
echo "[4/4] Creating launcher..."

LAUNCHER="${INSTALL_DIR}/run_worker.sh"
cat > "${LAUNCHER}" << LAUNCHER_EOF
#!/bin/bash
# Auto-generated launcher — just run this to start the worker!
# Edit the settings below if needed.

export COORDINATOR_URL="${COORDINATOR_URL}"
export API_KEY="${API_KEY}"
export WORKER_NAME="${WORKER_NAME}"
export THREADS="${THREADS}"

# Activate conda environment
eval "\$(${CONDA_DIR}/bin/conda shell.bash hook)"
conda activate ${ENV_NAME}

cd "${INSTALL_DIR}"
echo ""
echo "Starting worker '${WORKER_NAME}'..."
echo "Coordinator: ${COORDINATOR_URL}"
echo "Threads: ${THREADS}"
echo "Press Ctrl+C to stop (finishes current task first)"
echo ""

python3 -m worker
LAUNCHER_EOF
chmod +x "${LAUNCHER}"

# Also create a Windows-friendly .bat launcher if on WSL
if [[ ${IS_WSL} -eq 1 ]]; then
    # Find Windows Desktop path
    WIN_DESKTOP=""
    for d in /mnt/c/Users/*/Desktop; do
        if [[ -d "$d" ]]; then
            WIN_DESKTOP="$d"
            break
        fi
    done

    if [[ -n "${WIN_DESKTOP}" ]]; then
        BAT_FILE="${WIN_DESKTOP}/Start_Metagenomics_Worker.bat"
        cat > "${BAT_FILE}" << BAT_EOF
@echo off
echo Starting Metagenomics Worker...
echo.
wsl -d Ubuntu -- bash -l -c "${LAUNCHER}"
pause
BAT_EOF
        echo "  Desktop shortcut created: Start_Metagenomics_Worker.bat"
    fi
fi

# ---- Done! ------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  To start the worker, run:"
echo "    ${LAUNCHER}"
echo ""
if [[ ${IS_WSL} -eq 1 ]]; then
    echo "  Or double-click 'Start_Metagenomics_Worker.bat' on your Desktop."
    echo ""
fi
echo "  Worker name: ${WORKER_NAME}"
echo "  Coordinator: ${COORDINATOR_URL}"
echo "  Threads:     ${THREADS}"
echo ""
