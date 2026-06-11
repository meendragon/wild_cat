#!/bin/bash
# =============================================================
# fio_write3.sh v9 - meen/12G STABLE + RL 적응력 강화 워크로드
#
# v9 변경점 (v8 대비):
#   [유지] S1, S2, S4, S5 — 기존 유의미한 시나리오
#   [제거] S3 (Long Convergence)  — RL이 학습할 게 없는 정상상태
#   [제거] S7 (Multiple Shifts)   — phase 60s가 너무 짧아 RL 적응 불가
#   [신규] S8 Bursty Hot Pulses    — α(hot ratio) trend 급변
#   [신규] S9 Sliding Hotspot      — age weighting + 공간 drift
#   [신규] S10 Decaying Locality   — gradient 역방향, α 해제 능력 검증
#
# 시나리오 흐름: S1 → S2 → S4 → S8 → S9 → S10 → S5
#   (위험도 낮은 순서, S5(8G fill/qd=8)는 마지막)
# 모드당: ~36분
# 4모드: ~2.4시간
# =============================================================

WHICH=${1:-all}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"

FILL_NORMAL="6G"
FILL_S5="5G"

echo "=== $(date) === fio_write3 v9 [$WHICH] meen/12G" > "${LOG}"

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

# 전체 파일 대상 random write
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

# 제한된 영역(offset~offset+size) 대상 random write — S9 Sliding Hotspot용
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

    if [ $ret -eq 124 ]; then
        echo "  ⚠ ${name} timeout (${timeout_sec}s) [window=${offset}+${size}]"
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
# SCENARIO 1: Strong Hotspot (유지) ~8분
#   RL이 Greedy/CB/CAT를 모두 압도한 핵심 showcase
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
# SCENARIO 2: Hot/Cold Oscillation (유지) ~4분
#   RL이 CAT보다 wear에서 약간 우위
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
# SCENARIO 4: Gradient Heating (유지) ~4분
#   점진적 적응 trajectory를 보여주는 기본 baseline
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
# SCENARIO 5: Mild Pressure (유지) ~3분 + sleeps
#   8G fill, qd=8 (저 QD edge case)
# ===================================================================
scenario_5() {
    echo "[S5.0] Fill ${FILL_S5} (~67%)"
    do_fill ${FILL_S5} || return 1
    log_phase 0
    sleep 15

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

# ===================================================================
# SCENARIO 8: Bursty Hot Pulses (NEW) ~5분
#
#   [목적]
#     S3 (hot ratio) 와 S4 (hot ratio trend) 를 직접 자극.
#     uniform 바다 위에 zipf:2.5 급격한 burst.
#     정적 정책(CB/CAT)은 한 가지 α/δ에 baked-in되어 양쪽에 동시 최적 X.
#     RL은 trend(S4)를 감지해 α를 능동적으로 흔들어야 함.
#
#   [예상 거동]
#     - phase 1,3,5 (uniform): hot ratio 낮음 → α 낮춰 greedy 쪽으로
#     - phase 2,4 (zipf:2.5): hot ratio 급상승 → α 올려 hot 회피
#     - 정적 CAT는 phase 2,4에서 적절, phase 1,3,5에서 과잉
# ===================================================================
scenario_8() {
    echo "[S8.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S8.1] uniform 4k 60s (baseline cold)"
    rand_write 4k 60 uniform 1 32 s8p1 || return 1
    log_phase 1
    sleep 2

    echo "[S8.2] zipf:2.5 4k 60s (sharp hot burst)"
    rand_write 4k 60 zipf:2.5 1 32 s8p2 || return 1
    log_phase 2
    sleep 2

    echo "[S8.3] uniform 4k 60s (cool down)"
    rand_write 4k 60 uniform 1 32 s8p3 || return 1
    log_phase 3
    sleep 2

    echo "[S8.4] zipf:2.5 4k 60s (another burst)"
    rand_write 4k 60 zipf:2.5 1 32 s8p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 9: Sliding Hotspot (NEW) ~6분
#
#   [목적]
#     Age weighting 의 실질 가치 검증 + 공간적 drift.
#     hot 영역이 파일 내 LBA 공간을 따라 이동.
#     과거 hot data는 시간이 지나면서 cold가 되고 cold valid page로 남음.
#     CB/CAT의 고정된 age 가중치는 이 비정상 환경을 따라가지 못함.
#
#   [예상 거동]
#     - 각 phase: 2G window 안에 zipf:1.8 hot region 집중
#     - phase 전환 시 과거 hot line들이 cold valid로 잔류
#       → wear는 그 line들에 누적되어있는 상태
#     - RL은 last_modified_time 기반 age 가중치 + erase_cnt 정보로
#       이전 hot line을 적절히 회피/선택해야 함
#     - 정적 CAT는 erase_cnt만 보고 selection → drift 따라가지 못함
# ===================================================================
scenario_9() {
    echo "[S9.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S9.1] zipf:1.8 window 0G+2G 90s"
    rand_write_window 4k 90 zipf:1.8 1 32 0 2G s9p1 || return 1
    log_phase 1
    sleep 2

    echo "[S9.2] zipf:1.8 window 2G+2G 90s"
    rand_write_window 4k 90 zipf:1.8 1 32 2G 2G s9p2 || return 1
    log_phase 2
    sleep 2

    echo "[S9.3] zipf:1.8 window 4G+2G 90s"
    rand_write_window 4k 90 zipf:1.8 1 32 4G 2G s9p3 || return 1
    log_phase 3
    sleep 2

    echo "[S9.4] zipf:1.8 window 6G+2G 90s"
    rand_write_window 4k 90 zipf:1.8 1 32 6G 2G s9p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 10: Decaying Locality (NEW) ~4분
#
#   [목적]
#     S4 (Gradient Heating) 의 정확한 역방향.
#     S4가 α를 "올리는" 능력만 검증한다면, S10은 α를 "내리는" 능력 검증.
#     정적 CAT는 이 비대칭에 약함 — 한 번 hot으로 적응되면 cold로 빨리 못 돌아옴.
#     RL은 trend(S4) negative direction을 감지해 α/δ를 의도적으로 낮춰야 함.
#
#   [예상 거동]
#     - phase 1: zipf:2.0 → 매우 hot, α 높음이 최적
#     - phase 4: uniform → cold, α=0.5 (낮음)이 최적 (greedy 쪽)
#     - 중간 phase: 자연스러운 transition
#     - RL의 Q-table이 양방향 비대칭을 학습했는지 결정적 평가
# ===================================================================
scenario_10() {
    echo "[S10.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S10.1] zipf:2.0 4k 60s (very hot)"
    rand_write 4k 60 zipf:2.0 1 32 s10p1 || return 1
    log_phase 1
    sleep 2

    echo "[S10.2] zipf:1.5 4k 60s (cooling)"
    rand_write 4k 60 zipf:1.5 1 32 s10p2 || return 1
    log_phase 2
    sleep 2

    echo "[S10.3] zipf:0.8 4k 60s (warm)"
    rand_write 4k 60 zipf:0.8 1 32 s10p3 || return 1
    log_phase 3
    sleep 2

    echo "[S10.4] uniform 4k 60s (cold)"
    rand_write 4k 60 uniform 1 32 s10p4 || return 1
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
    2)  run_one 2  "Hot/Cold Oscillation"            scenario_2 ;;
    4)  run_one 4  "Gradient Heating cold->very hot" scenario_4 ;;
    5)  run_one 5  "Mild Pressure 8G fill, qd=8"     scenario_5 ;;
    8)  run_one 8  "Bursty Hot Pulses"               scenario_8 ;;
    9)  run_one 9  "Sliding Hotspot"                 scenario_9 ;;
    10) run_one 10 "Decaying Locality (reverse)"     scenario_10 ;;
    all)
        # 순서: 부담 낮은 → 신규 검증 → S5 (8G/qd=8) 마지막
        run_one 1  "Strong Hotspot zipf:2.0"        scenario_1
        run_one 2  "Hot/Cold Oscillation"            scenario_2
        run_one 4  "Gradient Heating cold->very hot" scenario_4
        run_one 8  "Bursty Hot Pulses"               scenario_8
        run_one 9  "Sliding Hotspot"                 scenario_9
        run_one 10 "Decaying Locality (reverse)"     scenario_10
        run_one 5  "Mild Pressure 8G fill, qd=8"     scenario_5
        ;;
    *)
        echo "Usage: $0 [1|2|4|5|8|9|10|all]"
        echo "  유지: 1, 2, 4, 5"
        echo "  신규: 8 (Bursty), 9 (Sliding), 10 (Decay)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write3 v9 done [$WHICH] - elapsed: ${MIN}m ${SEC}s ==="
echo "    성공: ${SUCCESS}, 실패: ${FAILED}"
echo ""
echo "=== Log content ==="
cat "${LOG}"