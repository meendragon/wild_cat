#!/bin/bash
# =============================================================
# fio_write2.sh v8 - meen/12G STABLE 버전
#
# v8 변경점:
#   - S6 (Realistic Mixed) 제거 - 모든 모드에서 abort, 모듈 손상 트리거
#   - 시나리오 사이 stabilize: 5초 → 20초 (chmodel 회수 시간)
#   - 위험 시나리오 (S3, S5) 전후 추가 sleep
#   - phase 사이 sleep 강화
#
# 시나리오: 1 → 2 → 4 → 7 → 3 → 5 (S6 빠짐)
# 모드당: ~30분
# 4모드: ~2시간
# =============================================================

WHICH=${1:-all}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"

FILL_NORMAL="6G"
FILL_S5="5G"

echo "=== $(date) === fio_write2 v8 STABLE [$WHICH] meen/12G" > "${LOG}"

# ── 공통 헬퍼 ────────────────────────────────────────────────
log_phase() {
    timeout 30 nvme flush "${DEV}" -n 1 2>/dev/null
    sleep 1
    echo "--- phase$1 ---" >> "${LOG}"
    dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"
}

scenario_header() {
    echo "" >> "${LOG}"
    echo "########## SCENARIO $1: $2 ##########" >> "${LOG}"
    echo ""
    echo "============================================"
    echo " Scenario $1: $2"
    echo "============================================"
}

scenario_aborted() {
    echo "########## SCENARIO $1 ABORTED ##########" >> "${LOG}"
    echo "  ❌ Scenario $1 중단됨"
}

# 시나리오 사이 정리 (20초로 강화)
stabilize() {
    echo "  · sync + fstrim + 20s sleep (chmodel 회수)"
    sync
    timeout 60 sudo fstrim "${DIR}" 2>/dev/null || true
    sleep 20
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

    echo "  ❌ Fill ${size} 최종 실패"
    return 1
}

rand_write() {
    local bs=$1 rt=$2 dist=$3 jobs=${4:-1} qd=${5:-32} name=$6
    local dist_arg=""
    if [ -n "${dist}" ] && [ "${dist}" != "uniform" ]; then
        dist_arg="--random_distribution=${dist}"
    fi
    local timeout_sec=$((rt + 30))

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=${jobs} --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name} >/dev/null 2>&1
    local ret=$?

    if [ $ret -eq 124 ]; then
        echo "  ⚠ ${name} timeout (${timeout_sec}s)"
    fi
    return $ret
}

run_scenario() {
    local sc_num=$1
    local sc_name=$2
    local fn=$3

    scenario_header "$sc_num" "$sc_name"
    if ! "$fn"; then
        scenario_aborted "$sc_num"
        return 1
    fi
    return 0
}

# ===================================================================
# SCENARIO 1: Strong Hotspot (8분)
# ===================================================================
scenario_1() {
    echo "[S1.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S1.1] zipf:2.0 4k 120s (learning)"
    rand_write 4k 120 zipf:2.0 1 32 s1p1 || return 1
    log_phase 1
    sleep 2

    echo "[S1.2] zipf:2.0 4k 120s (active GC)"
    rand_write 4k 120 zipf:2.0 1 32 s1p2 || return 1
    log_phase 2
    sleep 2

    echo "[S1.3] zipf:1.5 4k 90s (cool)"
    rand_write 4k 90 zipf:1.5 1 32 s1p3 || return 1
    log_phase 3
    sleep 2

    echo "[S1.4] zipf:2.0 4k 90s (back hot)"
    rand_write 4k 90 zipf:2.0 1 32 s1p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 2: Hot/Cold Oscillation (4분)
# ===================================================================
scenario_2() {
    echo "[S2.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S2.1] HOT zipf:2.0 4k 60s"
    rand_write 4k 60 zipf:2.0 1 32 s2p1 || return 1
    log_phase 1
    sleep 2

    echo "[S2.2] COLD uniform 4k 60s"
    rand_write 4k 60 uniform 1 32 s2p2 || return 1
    log_phase 2
    sleep 2

    echo "[S2.3] HOT zipf:2.0 4k 60s"
    rand_write 4k 60 zipf:2.0 1 32 s2p3 || return 1
    log_phase 3
    sleep 2

    echo "[S2.4] COLD uniform 4k 60s"
    rand_write 4k 60 uniform 1 32 s2p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 3: Long Convergence (8분, 위험 시나리오)
# ===================================================================
scenario_3() {
    echo "[S3.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    sleep 5  # 위험 시나리오라 추가 대기

    for P in 1 2 3 4; do
        echo "[S3.${P}] zipf:1.2 4k 120s"
        rand_write 4k 120 zipf:1.2 1 32 s3p${P} || return 1
        log_phase ${P}
        sleep 3
    done
    return 0
}

# ===================================================================
# SCENARIO 4: Gradient Heating (4분)
# ===================================================================
scenario_4() {
    echo "[S4.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S4.1] uniform 4k 60s (S3=0)"
    rand_write 4k 60 uniform 1 32 s4p1 || return 1
    log_phase 1
    sleep 2

    echo "[S4.2] zipf:0.8 4k 60s (S3=1)"
    rand_write 4k 60 zipf:0.8 1 32 s4p2 || return 1
    log_phase 2
    sleep 2

    echo "[S4.3] zipf:1.2 4k 60s (S3=2)"
    rand_write 4k 60 zipf:1.2 1 32 s4p3 || return 1
    log_phase 3
    sleep 2

    echo "[S4.4] zipf:2.0 4k 60s (S3=3)"
    rand_write 4k 60 zipf:2.0 1 32 s4p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 5: Mild Pressure (3분, 가장 위험)
# ===================================================================
scenario_5() {
    echo "[S5.0] Fill ${FILL_S5} (~67%)"
    do_fill ${FILL_S5} || return 1
    log_phase 0
    sleep 15  # 위험 시나리오 - 긴 sleep

    echo "[S5.1] zipf:1.5 4k qd=8 45s"
    rand_write 4k 45 zipf:1.5 1 8 s5p1 || return 1
    log_phase 1
    sleep 15

    echo "[S5.2] zipf:1.5 4k qd=8 45s"
    rand_write 4k 45 zipf:1.5 1 8 s5p2 || return 1
    log_phase 2
    sleep 15

    echo "[S5.3] uniform 4k qd=8 45s"
    rand_write 4k 45 uniform 1 8 s5p3 || return 1
    log_phase 3
    sleep 15

    echo "[S5.4] zipf:2.0 4k qd=8 45s"
    rand_write 4k 45 zipf:2.0 1 8 s5p4 || return 1
    log_phase 4
    return 0
}

# S6 (Realistic Mixed)는 v8에서 제거 — 모든 모드에서 abort, 모듈 손상

# ===================================================================
# SCENARIO 7: Multiple Distribution Shifts (4분)
# ===================================================================
scenario_7() {
    echo "[S7.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S7.1] zipf:2.0 4k 60s (very hot)"
    rand_write 4k 60 zipf:2.0 1 32 s7p1 || return 1
    log_phase 1
    sleep 2

    echo "[S7.2] uniform 4k 60s (cold drop)"
    rand_write 4k 60 uniform 1 32 s7p2 || return 1
    log_phase 2
    sleep 2

    echo "[S7.3] zipf:1.5 4k 60s (hot rise)"
    rand_write 4k 60 zipf:1.5 1 32 s7p3 || return 1
    log_phase 3
    sleep 2

    echo "[S7.4] zipf:0.8 4k 60s (warm down)"
    rand_write 4k 60 zipf:0.8 1 32 s7p4 || return 1
    log_phase 4
    return 0
}

# ── 디스패처 (S6 제거, 6개 시나리오) ─────────────────────────
START_TIME=$(date +%s)
SUCCESS=0
FAILED=0

run_one() {
    local num=$1
    local name=$2
    local fn=$3

    run_scenario "$num" "$name" "$fn"
    if [ $? -eq 0 ]; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    stabilize
}

case "$WHICH" in
    1) run_one 1 "Strong Hotspot zipf:2.0" scenario_1 ;;
    2) run_one 2 "Hot/Cold Oscillation" scenario_2 ;;
    3) run_one 3 "Long Convergence zipf:1.2" scenario_3 ;;
    4) run_one 4 "Gradient Heating cold->very hot" scenario_4 ;;
    5) run_one 5 "Mild Pressure 8G fill, qd=8" scenario_5 ;;
    7) run_one 7 "Multiple Distribution Shifts" scenario_7 ;;
    all)
        # S6 제거. 안전 순서: 부담 작은 것부터, S5는 마지막
        run_one 1 "Strong Hotspot zipf:2.0" scenario_1
        run_one 2 "Hot/Cold Oscillation" scenario_2
        run_one 4 "Gradient Heating cold->very hot" scenario_4
        run_one 7 "Multiple Distribution Shifts" scenario_7
        run_one 3 "Long Convergence zipf:1.2" scenario_3
        run_one 5 "Mild Pressure 8G fill, qd=8" scenario_5
        ;;
    *)
        echo "Usage: $0 [1|2|3|4|5|7|all]  (S6 제거됨)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write2 v8 done [$WHICH] - elapsed: ${MIN}m ${SEC}s ==="
echo "    성공: ${SUCCESS}, 실패: ${FAILED}"
echo ""
echo "=== Log content ==="
cat "${LOG}"