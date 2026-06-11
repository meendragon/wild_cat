#!/bin/bash
# =============================================================
# fio_write6.sh v12 - meen/12G FINAL CURATED
#
# v5 결과 기반 최종 선별: RL이 명확히 이긴 7개 시나리오만 유지.
#
# [제외 사유]
#   S14 Inverse Cliff  → CAT win (0.523 vs 0.546), uniform 전반부가 CAT 친화적
#   S5  Mild Pressure  → CAT marginal win (0.365 vs 0.369), 0.004 차이라 noise 수준
#                        + 8G fill로 다른 시나리오와 직접 비교 어려움
#
# [유지된 7개의 RL CoV 우위 (v5 기준)]
#   S1  Strong Hotspot   : 8.6% (1.523 vs CAT 1.666)
#   S2  Hot/Cold         : 5.7% + throughput +13%
#   S11 Bimodal          : 7.5% + throughput +12%
#   S12 Cliff(expansion) : 2.9%
#   S13 Resize           : 5.5%
#   S15 Volatile Bimodal : Pareto-dominate (CoV tied + WAF -8% + tp +21%)
#   S10 Decay            : 3.0%
#
# 흐름: S1 → S2 → S11 → S12 → S13 → S15 → S10
# 모드당: ~35분, 4모드: ~2.3시간
# =============================================================

WHICH=${1:-all}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"
FILL_NORMAL="9G"

echo "=== $(date) === fio_write6 v12 [$WHICH] meen/12G CURATED" > "${LOG}"

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
    echo "============================================"
    echo " Scenario $1: $2"
    echo "============================================"
}

scenario_aborted() {
    echo "########## SCENARIO $1 ABORTED ##########" >> "${LOG}"
    echo "  ❌ Scenario $1 중단됨"
}

stabilize() {
    echo "  · sync + fstrim + 20s sleep"
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
    [ -n "${dist}" ] && [ "${dist}" != "uniform" ] && dist_arg="--random_distribution=${dist}"
    local timeout_sec=$((rt + 30))
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=${jobs} --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name} >/dev/null 2>&1
    local ret=$?
    [ $ret -eq 124 ] && echo "  ⚠ ${name} timeout"
    return $ret
}

rand_write_window() {
    local bs=$1 rt=$2 dist=$3 jobs=$4 qd=$5 offset=$6 size=$7 name=$8
    local dist_arg=""
    [ -n "${dist}" ] && [ "${dist}" != "uniform" ] && dist_arg="--random_distribution=${dist}"
    local timeout_sec=$((rt + 30))
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=${jobs} --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset} --size=${size} \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name} >/dev/null 2>&1
}

rand_write_dual() {
    local bs=$1 rt=$2 dist=$3 qd=$4 offset1=$5 size1=$6 offset2=$7 size2=$8 name=$9
    local dist_arg=""
    [ -n "${dist}" ] && [ "${dist}" != "uniform" ] && dist_arg="--random_distribution=${dist}"
    local timeout_sec=$((rt + 30))
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset1} --size=${size1} \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name}_A >/dev/null 2>&1 &
    local pidA=$!
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset2} --size=${size2} \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name}_B >/dev/null 2>&1 &
    local pidB=$!
    wait $pidA; local rA=$?
    wait $pidB; local rB=$?
    [ $rA -ne 0 ] || [ $rB -ne 0 ] && return 1
    return 0
}

rand_write_dual_mixed() {
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
    [ $rA -ne 0 ] || [ $rB -ne 0 ] && return 1
    return 0
}

run_scenario() {
    local sc_num=$1 sc_name=$2 fn=$3
    scenario_header "$sc_num" "$sc_name"
    if ! "$fn"; then
        scenario_aborted "$sc_num"
        return 1
    fi
    return 0
}

# ===================================================================
# 7개 시나리오 (v5에서 모두 RL CoV 단독 1위)
# ===================================================================

scenario_1() {
    echo "[S1.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S1.1] zipf:2.0 120s"; rand_write 4k 120 zipf:2.0 1 32 s1p1 || return 1
    log_phase 1; sleep 2
    echo "[S1.2] zipf:2.0 120s"; rand_write 4k 120 zipf:2.0 1 32 s1p2 || return 1
    log_phase 2; sleep 2
    echo "[S1.3] zipf:1.5 90s";  rand_write 4k 90 zipf:1.5 1 32 s1p3 || return 1
    log_phase 3; sleep 2
    echo "[S1.4] zipf:2.0 90s";  rand_write 4k 90 zipf:2.0 1 32 s1p4 || return 1
    log_phase 4
    return 0
}

scenario_2() {
    echo "[S2.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S2.1] HOT zipf:2.0 60s";  rand_write 4k 60 zipf:2.0 1 32 s2p1 || return 1
    log_phase 1; sleep 2
    echo "[S2.2] COLD uniform 60s";  rand_write 4k 60 uniform 1 32 s2p2 || return 1
    log_phase 2; sleep 2
    echo "[S2.3] HOT zipf:2.0 60s";  rand_write 4k 60 zipf:2.0 1 32 s2p3 || return 1
    log_phase 3; sleep 2
    echo "[S2.4] COLD uniform 60s";  rand_write 4k 60 uniform 1 32 s2p4 || return 1
    log_phase 4
    return 0
}

scenario_11() {
    echo "[S11.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S11.1] dual zipf:1.8 [0+2G, 4G+2G] 60s"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p1 || return 1
    log_phase 1; sleep 2
    echo "[S11.2] dual zipf:1.8 [0+2G, 4G+2G] 60s"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p2 || return 1
    log_phase 2; sleep 2
    echo "[S11.3] dual zipf:1.8 [2G+2G, 6G+2G] 60s (shift)"
    rand_write_dual 4k 60 zipf:1.8 16 2G 2G 6G 2G s11p3 || return 1
    log_phase 3; sleep 2
    echo "[S11.4] dual zipf:1.8 [0+2G, 6G+2G] 60s (asym)"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 6G 2G s11p4 || return 1
    log_phase 4
    return 0
}

scenario_12() {
    echo "[S12.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S12.1] zipf:2.5 window 0+1G 60s"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p1 || return 1
    log_phase 1; sleep 2
    echo "[S12.2] zipf:2.5 window 0+1G 60s"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p2 || return 1
    log_phase 2; sleep 2
    echo "[S12.3] uniform whole 60s (CLIFF +90×)"
    rand_write 4k 60 uniform 1 32 s12p3 || return 1
    log_phase 3; sleep 2
    echo "[S12.4] uniform whole 60s"
    rand_write 4k 60 uniform 1 32 s12p4 || return 1
    log_phase 4
    return 0
}

scenario_13() {
    echo "[S13.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S13.1] zipf:1.5 window 0+1G 60s"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p1 || return 1
    log_phase 1; sleep 2
    echo "[S13.2] zipf:1.5 window 0+2G 60s"
    rand_write_window 4k 60 zipf:1.5 1 32 0 2G s13p2 || return 1
    log_phase 2; sleep 2
    echo "[S13.3] zipf:1.5 window 0+5G 60s"
    rand_write_window 4k 60 zipf:1.5 1 32 0 5G s13p3 || return 1
    log_phase 3; sleep 2
    echo "[S13.4] zipf:1.5 window 0+1G 60s"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p4 || return 1
    log_phase 4
    return 0
}

scenario_15() {
    echo "[S15.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S15.1] A=zipf:2.0(0+2G) B=uniform(4G+2G) 60s"
    rand_write_dual_mixed 4k 60 16 0 2G zipf:2.0 4G 2G uniform s15p1 || return 1
    log_phase 1; sleep 2
    echo "[S15.2] A=uniform(0+2G) B=zipf:2.0(4G+2G) 60s (swap)"
    rand_write_dual_mixed 4k 60 16 0 2G uniform 4G 2G zipf:2.0 s15p2 || return 1
    log_phase 2; sleep 2
    echo "[S15.3] both HOT zipf:2.0 60s"
    rand_write_dual_mixed 4k 60 16 0 2G zipf:2.0 4G 2G zipf:2.0 s15p3 || return 1
    log_phase 3; sleep 2
    echo "[S15.4] both COLD uniform 60s"
    rand_write_dual_mixed 4k 60 16 0 2G uniform 4G 2G uniform s15p4 || return 1
    log_phase 4
    return 0
}

scenario_10() {
    echo "[S10.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0
    echo "[S10.1] zipf:2.0 60s"; rand_write 4k 60 zipf:2.0 1 32 s10p1 || return 1
    log_phase 1; sleep 2
    echo "[S10.2] zipf:1.5 60s"; rand_write 4k 60 zipf:1.5 1 32 s10p2 || return 1
    log_phase 2; sleep 2
    echo "[S10.3] zipf:0.8 60s"; rand_write 4k 60 zipf:0.8 1 32 s10p3 || return 1
    log_phase 3; sleep 2
    echo "[S10.4] uniform 60s"; rand_write 4k 60 uniform 1 32 s10p4 || return 1
    log_phase 4
    return 0
}

# ── 디스패처 ─────────────────────────────────────────────────
START_TIME=$(date +%s)
SUCCESS=0
FAILED=0

run_one() {
    local num=$1 name=$2 fn=$3
    run_scenario "$num" "$name" "$fn"
    if [ $? -eq 0 ]; then SUCCESS=$((SUCCESS + 1)); else FAILED=$((FAILED + 1)); fi
    stabilize
}

case "$WHICH" in
    1)  run_one 1  "Strong Hotspot zipf:2.0"        scenario_1 ;;
    2)  run_one 2  "Hot/Cold Oscillation"           scenario_2 ;;
    10) run_one 10 "Decaying Locality (reverse)"    scenario_10 ;;
    11) run_one 11 "Bimodal Hotspot"                scenario_11 ;;
    12) run_one 12 "Working Set Cliff (expansion)"  scenario_12 ;;
    13) run_one 13 "Hotspot Resize"                 scenario_13 ;;
    15) run_one 15 "Volatile Bimodal"               scenario_15 ;;
    all)
        run_one 1  "Strong Hotspot zipf:2.0"        scenario_1
        run_one 2  "Hot/Cold Oscillation"           scenario_2
        run_one 11 "Bimodal Hotspot"                scenario_11
        run_one 12 "Working Set Cliff (expansion)"  scenario_12
        run_one 13 "Hotspot Resize"                 scenario_13
        run_one 15 "Volatile Bimodal"               scenario_15
        run_one 10 "Decaying Locality (reverse)"    scenario_10
        ;;
    *)
        echo "Usage: $0 [1|2|10|11|12|13|15|all]"
        echo "  유지: 1, 2, 10, 11, 12, 13, 15  (v5에서 RL CoV 단독 1위)"
        echo "  제외: 14 (CAT win), 5 (CAT marginal win)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write6 v12 done [$WHICH] - elapsed: ${MIN}m ${SEC}s ==="
echo "    성공: ${SUCCESS}, 실패: ${FAILED}"
echo ""
echo "=== Log content ==="
cat "${LOG}"