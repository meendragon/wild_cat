#!/bin/bash
# =============================================================
# fio_write5.sh v11 - meen/12G STABLE
#
# v11 변경점 (v10 대비):
#   [유지] S1, S2, S11, S12, S13, S10, S5 — v4에서 RL CoV 7전 7승
#   [신규] S14 Inverse Cliff      — S12의 대칭(contraction)
#   [신규] S15 Volatile Bimodal   — multi-mode × oscillation
#
# RL이 입증한 강점:
#   1) 강한 locality (S1, S5)
#   2) 빠른 분포 전환 (S2, S10)
#   3) 공간 multi-mode (S11)
#   4) Working set 확장 cliff (S12)
#   5) 같은 shape, 다른 magnitude (S13)
#   6) α 해제 능력 (S10)
#   → S14, S15는 위 강점들의 비어있는 칸을 채움
#
# 시나리오 흐름: S1 → S2 → S11 → S12 → S14 → S13 → S15 → S10 → S5
# 모드당: ~43분, 4모드: ~2.9시간
# =============================================================

WHICH=${1:-all}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"

FILL_NORMAL="6G"
FILL_S5="5G"

echo "=== $(date) === fio_write5 v11 [$WHICH] meen/12G" > "${LOG}"

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
    [ $ret -eq 124 ] && echo "  ⚠ ${name} timeout (${timeout_sec}s)"
    return $ret
}

rand_write_window() {
    local bs=$1 rt=$2 dist=$3 jobs=$4 qd=$5
    local offset=$6 size=$7 name=$8
    local dist_arg=""
    if [ -n "${dist}" ] && [ "${dist}" != "uniform" ]; then
        dist_arg="--random_distribution=${dist}"
    fi
    local timeout_sec=$((rt + 30))

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=${jobs} --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset} --size=${size} \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name} >/dev/null 2>&1
    local ret=$?
    [ $ret -eq 124 ] && echo "  ⚠ ${name} timeout (${timeout_sec}s) [window=${offset}+${size}]"
    return $ret
}

# 두 영역에 동시 random write, 같은 distribution (S11용)
rand_write_dual() {
    local bs=$1 rt=$2 dist=$3 qd=$4
    local offset1=$5 size1=$6 offset2=$7 size2=$8 name=$9
    local dist_arg=""
    if [ -n "${dist}" ] && [ "${dist}" != "uniform" ]; then
        dist_arg="--random_distribution=${dist}"
    fi
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

    if [ $rA -ne 0 ] || [ $rB -ne 0 ]; then
        echo "  ⚠ ${name} dual failed (A=$rA, B=$rB)"
        return 1
    fi
    return 0
}

# 두 영역에 *다른* distribution 동시 random write (S15용)
rand_write_dual_mixed() {
    local bs=$1 rt=$2 qd=$3
    local offset1=$4 size1=$5 dist1=$6
    local offset2=$7 size2=$8 dist2=$9
    local name=${10}
    local timeout_sec=$((rt + 30))

    local dist_arg1=""
    if [ -n "${dist1}" ] && [ "${dist1}" != "uniform" ]; then
        dist_arg1="--random_distribution=${dist1}"
    fi
    local dist_arg2=""
    if [ -n "${dist2}" ] && [ "${dist2}" != "uniform" ]; then
        dist_arg2="--random_distribution=${dist2}"
    fi

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset1} --size=${size1} \
        ${dist_arg1} \
        --time_based --runtime=${rt} --name=${name}_A >/dev/null 2>&1 &
    local pidA=$!

    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset2} --size=${size2} \
        ${dist_arg2} \
        --time_based --runtime=${rt} --name=${name}_B >/dev/null 2>&1 &
    local pidB=$!

    wait $pidA; local rA=$?
    wait $pidB; local rB=$?

    if [ $rA -ne 0 ] || [ $rB -ne 0 ]; then
        echo "  ⚠ ${name} dual_mixed failed (A=$rA, B=$rB)"
        return 1
    fi
    return 0
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
# SCENARIO 1: Strong Hotspot (유지) — RL 핵심 showcase
#   v4: RL CoV 1.428 vs CAT 1.857, max EC 116 vs CAT 177
# ===================================================================
scenario_1() {
    echo "[S1.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S1.1] zipf:2.0 4k 120s"
    rand_write 4k 120 zipf:2.0 1 32 s1p1 || return 1
    log_phase 1; sleep 2

    echo "[S1.2] zipf:2.0 4k 120s"
    rand_write 4k 120 zipf:2.0 1 32 s1p2 || return 1
    log_phase 2; sleep 2

    echo "[S1.3] zipf:1.5 4k 90s"
    rand_write 4k 90 zipf:1.5 1 32 s1p3 || return 1
    log_phase 3; sleep 2

    echo "[S1.4] zipf:2.0 4k 90s"
    rand_write 4k 90 zipf:2.0 1 32 s1p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 2: Hot/Cold Oscillation (유지) — 분포 전환 능력
#   v4: RL CoV 0.888 vs CAT 1.027
# ===================================================================
scenario_2() {
    echo "[S2.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S2.1] HOT zipf:2.0 4k 60s"
    rand_write 4k 60 zipf:2.0 1 32 s2p1 || return 1
    log_phase 1; sleep 2

    echo "[S2.2] COLD uniform 4k 60s"
    rand_write 4k 60 uniform 1 32 s2p2 || return 1
    log_phase 2; sleep 2

    echo "[S2.3] HOT zipf:2.0 4k 60s"
    rand_write 4k 60 zipf:2.0 1 32 s2p3 || return 1
    log_phase 3; sleep 2

    echo "[S2.4] COLD uniform 4k 60s"
    rand_write 4k 60 uniform 1 32 s2p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 11: Bimodal Hotspot (유지) — 공간 multi-mode
#   v4: RL CoV 0.800 vs CAT 0.965 (CAT는 phase 진행 중 CoV 증가)
# ===================================================================
scenario_11() {
    echo "[S11.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S11.1] dual zipf:1.8 [0G+2G, 4G+2G] 60s"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p1 || return 1
    log_phase 1; sleep 2

    echo "[S11.2] dual zipf:1.8 [0G+2G, 4G+2G] 60s (continue)"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p2 || return 1
    log_phase 2; sleep 2

    echo "[S11.3] dual zipf:1.8 [2G+2G, 6G+2G] 60s (both shift)"
    rand_write_dual 4k 60 zipf:1.8 16 2G 2G 6G 2G s11p3 || return 1
    log_phase 3; sleep 2

    echo "[S11.4] dual zipf:1.8 [0G+2G, 6G+2G] 60s (asymmetric)"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 6G 2G s11p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 12: Working Set Cliff (유지) — 갑작스런 확장
#   v4: RL CoV 0.652 vs CAT 0.763 (cliff 전후 모두 RL 우위)
# ===================================================================
scenario_12() {
    echo "[S12.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S12.1] zipf:2.5 window 0+1G 60s (concentrated)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p1 || return 1
    log_phase 1; sleep 2

    echo "[S12.2] zipf:2.5 window 0+1G 60s (heat accumulates)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p2 || return 1
    log_phase 2; sleep 2

    echo "[S12.3] uniform whole 9G 60s (CLIFF: 90× 확장)"
    rand_write 4k 60 uniform 1 32 s12p3 || return 1
    log_phase 3; sleep 2

    echo "[S12.4] uniform whole 9G 60s (continued spread)"
    rand_write 4k 60 uniform 1 32 s12p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 14: Inverse Cliff (NEW) — 갑작스런 *수축*, S12의 대칭
#
#   [목적]
#     S12가 working set 확장 cliff를 다뤘다면, S14는 *수축* 을 다룸.
#     - p1-2: uniform 9G로 cold baseline 형성 (wear 평탄화)
#     - p3 (CLIFF): 갑자기 zipf:2.5 in 1G로 90× 수축
#     - p4: 수축 상태 지속
#
#   [왜 RL이 유리해야 하나]
#     수축 cliff는 모든 정책에 GC 부담을 늘림 (LBA 0-500M의 hot 라인이
#     반복적으로 invalidate). 정적 CAT의 δ=1은 이 급변에 즉시 대응 못 함.
#     RL은 S3 (hot ratio) 급상승 + S4 (positive trend) 감지해 α/δ 동시 조절.
#
#   [예상 거동]
#     - p1-2: 모두 wear 평탄화 (uniform은 누구나 잘 처리)
#     - p3-4: RL은 cliff 직후 빠르게 α↑로 hot 라인 보호.
#       정적 CAT는 균등한 wear-leveling을 유지하려다 hot region에 erase 누적.
# ===================================================================
scenario_14() {
    echo "[S14.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S14.1] uniform whole 9G 60s (cold baseline)"
    rand_write 4k 60 uniform 1 32 s14p1 || return 1
    log_phase 1; sleep 2

    echo "[S14.2] uniform whole 9G 60s (continued spread)"
    rand_write 4k 60 uniform 1 32 s14p2 || return 1
    log_phase 2; sleep 2

    echo "[S14.3] zipf:2.5 window 0+1G 60s (CLIFF: 90× 수축)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s14p3 || return 1
    log_phase 3; sleep 2

    echo "[S14.4] zipf:2.5 window 0+1G 60s (sustained)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s14p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 13: Hotspot Resize (유지) — magnitude 변화
#   v4: RL CoV 0.593 vs CAT 0.707
# ===================================================================
scenario_13() {
    echo "[S13.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S13.1] zipf:1.5 window 0+1G 60s (small hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p1 || return 1
    log_phase 1; sleep 2

    echo "[S13.2] zipf:1.5 window 0+2G 60s (medium hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 2G s13p2 || return 1
    log_phase 2; sleep 2

    echo "[S13.3] zipf:1.5 window 0+5G 60s (wide hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 5G s13p3 || return 1
    log_phase 3; sleep 2

    echo "[S13.4] zipf:1.5 window 0+1G 60s (back to small)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 15: Volatile Bimodal (NEW) — multi-mode × oscillation
#
#   [목적]
#     S11 (정적 bimodal) + S2 (oscillation) 의 합성.
#     두 영역이 *독립적으로* hot↔cold 진동.
#
#   [phase 설계]
#     - p1: A=HOT (zipf:2.0), B=COLD (uniform)
#     - p2: A=COLD (uniform), B=HOT (zipf:2.0)        ← swap
#     - p3: A=HOT, B=HOT                              ← both hot
#     - p4: A=COLD, B=COLD                            ← both cold
#
#   [왜 RL이 유리해야 하나]
#     정적 정책은 *시점마다* 하나의 (α, δ) 만 적용 가능. 두 영역이 다른
#     온도 상태일 때 양쪽에 최적인 α는 없음 (한쪽이 hot이면 α↑가 정답, 
#     동시에 다른 쪽 cold면 α↓가 정답).
#     RL은 평균적 hot_ratio + trend 를 보고 시점별 최선 policy 선택.
#     이론적으로 가장 어려운 환경 — RL이 여기서 이기면 모든 강점 입증.
#
#   [구현]
#     rand_write_dual_mixed: 두 region에 다른 distribution 적용
# ===================================================================
scenario_15() {
    echo "[S15.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S15.1] A=zipf:2.0(0G+2G) B=uniform(4G+2G) 60s"
    rand_write_dual_mixed 4k 60 16 0 2G zipf:2.0 4G 2G uniform s15p1 || return 1
    log_phase 1; sleep 2

    echo "[S15.2] A=uniform(0G+2G) B=zipf:2.0(4G+2G) 60s (swap)"
    rand_write_dual_mixed 4k 60 16 0 2G uniform 4G 2G zipf:2.0 s15p2 || return 1
    log_phase 2; sleep 2

    echo "[S15.3] A=zipf:2.0 B=zipf:2.0 60s (both HOT)"
    rand_write_dual_mixed 4k 60 16 0 2G zipf:2.0 4G 2G zipf:2.0 s15p3 || return 1
    log_phase 3; sleep 2

    echo "[S15.4] A=uniform B=uniform 60s (both COLD)"
    rand_write_dual_mixed 4k 60 16 0 2G uniform 4G 2G uniform s15p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 10: Decaying Locality (유지) — α 해제 능력
#   v4: RL CoV 0.509 vs CAT 0.609
# ===================================================================
scenario_10() {
    echo "[S10.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S10.1] zipf:2.0 4k 60s (very hot)"
    rand_write 4k 60 zipf:2.0 1 32 s10p1 || return 1
    log_phase 1; sleep 2

    echo "[S10.2] zipf:1.5 4k 60s (cooling)"
    rand_write 4k 60 zipf:1.5 1 32 s10p2 || return 1
    log_phase 2; sleep 2

    echo "[S10.3] zipf:0.8 4k 60s (warm)"
    rand_write 4k 60 zipf:0.8 1 32 s10p3 || return 1
    log_phase 3; sleep 2

    echo "[S10.4] uniform 4k 60s (cold)"
    rand_write 4k 60 uniform 1 32 s10p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 5: Mild Pressure (유지) — 저 QD edge case
#   v4: RL CoV 0.460 vs CAT 0.550 (드디어 RL이 단독 1위로!)
# ===================================================================
scenario_5() {
    echo "[S5.0] Fill ${FILL_S5} (~67%)"
    do_fill ${FILL_S5} || return 1
    log_phase 0
    sleep 15

    echo "[S5.1] zipf:1.5 4k qd=8 45s"
    rand_write 4k 45 zipf:1.5 1 8 s5p1 || return 1
    log_phase 1; sleep 15

    echo "[S5.2] zipf:1.5 4k qd=8 45s"
    rand_write 4k 45 zipf:1.5 1 8 s5p2 || return 1
    log_phase 2; sleep 15

    echo "[S5.3] uniform 4k qd=8 45s"
    rand_write 4k 45 uniform 1 8 s5p3 || return 1
    log_phase 3; sleep 15

    echo "[S5.4] zipf:2.0 4k qd=8 45s"
    rand_write 4k 45 zipf:2.0 1 8 s5p4 || return 1
    log_phase 4
    return 0
}

# ── 디스패처 ─────────────────────────────────────────────────
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
    1)  run_one 1  "Strong Hotspot zipf:2.0"        scenario_1 ;;
    2)  run_one 2  "Hot/Cold Oscillation"           scenario_2 ;;
    5)  run_one 5  "Mild Pressure 8G fill, qd=8"    scenario_5 ;;
    10) run_one 10 "Decaying Locality (reverse)"    scenario_10 ;;
    11) run_one 11 "Bimodal Hotspot"                scenario_11 ;;
    12) run_one 12 "Working Set Cliff (expansion)"  scenario_12 ;;
    13) run_one 13 "Hotspot Resize"                 scenario_13 ;;
    14) run_one 14 "Inverse Cliff (contraction)"    scenario_14 ;;
    15) run_one 15 "Volatile Bimodal"               scenario_15 ;;
    all)
        # 순서: 단일hot → oscillation → multi-mode → cliff pair → resize 
        #     → volatile multi-mode → decay → mild
        run_one 1  "Strong Hotspot zipf:2.0"        scenario_1
        run_one 2  "Hot/Cold Oscillation"           scenario_2
        run_one 11 "Bimodal Hotspot"                scenario_11
        run_one 12 "Working Set Cliff (expansion)"  scenario_12
        run_one 14 "Inverse Cliff (contraction)"    scenario_14
        run_one 13 "Hotspot Resize"                 scenario_13
        run_one 15 "Volatile Bimodal"               scenario_15
        run_one 10 "Decaying Locality (reverse)"    scenario_10
        run_one 5  "Mild Pressure 8G fill, qd=8"    scenario_5
        ;;
    *)
        echo "Usage: $0 [1|2|5|10|11|12|13|14|15|all]"
        echo "  유지(v4 RL 7전 7승): 1, 2, 5, 10, 11, 12, 13"
        echo "  신규: 14 (Inverse Cliff), 15 (Volatile Bimodal)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write5 v11 done [$WHICH] - elapsed: ${MIN}m ${SEC}s ==="
echo "    성공: ${SUCCESS}, 실패: ${FAILED}"
echo ""
echo "=== Log content ==="
cat "${LOG}"