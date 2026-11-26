#!/usr/bin/env python3
"""One build and one native stacking probe, submitted through ./farm exec."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
subprocess.run(['./build.sh'], cwd=root, check=True)
sys.path.insert(0, str(root / 'evals/golden'))
from small_window_stacking import run
sys.exit(run(root / 'build/Pane Dev.app', Path(os.environ['YAB_FARM_OUT']) / 'stacking'))
