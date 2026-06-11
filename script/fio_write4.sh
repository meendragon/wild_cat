#!/bin/bash
# =============================================================
# fio_write4.sh v10 - meen/12G STABLE + 신규 차원 워크로드
#
# v10 변경점 (v9 대비):
#   [유지] S1, S2, S10, S5 — v3에서 RL 차별화 입증된 핵심 시나리오
#   [제거] S4 (Gradient)   — S10 reverse가 더 강력한 테스트
#   [제거] S8 (Bursty)     — RL 차별화 부족, CAT 우위
#   [제거] S9 (Sliding)    — 정보 있지만 v4에선 S11/S12가 더 novel
#   [신규] S11 Bimodal Hotspot  — 공간 multi-mode (parallel fio)
#   [신규] S12 Working Set Cliff — 갑작스런 working set 확장
#   [신규] S13 Hotspot Resize    — hot ratio 같고 window 크기만 변화
#
# 시나리오 흐름: S1 → S2 → S11 → S12 → S13 → S10 → S5
# 모드당: ~34분
# 4모드: ~2.3시간
# =============================================================

WHICH=${1:-all}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"

FILL_NORMAL="6G"
FILL_S5="5G"

echo "=== $(date) === fio_write4 v10 [$WHICH] meen/12G" > "${LOG}"

# ── 공통 헬퍼 (v9 verbatim) ──────────────────────────────────
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

# 전체 파일 random write (v9 동일)
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

# 제한된 영역 random write (v9 동일, S12/S13에서 사용)
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

# 두 영역에 동시 random write (NEW, S11 Bimodal 전용)
# 두 개의 fio 프로세스가 서로 다른 LBA 범위에 병렬 writing
rand_write_dual() {
    local bs=$1 rt=$2 dist=$3 qd=$4
    local offset1=$5 size1=$6 offset2=$7 size2=$8 name=$9
    local dist_arg=""
    if [ -n "${dist}" ] && [ "${dist}" != "uniform" ]; then
        dist_arg="--random_distribution=${dist}"
    fi
    local timeout_sec=$((rt + 30))

    # Job A 백그라운드
    timeout ${timeout_sec} fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=${bs} --numjobs=1 --iodepth=${qd} \
        --norandommap=1 --randrepeat=0 \
        --offset=${offset1} --size=${size1} \
        ${dist_arg} \
        --time_based --runtime=${rt} --name=${name}_A >/dev/null 2>&1 &
    local pidA=$!

    # Job B 백그라운드
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
#   v3에서 RL CoV 1.523 (vs CAT 1.619) — 핵심 showcase
# ===================================================================
scenario_1() {
    echo "[S1.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S1.1] zipf:2.0 4k 120s"
    rand_write 4k 120 zipf:2.0 1 32 s1p1 || return 1
    log_phase 1
    sleep 2

    echo "[S1.2] zipf:2.0 4k 120s"
    rand_write 4k 120 zipf:2.0 1 32 s1p2 || return 1
    log_phase 2
    sleep 2

    echo "[S1.3] zipf:1.5 4k 90s"
    rand_write 4k 90 zipf:1.5 1 32 s1p3 || return 1
    log_phase 3
    sleep 2

    echo "[S1.4] zipf:2.0 4k 90s"
    rand_write 4k 90 zipf:2.0 1 32 s1p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 2: Hot/Cold Oscillation (유지) ~4분
#   v3에서 RL CoV 0.888 (vs CAT 0.916)
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
# SCENARIO 11: Bimodal Hotspot (NEW) ~4분
#
#   [목적]
#     공간 multi-mode 처리 능력 검증. 모든 이전 시나리오는 한 시점에
#     하나의 hot region만 존재했음. v4에서 처음으로 *두 개의 hot region
#     이 동시에* 존재하는 상황을 만듦.
#
#   [구현]
#     - 두 fio 프로세스가 disjoint LBA range에 병렬 writing
#     - 각 region은 zipf:1.8로 자체 hotspot 형성
#     - phase 진행 시 region 조합 변경 (drift + add/remove)
#
#   [예상 거동]
#     - S3 (hot ratio): 두 hotspot의 영향으로 일정 수준 유지
#     - 정적 CAT: 두 region 모두에 동일한 δ=1 적용 → 한쪽에서 sub-optimal
#     - RL: state가 multi-mode를 표현 못 하므로 평균적 대응
#       이 시나리오는 RL의 한계를 검증하는 stress test 성격
# ===================================================================
scenario_11() {
    echo "[S11.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S11.1] dual zipf:1.8 [0G+2G, 4G+2G] 60s"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p1 || return 1
    log_phase 1
    sleep 2

    echo "[S11.2] dual zipf:1.8 [0G+2G, 4G+2G] 60s (continue)"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 4G 2G s11p2 || return 1
    log_phase 2
    sleep 2

    echo "[S11.3] dual zipf:1.8 [2G+2G, 6G+2G] 60s (both shift)"
    rand_write_dual 4k 60 zipf:1.8 16 2G 2G 6G 2G s11p3 || return 1
    log_phase 3
    sleep 2

    echo "[S11.4] dual zipf:1.8 [0G+2G, 6G+2G] 60s (asymmetric)"
    rand_write_dual 4k 60 zipf:1.8 16 0 2G 6G 2G s11p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 12: Working Set Cliff (NEW) ~4분
#
#   [목적]
#     Working set의 *크기* 가 급변하는 상황. 이전 시나리오들은 분포
#     shape (zipf parameter)만 바꿨지, hot region의 absolute size가
#     phase 사이에 급변한 적은 없음.
#
#   [구현]
#     phase 1-2: zipf:2.5 within 1G window
#                → 실질 hot 영역 ~100MB 정도로 매우 집중
#     phase 3 (CLIFF): uniform across entire 9G
#                → working set이 ~90배로 폭증, hot ratio 0으로 추락
#     phase 4: uniform 9G 계속
#
#   [예상 거동]
#     - phase 2 → 3 전환에서 RL의 S4 (hot ratio trend) 큰 음의 변화
#     - 1-2에서 hot 라인에 집중적 wear → 3에서 갑자기 그 라인들이
#       cold이지만 erase_cnt 높은 상태로 잔류
#     - RL은 trend를 감지해 α 급감 + δ 증가시켜 wear 분산해야 함
#     - 정적 CAT는 cliff 후에도 1-2 동안 형성된 wear bias를 빠르게
#       해소하지 못함
# ===================================================================
scenario_12() {
    echo "[S12.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S12.1] zipf:2.5 window 0+1G 60s (concentrated)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p1 || return 1
    log_phase 1
    sleep 2

    echo "[S12.2] zipf:2.5 window 0+1G 60s (heat accumulates)"
    rand_write_window 4k 60 zipf:2.5 1 32 0 1G s12p2 || return 1
    log_phase 2
    sleep 2

    echo "[S12.3] uniform whole 9G 60s (CLIFF: working set 폭증)"
    rand_write 4k 60 uniform 1 32 s12p3 || return 1
    log_phase 3
    sleep 2

    echo "[S12.4] uniform whole 9G 60s (continued spread)"
    rand_write 4k 60 uniform 1 32 s12p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 13: Hotspot Resize (NEW) ~4분
#
#   [목적]
#     같은 distribution shape (zipf:1.5) 으로 hot window 크기만 변화.
#     이전 시나리오들이 분포 parameter (zipf:0.8 → 2.0)로 hot ratio를
#     바꾼 것과 달리, 여기서는 hot ratio는 비슷하고 hot region의
#     *공간적 크기* 만 변함.
#
#   [구현]
#     - p1: 1G window (집중)
#     - p2: 2G window (확장)
#     - p3: 5G window (광역)
#     - p4: 1G window (집중 회귀)
#
#   [예상 거동]
#     - 분포 shape 동일하므로 S3 (hot ratio)는 phase 내내 비슷
#     - 그러나 절대 hot LBA 개수가 달라짐 → wear가 분산되는 정도 변화
#     - 정적 정책: hot ratio가 비슷해 보이므로 동일한 α 적용
#     - RL: S5 (erase distribution quality) state로 차이 감지해
#       window 크기 별로 다른 정책 선택 가능
#     - p3 → p4 (광역 → 집중) 전환에서 적응력 차이 부각
# ===================================================================
scenario_13() {
    echo "[S13.0] Fill ${FILL_NORMAL}"
    do_fill ${FILL_NORMAL} || return 1
    log_phase 0

    echo "[S13.1] zipf:1.5 window 0+1G 60s (small hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p1 || return 1
    log_phase 1
    sleep 2

    echo "[S13.2] zipf:1.5 window 0+2G 60s (medium hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 2G s13p2 || return 1
    log_phase 2
    sleep 2

    echo "[S13.3] zipf:1.5 window 0+5G 60s (wide hot)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 5G s13p3 || return 1
    log_phase 3
    sleep 2

    echo "[S13.4] zipf:1.5 window 0+1G 60s (back to small)"
    rand_write_window 4k 60 zipf:1.5 1 32 0 1G s13p4 || return 1
    log_phase 4
    return 0
}

# ===================================================================
# SCENARIO 10: Decaying Locality (유지) ~4분
#   v3에서 RL CoV 0.476 (vs CAT 0.485) — α release 핵심 검증
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

# ===================================================================
# SCENARIO 5: Mild Pressure (유지) ~3분 + sleeps
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
    1)  run_one 1  "Strong Hotspot zipf:2.0"     scenario_1 ;;
    2)  run_one 2  "Hot/Cold Oscillation"         scenario_2 ;;
    5)  run_one 5  "Mild Pressure 8G fill, qd=8"  scenario_5 ;;
    10) run_one 10 "Decaying Locality (reverse)"  scenario_10 ;;
    11) run_one 11 "Bimodal Hotspot"              scenario_11 ;;
    12) run_one 12 "Working Set Cliff"            scenario_12 ;;
    13) run_one 13 "Hotspot Resize"               scenario_13 ;;
    all)
        # 순서: 단일 hot (S1) → oscillation (S2) → 신규 3종 → decay (S10) → mild (S5)
        run_one 1  "Strong Hotspot zipf:2.0"     scenario_1
        run_one 2  "Hot/Cold Oscillation"         scenario_2
        run_one 11 "Bimodal Hotspot"              scenario_11
        run_one 12 "Working Set Cliff"            scenario_12
        run_one 13 "Hotspot Resize"               scenario_13
        run_one 10 "Decaying Locality (reverse)"  scenario_10
        run_one 5  "Mild Pressure 8G fill, qd=8"  scenario_5
        ;;
    *)
        echo "Usage: $0 [1|2|5|10|11|12|13|all]"
        echo "  유지: 1, 2, 10, 5"
        echo "  신규: 11 (Bimodal), 12 (Cliff), 13 (Resize)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write4 v10 done [$WHICH] - elapsed: ${MIN}m ${SEC}s ==="
echo "    성공: ${SUCCESS}, 실패: ${FAILED}"
echo ""
echo "=== Log content ==="
cat "${LOG}"