#!/usr/bin/env bash
# Launch the mail-agent Streamlit UI. Run:  bash run-ui.sh
cd "$(dirname "$0")"
export PATH="$PATH:$HOME/.local/bin:$HOME/scoop/shims"
PORT="${1:-8502}"
# pick whichever python is available
PY=python; command -v python >/dev/null 2>&1 || PY=py
"$PY" -m pip install --quiet streamlit pandas openpyxl pypdf python-docx pillow pytesseract 2>/dev/null
"$PY" -m streamlit run app.py --server.port "$PORT"
