#!/bin/bash
# =============================================================
# fio_write8.sh v1 - meen/12G CONTINUOUS CYCLING MIX
#
# 가설:
#   v6에서 7개 시나리오 각각 RL CoV 단독 1위였지만, 각 시나리오는
#   fill 직후 정적 단일 패턴이라 RL의 상태 조건부 적응 능력을
#   충분히 자극하지 못함. 7개 패턴을 짧은 주기로 cycle하면
#   RL Q-table이 다양한 상태에 반복 노출되어 학습 우위가
#   누적되고, 장기적으로 WAF/CoV/throughput 모든 지표에서
#   정적 정책을 추월할 가능성이 있음.
#
# v6 대비 변경:
#   1) scenario(4 phase 묶음) → atomic pattern(60s 단일 워크로드)
#   2) 사이클 사이에 stabilize/fstrim 없음 (GC 상태 연속성)
#   3) 초기 fill 9G 한 번만, 이후 cycling 동안 re-fill 안 함
#   4) CYCLES만큼 7개 패턴 고정 순서 반복
#
# 7개 atomic pattern (v6 7시나리오에서 추출):
#   P1 HOT_strong   zipf:2.0 whole          ← S1   (강 단일 핫스팟)
#   P2 COLD         uniform whole           ← S2   (지역성 없음)
#   P3 BIMODAL      dual zipf:1.8 2 windows ← S11  (이중 핫스팟)
#   P4 CLIFF        zipf:2.5 narrow 1G      ← S12  (극단 좁은 핫스팟)
#   P5 RESIZE_wide  zipf:1.5 5G window      ← S13  (중간 폭 작업셋)
#   P6 MIXED        A=zipf:2.0 B=uniform    ← S15  (핫+콜드 공존)
#   P7 DECAY        zipf:0.8 whole          ← S10  (약 지역성)
#
# 총 시간: 7 pattern × CYCLES × PATTERN_RT
#   기본(CYCLES=4, RT=60): 28 min/policy → 4 policy ~2h
#   짧게(CYCLES=3, RT=45): 16 min/policy → 4 policy ~1.1h
#   길게(CYCLES=6, RT=60): 42 min/policy → 4 policy ~2.8h
#
# 사용법:
#   ./fio_write8.sh                       # 기본 (4 cycles × 60s)
#   CYCLES=6 ./fio_write8.sh              # 더 긴 학습
#   CYCLES=3 PATTERN_RT=45 ./fio_write8.sh
# =============================================================

CYCLES=${CYCLES:-4}
PATTERN_RT=${PATTERN_RT:-60}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
LOG="${LOG:-./gc_log.txt}"
FILL_SIZE="6G"

START_TIME=$(date +%s)
echo "=== $(date) === fio_write8 v1 cycles=${CYCLES} rt=${PATTERN_RT}s meen/12G" > "${LOG}"

# ── helpers ───────────────────────────────────────────────────
log_phase() {
    local n=$1
    timeout 30 nvme flush "${DEV}" -n 1 2>/dev/null
    sleep 1
    echo "--- phase${n} ---" >> "${LOG}"
    dmesg | grep "NVMeVirt: \[FLUSH\]\|NVMeVirt: \[Wear\]" | tail -2 >> "${LOG}"
}

pattern_header() {
    local cy=$1 idx=$2 name=$3
    echo "" >> "${LOG}"
    echo "########## c${cy}_p${idx}: ${name} ##########" >> "${LOG}"
    echo "  [c${cy}_p${idx}] ${name} (${PATTERN_RT}s)"
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
        echo "  ⚠ Fill ${size} attempt $attempt failed"
        attempt=$((attempt + 1))
        sleep 30
    done
    return 1
}

# ── 7 atomic patterns ─────────────────────────────────────────
# 모두 PATTERN_RT 초간 단일 워크로드. 성공 시 0 리턴.

p_hot_strong() {
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 \
        --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:2.0 \
        --time_based --runtime=${PATTERN_RT} --name=p_hot >/dev/null 2>&1
}

p_cold() {
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 \
        --norandommap=1 --randrepeat=0 \
        --time_based --runtime=${PATTERN_RT} --name=p_cold >/dev/null 2>&1
}

p_bimodal() {
    local pidA pidB rA rB
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 \
        --norandommap=1 --randrepeat=0 \
        --offset=0 --size=2G \
        --random_distribution=zipf:1.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_bi_A >/dev/null 2>&1 &
    pidA=$!
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 \
        --norandommap=1 --randrepeat=0 \
        --offset=4G --size=2G \
        --random_distribution=zipf:1.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_bi_B >/dev/null 2>&1 &
    pidB=$!
    wait $pidA; rA=$?
    wait $pidB; rB=$?
    [ $rA -eq 0 ] && [ $rB -eq 0 ]
}

p_cliff() {
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 \
        --norandommap=1 --randrepeat=0 \
        --offset=0 --size=1G \
        --random_distribution=zipf:2.5 \
        --time_based --runtime=${PATTERN_RT} --name=p_cliff >/dev/null 2>&1
}

p_resize_wide() {
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 \
        --norandommap=1 --randrepeat=0 \
        --offset=0 --size=5G \
        --random_distribution=zipf:1.5 \
        --time_based --runtime=${PATTERN_RT} --name=p_resize >/dev/null 2>&1
}

p_mixed() {
    local pidA pidB rA rB
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 \
        --norandommap=1 --randrepeat=0 \
        --offset=0 --size=2G \
        --random_distribution=zipf:2.0 \
        --time_based --runtime=${PATTERN_RT} --name=p_mix_A >/dev/null 2>&1 &
    pidA=$!
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 \
        --norandommap=1 --randrepeat=0 \
        --offset=4G --size=2G \
        --time_based --runtime=${PATTERN_RT} --name=p_mix_B >/dev/null 2>&1 &
    pidB=$!
    wait $pidA; rA=$?
    wait $pidB; rB=$?
    [ $rA -eq 0 ] && [ $rB -eq 0 ]
}

p_decay() {
    timeout $((PATTERN_RT + 30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 \
        --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:0.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_decay >/dev/null 2>&1
}

# ── dispatch table ────────────────────────────────────────────
PATTERN_NAMES=("HOT_strong" "COLD" "BIMODAL" "CLIFF" "RESIZE_wide" "MIXED" "DECAY")
PATTERN_FNS=("p_hot_strong" "p_cold" "p_bimodal" "p_cliff" "p_resize_wide" "p_mixed" "p_decay")
NUM_PATTERNS=${#PATTERN_FNS[@]}

# ── main ──────────────────────────────────────────────────────
echo "[init] fill ${FILL_SIZE}"
if ! do_fill ${FILL_SIZE}; then
    echo "❌ Initial fill failed; aborting"
    echo "FATAL: fill failed" >> "${LOG}"
    exit 1
fi

phase=0
log_phase ${phase}   # phase0 = post-fill (GC=0 expected)

CONSEC_FAIL=0
TOTAL_FAIL=0

for ((c=1; c<=CYCLES; c++)); do
    echo ""
    echo "==== Cycle ${c}/${CYCLES} ===="
    for ((i=0; i<NUM_PATTERNS; i++)); do
        name=${PATTERN_NAMES[$i]}
        fn=${PATTERN_FNS[$i]}
        phase=$((phase + 1))
        pattern_header "${c}" "$((i+1))" "${name}"

        if ! "${fn}"; then
            echo "  ⚠ ${name} failed (consec=${CONSEC_FAIL})"
            echo "  [FAILED] pattern returned non-zero" >> "${LOG}"
            CONSEC_FAIL=$((CONSEC_FAIL + 1))
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            if [ ${CONSEC_FAIL} -ge 3 ]; then
                echo "❌ 3 consecutive failures, aborting"
                echo "FATAL: 3 consec fails" >> "${LOG}"
                break 2
            fi
            log_phase ${phase}   # snapshot 찍어두고 다음으로
            sleep 2
            continue
        fi

        CONSEC_FAIL=0
        log_phase ${phase}
        sleep 1
    done
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MIN=$((ELAPSED / 60))
SEC=$((ELAPSED % 60))

echo ""
echo "=== fio_write8 v1 done - ${MIN}m ${SEC}s (failed: ${TOTAL_FAIL}, phases: ${phase}) ==="
echo ""
echo "=== Log content ==="
cat "${LOG}"