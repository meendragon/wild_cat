#!/bin/bash
# fio_write.sh - Multi-Phase Write Workload
#
# 모든 phase가 8G 전체 파일에 write → 영역 잠김 없음
# hot spot shift = zipf → uniform 전환 (분포 변화)
#
# sudo ./fio_write.sh
# LOG=./gc_log_0.txt sudo ./fio_write.sh

set -e

DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"

echo "=== $(date) ===" > "${LOG}"

# Phase 0: 8G fill
echo "[Phase 0] Fill..."
fio --directory="${DIR}" --direct=1 --ioengine=libaio \
    --rw=write --bs=128k --size=4G --numjobs=1 --name=workload

nvme flush "${DEV}" -n 1 && sleep 1
echo "--- phase0 ---" >> "${LOG}"
dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"

# Phase 1: Uniform Random (60s) → baseline
# 모든 policy 동일 출발점
echo "[Phase 1] Uniform random (60s)"
fio --filename="${FILE}" --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k \
    --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
    --time_based --runtime=60 --name=phase1_random

nvme flush "${DEV}" -n 1 && sleep 1
echo "--- phase1 ---" >> "${LOG}"
dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"

# Phase 2: Hot/Cold zipf:1.2 (120s) → CB 유리
# 8G 전체에 zipf → 강한 hot/cold 분리
# CB가 age로 hot 보호 → useless copy 감소
# Greedy는 hot 블록 건드려서 copied 증가
echo "[Phase 2] Hot/Cold zipf:1.2 (120s)"
fio --filename="${FILE}" --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k \
    --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
    --random_distribution=zipf:1.2 \
    --time_based --runtime=120 --name=phase2_hotcold

nvme flush "${DEV}" -n 1 && sleep 1
echo "--- phase2 ---" >> "${LOG}"
dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"

# Phase 3: Sequential Burst (120s) → CAT 유리 (wear 기준)
# 순차 덮어쓰기 → ipc 균등 → Greedy/CB 구분력 상실
# CAT만 erase_cnt 보고 wear-leveling
# 이 phase는 Wear max-min으로 비교
echo "[Phase 3] Sequential burst (120s)"
fio --filename="${FILE}" --direct=1 --ioengine=libaio \
    --rw=write --bs=128k \
    --numjobs=1 --iodepth=32 \
    --time_based --runtime=120 --name=phase3_seq

nvme flush "${DEV}" -n 1 && sleep 1
echo "--- phase3 ---" >> "${LOG}"
dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"

# Phase 4: 다시 Uniform Random (120s) → RL만 적응
# Phase 2에서 zipf로 형성된 hot/cold가 갑자기 uniform으로 전환
# CB/CAT는 이전 age 분포 기준으로 잘못 판단
# RL은 state 변화 감지 → 빠르게 재조정
echo "[Phase 4] Uniform random again (120s) - distribution shift"
fio --filename="${FILE}" --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k \
    --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
    --time_based --runtime=120 --name=phase4_shift

nvme flush "${DEV}" -n 1 && sleep 1
echo "--- phase4 ---" >> "${LOG}"
dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"

echo ""
echo "Done! Log:"
cat "${LOG}"