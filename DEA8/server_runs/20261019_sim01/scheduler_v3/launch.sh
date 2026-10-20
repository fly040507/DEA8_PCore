#!/bin/bash
set -eu
cd /home/zhaofei/eda_runs/DEA8_panda/20261019_sim01/scheduler_v3
source /opt/Vivado/Vivado/2023.1/settings64.sh
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/ionice -c 3 /opt/Mentor/calibre2022_aoj/aoj_cal_2022.2_38.20/pkgs/icv_python/asp/bin/python3.8 -B -u ./scheduler.py > launcher.log 2>&1
