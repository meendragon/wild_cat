#!/bin/bash
# =============================================================
# fio_write7.sh v13 - CONTINUOUS MIXED WORKLOAD
#
# [핵심 차이 vs fio_write6]
#   - SINGLE fill (재충전 없음, fstrim 없음, stabilize 없음)
#   - 매 phase = 2개 fio job 동시 실행 (non-overlapping LBA)
#   - Wear 누적이 phase 경계에서 reset 안 됨 → state distribution 연속
#   - Total ~13 min/mode (vs fio_write6의 ~35 min)
#
# [설계 철학]
#   v5에서 CAT가 강했던 long uniform 구간 제거.
#   v5에서 RL이 강했던 패턴(multi-mode, 빠른 전환, 다중 magnitude)을
#   *동시에* 한 phase에 묶어버림.
#
#   Hypothesis: 정적 정책은 시점마다 하나의 (α, δ)만 적용 가능.
#   영역 A는 HOT, 영역 B는 COLD일 때 정적 정책은 평균에 맞춤.
#   RL은 state 관찰값(평균 hot ratio + trend)에 따라 GC마다 다른 선택 가능.
#
# [Phase 구성] (모두 120s, 2-job 동시 실행)
#   P1: HOT@0+2G zipf:2.0  ||  COLD@2G+7G uniform     (단일 hotspot + cold 배경)
#   P2: COLD@0+2G uniform  ||  HOT@2G+7G zipf:2.0     (swap: hot이 wider로)
#   P3: PEAK@0+1G zipf:2.5 ||  TILT@1G+8G zipf:1.0    (집중 + 확산 동시)
#   P4: WAVE-A@0+4G zipf:1.5 || WAVE-B@5G+4G zipf:0.8 (둘 다 약한 tilt, 영역간 격차)
#   P5: BI-A@0+3G zipf:1.8  ||  BI-B@6+3G zipf:1.8    (S11 정신, gap 큼)
#   P6: OFFSET@3G+1G zipf:2.5 || TAIL@5G+4G uniform   (off-center hot + cold tail)
#
# [안전 보장]
#   - 모든 phase 영역 non-overlapping (fio 동시 write 충돌 회피)
#   - iodepth 16/job × 2 job = 32 (커널 IO queue 안전 범위)
#   - 각 phase timeout, fstrim 없음 (모듈 stress 회피)
#   - fill 한 번만, 1G/2G/4G 같은 표준 power-of-2 offset만 사용
# =============================================================

DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"
FILL_SIZE="6G"
PHASE_TIME=${PHASE_TIME:-120}   # env로 조절 가능

echo "=== $(date) === fio_write7 v13 [continuous mix] meen/12G" > "${LOG}"

# ── 헬퍼 ─────────────────────────────────────────────────────
log_phase() {
    timeout 30 nvme flush "${DEV}" -n 1 2>/dev/null
    sleep 1
    echo "--- phase$1 ---" >> "${LOG}"
    dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"
}

do_fill() {
    local size=$1
    local attempt=1
    while [ $attempt -le 2 ]; do
        if timeout 300 fio --filename="${FILE}" --direct=1 --ioengine=libaio \
            --rw=write --bs=128k --size=${size} --numjobs=1 \
            --name=fill >/dev/null 2>&1
        then
            return 0
        fi
        echo "  ⚠ Fill ${size} 시도 $attempt 실패"
        if [ $attempt -lt 2 ]; then
            sync
            timeout 60 sudo fstrim "${DIR}" 2>/dev/null || true
            sleep 30
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# 단일 job (전체 영역)
rand_write_full() {
    local bs=$1 rt=$2 dist=$3 qd=${4:-32} name=$5
    local dist_arg=""
    [ -n "${dist}" ] && [ "${dist}" != "uniform" ] && dist_arg="--random_distribution=${dist}"
    local timeout_sec=$((rt + 30))
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name} >/dev/null 2>&1
    local ret=$?
    [ $ret -eq 124 ] && echo "  ⚠ ${name} timeout"
    return $ret
}

# 2개 job 병렬, 서로 다른 region + 서로 다른 distribution
dual_mix() {
    local bs=$1 rt=$2 qd=$3
    local offset1=$4 size1=$5 dist1=$6
    local offset2=$7 size2=$8 dist2=$9
    local name=${10}
    local timeout_sec=$((rt + 30))
    local d1=""; [ -n "${dist1}" ] && [ "${dist1}" != "uniform" ] && d1="--random_distribution=${dist1}"
    local d2=""; [ -n "${dist2}" ] && [ "${dist2}" != "uniform" ] && d2="--random_distribution=${dist2}"

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset1} --size=${size1} ${d1} \
        --time_based --runtime=${rt} --name=${name}_A >/dev/null 2>&1 &
    local pidA=$!

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset2} --size=${size2} ${d2} \
        --time_based --runtime=${rt} --name=${name}_B >/dev/null 2>&1 &
    local pidB=$!

    wait $pidA; local rA=$?
    wait $pidB; local rB=$?
    if [ $rA -ne 0 ] || [ $rB -ne 0 ]; then
        echo "  ⚠ ${name} dual failed (A=$rA, B=$rB)"
        return 1
    fi
    return 0
}

# ── 메인 ─────────────────────────────────────────────────────
START_TIME=$(date +%s)

echo "============================================"
echo " fio_write7: continuous mixed (no re-fill)"
echo "============================================"

# === 단일 fill ===
echo "[FILL] ${FILL_SIZE} sequential 128k"
do_fill ${FILL_SIZE} || { echo "❌ Fill failed"; exit 1; }
log_phase 0

# === Phase 1: 단일 hotspot + cold 배경 ===
echo "[P1 ${PHASE_TIME}s] HOT@0+2G zipf:2.0  ||  COLD@2G+7G uniform"
dual_mix 4k ${PHASE_TIME} 16  0 2G zipf:2.0  2G 7G uniform   p1 || exit 1
log_phase 1

# === Phase 2: swap — hot이 wider로, cold가 좁은 영역으로 ===
echo "[P2 ${PHASE_TIME}s] COLD@0+2G uniform  ||  HOT@2G+7G zipf:2.0"
dual_mix 4k ${PHASE_TIME} 16  0 2G uniform   2G 7G zipf:2.0  p2 || exit 1
log_phase 2

# === Phase 3: 집중 peak + 확산 tilt 동시 (multi-magnitude) ===
echo "[P3 ${PHASE_TIME}s] PEAK@0+1G zipf:2.5  ||  TILT@1G+8G zipf:1.0"
dual_mix 4k ${PHASE_TIME} 16  0 1G zipf:2.5  1G 8G zipf:1.0  p3 || exit 1
log_phase 3

# === Phase 4: 약한 dual tilt — wear leveling 능력 stress ===
echo "[P4 ${PHASE_TIME}s] WAVE-A@0+4G zipf:1.5  ||  WAVE-B@5G+4G zipf:0.8"
dual_mix 4k ${PHASE_TIME} 16  0 4G zipf:1.5  5G 4G zipf:0.8  p4 || exit 1
log_phase 4

# === Phase 5: bimodal — 두 hot 영역 + cold gap ===
echo "[P5 ${PHASE_TIME}s] BI-A@0+3G zipf:1.8  ||  BI-B@6+3G zipf:1.8"
dual_mix 4k ${PHASE_TIME} 16  0 3G zipf:1.8  6G 3G zipf:1.8  p5 || exit 1
log_phase 5

# === Phase 6: 비대칭 — off-center hot + 우측 cold ===
echo "[P6 ${PHASE_TIME}s] OFFSET@3G+1G zipf:2.5  ||  TAIL@5G+4G uniform"
dual_mix 4k ${PHASE_TIME} 16  3G 1G zipf:2.5  5G 4G uniform  p6 || exit 1
log_phase 6

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write7 v13 done - elapsed: ${MIN}m ${SEC}s ==="
echo "    phase time: ${PHASE_TIME}s × 6 = $((PHASE_TIME * 6 / 60))min workload"
echo ""
echo "=== Log content ==="
cat "${LOG}"