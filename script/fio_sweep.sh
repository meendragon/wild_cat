#!/bin/bash
# =============================================================
# fio_sweep.sh - 4-policy auto sweep + per-cycle trend CSV
#                (run_all2.sh 컨벤션 / start_virt·end_virt 위임)
#
# 기존 fio_write9.sh의 구조적 문제 3가지를 해결한 재작성본:
#
#   1) 모드 전환 자동화 (위임)
#      gc_mode 0~3을 순회하며, 모듈 로드/언로드는 run_all2.sh와
#      동일하게 start_virt.sh <mode> / end_virt.sh 에 위임한다.
#      (직접 insmod/rmmod 하지 않음 → 환경 의존·위험 코드 제거)
#
#   2) 추세(trend) 데이터 보존
#      기존: log_phase가 'tail -2'로 *누적* FLUSH/Wear만 긁음. erase/WAF는
#            모듈 로드 후 단조 증가하는 누적치라 사이클 간 격차가 안 보임.
#      본 버전: 매 사이클 누적치를 읽어 직전 사이클과의 *증분(delta)*을
#            계산하고, 구간 WAF(=1+Δcopied/Δhost)와 WearGap per_gc를
#            CSV로 남긴다. "CAT은 단조 악화, RL은 안정"을 직접 플롯 가능.
#
#   3) 적정 실험 시간 (sweep 우선)
#      기존: PATTERN_RT=60s × 7 × 40cyc = 정책당 ~4h50m.
#      본 버전: CYCLES=12 × RT=40s → 정책당 ~1h, 4정책 합 ~4h.
#            CYCLES(추세 포인트)와 RT(steady-state) 두 축을 균형 있게
#            줄여, 한쪽만 극단으로 깎을 때의 정보 손실을 피한다.
#            RT 하한 40s는 큰 워킹셋 패턴(RESIZE/COLD)이 GC를 충분히
#            유발하는 안전선. 목적은 'v8 재현'이 아니라 정책 sweep.
#
# 사용:
#   ./fio_sweep.sh                       # gc_mode 0 1 2 3 × 12cyc (~4h)
#   CYCLES=8 ./fio_sweep.sh              # 더 빠르게 (정책당 ~40m)
#   MODES_TO_RUN="2 3" ./fio_sweep.sh    # cat, rl 만
#   SKIP_RELOAD=1 MODES_TO_RUN="2" ./fio_sweep.sh   # 현재 로드된 모드만
# =============================================================

set -u

# ── 설정 (run_all2.sh 컨벤션에 맞춤) ──────────────────────────
MODES=("greedy" "cb" "cat" "rl")          # index = gc_mode 번호
MODES_TO_RUN="${MODES_TO_RUN:-0 1 2 3}"   # 돌릴 gc_mode (run_all2와 동일)
CYCLES=${CYCLES:-12}                       # 정책당 사이클 (~1h, 추세 포인트 12개)
PATTERN_RT=${PATTERN_RT:-40}               # 패턴당 런타임 (steady-state 안전 하한)
SCEN="${SCEN:-all}"                        # 시나리오 (예약: 향후 패턴 서브셋용)

DEV="/dev/nvme1n1"
MOUNT_POINT="/home/meen/wild_cat/mnt"
FILE="${MOUNT_POINT}/workload.0.0"
FILL_SIZE="6G"
LOGS_DIR="./logs"                          # run_all2와 동일 디렉터리
OUTDIR="${OUTDIR:-./sweep_results}"        # per-cycle CSV 출력

# 모듈 제어: run_all2처럼 start/end_virt.sh에 위임 (직접 insmod 안 함)
START_VIRT="${START_VIRT:-./start_virt.sh}"   # 사용법: start_virt.sh <gc_mode>
END_VIRT="${END_VIRT:-./end_virt.sh}"         # rmmod + unmount 담당
RELOAD_TIMEOUT="${RELOAD_TIMEOUT:-60}"        # end_virt hang 방어 (v3와 동일)
SKIP_RELOAD="${SKIP_RELOAD:-0}"               # 1이면 현재 로드된 모드만 측정

START_TIME=$(date +%s)
mkdir -p "${OUTDIR}" "${LOGS_DIR}"

# ── 유틸 ──────────────────────────────────────────────────────
format_eta() {
    local sec=$1 h m
    h=$((sec / 3600)); m=$(( (sec % 3600) / 60 ))
    [ $h -gt 0 ] && echo "${h}h ${m}m" || echo "${m}m"
}

# dmesg 한 줄에서 key=value 추출 (정수/소수 공통)
get_field() { echo "$1" | grep -oP "$2=\K[0-9.]+" | head -1; }

# 가장 최근 FLUSH/Wear/WearGap 라인 1개씩
latest_flush()   { sudo dmesg | grep "NVMeVirt: \[FLUSH\]"   | tail -1; }
latest_wear()    { sudo dmesg | grep "NVMeVirt: \[Wear\]"    | tail -1; }
latest_weargap() { sudo dmesg | grep "NVMeVirt: \[WearGap\]" | tail -1; }

# ── 모듈 로드/언로드 (start_virt.sh / end_virt.sh 위임) ───────
#
# run_all2.sh와 동일 철학: 직접 insmod/rmmod 하지 않고 외부 스크립트에
# 맡긴다. 로드 후 dmesg로 gc_mode 일치 + gc=0(fresh) 검증.
load_mode() {
    local mode=$1

    if [ "${SKIP_RELOAD}" = "1" ]; then
        echo "  [load] SKIP_RELOAD=1 → 현재 로드된 모드 그대로 사용"
        return 0
    fi

    if [ ! -x "${START_VIRT}" ]; then
        echo "  ❌ ${START_VIRT} 실행 불가 (경로 확인 또는 chmod +x)"
        return 1
    fi

    echo "  [load] ${START_VIRT} ${mode}"
    "${START_VIRT}" "${mode}"
    sleep 2

    # 디바이스 등장 대기
    local w=0
    while [ ! -b "${DEV}" ] && [ $w -lt 15 ]; do sleep 1; w=$((w+1)); done
    if [ ! -b "${DEV}" ]; then
        echo "  ❌ ${DEV} 미등장"
        return 1
    fi

    # 검증: gc_mode 일치 + gc=0
    sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1
    sleep 2
    local fl actual_mode gc_count
    fl=$(latest_flush)
    if [ -z "$fl" ]; then
        echo "  ❌ dmesg에 FLUSH 없음 (모듈 비정상)"
        return 1
    fi
    actual_mode=$(echo "$fl" | grep -oP 'gc_mode=\K[0-9]')
    gc_count=$(echo "$fl" | grep -oP 'gc=\K[0-9]+')
    if [ "$actual_mode" != "$mode" ]; then
        echo "  ❌ gc_mode mismatch: expected=${mode} actual=${actual_mode}"
        return 1
    fi
    if [ "$gc_count" != "0" ]; then
        echo "  ❌ gc=${gc_count} (이전 모드 잔재, fresh 아님)"
        return 1
    fi
    echo "  ✅ 검증 통과: gc_mode=${actual_mode}, gc=0"
    return 0
}

unload_mode() {
    if [ "${SKIP_RELOAD}" = "1" ]; then
        return 0   # SKIP 모드에선 사용자가 직접 관리
    fi
    if [ ! -x "${END_VIRT}" ]; then
        echo "  ⚠ ${END_VIRT} 실행 불가 — 모듈 언로드 생략"
        return 0
    fi
    echo "  [unload] ${END_VIRT} (${RELOAD_TIMEOUT}s timeout)"
    timeout "${RELOAD_TIMEOUT}" "${END_VIRT}"
    [ $? -eq 124 ] && echo "  ⚠ end_virt timeout (rmmod hang 추정)"
    sleep 3
    if lsmod | grep -q nvmev; then
        echo "  ⚠ 모듈 여전히 로드됨 (다음 load 전 정리 필요)"
        return 1
    fi
    return 0
}

do_fill() {
    local size=$1 attempt=1
    while [ $attempt -le 2 ]; do
        if timeout 300 fio --filename="${FILE}" --direct=1 --ioengine=libaio \
            --rw=write --bs=128k --size=${size} --numjobs=1 \
            --name=fill >/dev/null 2>&1
        then return 0; fi
        echo "  ⚠ fill ${size} attempt ${attempt} 실패"
        attempt=$((attempt+1)); sleep 30
    done
    return 1
}

# ── 7 패턴 (v8과 동일, 비교 가능성 유지) ──────────────────────
p_hot_strong() {
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:2.0 \
        --time_based --runtime=${PATTERN_RT} --name=p_hot >/dev/null 2>&1
}
p_cold() {
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --time_based --runtime=${PATTERN_RT} --name=p_cold >/dev/null 2>&1
}
p_bimodal() {
    local pidA pidB rA rB
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=2G --random_distribution=zipf:1.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_bi_A >/dev/null 2>&1 &
    pidA=$!
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 --norandommap=1 --randrepeat=0 \
        --offset=4G --size=2G --random_distribution=zipf:1.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_bi_B >/dev/null 2>&1 &
    pidB=$!
    wait $pidA; rA=$?; wait $pidB; rB=$?
    [ $rA -eq 0 ] && [ $rB -eq 0 ]
}
p_cliff() {
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=1G --random_distribution=zipf:2.5 \
        --time_based --runtime=${PATTERN_RT} --name=p_cliff >/dev/null 2>&1
}
p_resize_wide() {
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=5G --random_distribution=zipf:1.5 \
        --time_based --runtime=${PATTERN_RT} --name=p_resize >/dev/null 2>&1
}
p_mixed() {
    local pidA pidB rA rB
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=2G --random_distribution=zipf:2.0 \
        --time_based --runtime=${PATTERN_RT} --name=p_mix_A >/dev/null 2>&1 &
    pidA=$!
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=16 --norandommap=1 --randrepeat=0 \
        --offset=4G --size=2G \
        --time_based --runtime=${PATTERN_RT} --name=p_mix_B >/dev/null 2>&1 &
    pidB=$!
    wait $pidA; rA=$?; wait $pidB; rB=$?
    [ $rA -eq 0 ] && [ $rB -eq 0 ]
}
p_decay() {
    timeout $((PATTERN_RT+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:0.8 \
        --time_based --runtime=${PATTERN_RT} --name=p_decay >/dev/null 2>&1
}

PATTERN_FNS=("p_hot_strong" "p_cold" "p_bimodal" "p_cliff" "p_resize_wide" "p_mixed" "p_decay")
NUM_PATTERNS=${#PATTERN_FNS[@]}

# 한 사이클 = 7패턴 연속 실행. flush는 사이클 끝 1회만
# (패턴마다 flush하면 오버헤드 + 누적 증분 해석이 흐려짐).
run_one_cycle() {
    local i fn
    for ((i=0; i<NUM_PATTERNS; i++)); do
        fn=${PATTERN_FNS[$i]}
        "${fn}" || return 1
    done
    return 0
}

# ── 모드 1개 실행: load → fill → CYCLES회 → 증분 CSV → unload ──
run_mode() {
    local mode=$1 name csv raw
    name=${MODES[$mode]}
    csv="${OUTDIR}/gc_${mode}_${name}.csv"
    raw="${LOGS_DIR}/gc_log_${mode}_${name}.txt"

    echo ""
    echo "############################################"
    echo "# gc_mode=${mode} (${name}) 시작 - $(date)"
    echo "############################################"

    load_mode "${mode}" || { echo "  ❌ load 실패, 모드 건너뜀"; return 1; }

    echo "  [fill] ${FILL_SIZE}"
    do_fill "${FILL_SIZE}" || { echo "  ❌ fill 실패"; unload_mode; return 1; }

    echo "cycle,d_gc,d_copied,d_host,seg_waf,cum_waf,ec_range,d_range,cov,weargap_per_gc" > "${csv}"
    : > "${raw}"

    # 기준선(fill 직후) 스냅샷
    sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1; sleep 1
    local fl wr
    fl=$(latest_flush); wr=$(latest_wear)
    local prev_gc prev_cp prev_host prev_rng
    prev_gc=$(get_field "$fl" gc);      prev_gc=${prev_gc:-0}
    prev_cp=$(get_field "$fl" copied);  prev_cp=${prev_cp:-0}
    prev_host=$(get_field "$fl" host);  prev_host=${prev_host:-0}
    prev_rng=$(get_field "$wr" range);  prev_rng=${prev_rng:-0}

    local c consec_fail=0
    for ((c=1; c<=CYCLES; c++)); do
        local cbeg; cbeg=$(date +%s)

        if ! run_one_cycle; then
            consec_fail=$((consec_fail+1))
            echo "  ⚠ cycle ${c} 패턴 실패 (consec=${consec_fail})"
            [ ${consec_fail} -ge 3 ] && { echo "  ❌ 3연속 실패, 모드 중단"; break; }
            continue
        fi
        consec_fail=0

        sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1; sleep 1
        fl=$(latest_flush); wr=$(latest_wear); local wg; wg=$(latest_weargap)
        { echo "=== cycle ${c} ==="; echo "$fl"; echo "$wr"; echo "$wg"; } >> "${raw}"

        local cur_gc cur_cp cur_host cur_rng cum_waf cov pergc
        cur_gc=$(get_field "$fl" gc);      cur_gc=${cur_gc:-$prev_gc}
        cur_cp=$(get_field "$fl" copied);  cur_cp=${cur_cp:-$prev_cp}
        cur_host=$(get_field "$fl" host);  cur_host=${cur_host:-$prev_host}
        cur_rng=$(get_field "$wr" range);  cur_rng=${cur_rng:-$prev_rng}
        cum_waf=$(get_field "$fl" WAF);    cum_waf=${cum_waf:-0}
        cov=$(get_field "$wr" CoV);        cov=${cov:-0}
        pergc=$(get_field "$wg" per_gc);   pergc=${pergc:-0}

        local d_gc d_cp d_host d_rng seg_waf
        d_gc=$((cur_gc - prev_gc))
        d_cp=$((cur_cp - prev_cp))
        d_host=$((cur_host - prev_host))
        d_rng=$((cur_rng - prev_rng))

        if [ "${d_host}" -gt 0 ]; then
            seg_waf=$(awk "BEGIN{printf \"%.4f\", 1 + ${d_cp}/${d_host}}")
        else
            seg_waf="1.0000"
        fi

        echo "${c},${d_gc},${d_cp},${d_host},${seg_waf},${cum_waf},${cur_rng},${d_rng},${cov},${pergc}" >> "${csv}"
        prev_gc=$cur_gc; prev_cp=$cur_cp; prev_host=$cur_host; prev_rng=$cur_rng

        local cend eta
        cend=$(date +%s)
        if [ $c -lt $CYCLES ]; then
            eta=$(( (CYCLES - c) * (cend - cbeg) ))
            printf "  cycle %2d/%d  seg_waf=%s range=%s (Δ%+d)  ETA(mode) %s\n" \
                   "$c" "$CYCLES" "$seg_waf" "$cur_rng" "$d_rng" "$(format_eta $eta)"
        else
            printf "  cycle %2d/%d  seg_waf=%s range=%s (Δ%+d)  [done]\n" \
                   "$c" "$CYCLES" "$seg_waf" "$cur_rng" "$d_rng"
        fi
    done

    unload_mode
    echo "  ✓ ${name} 완료 → ${csv}"
    return 0
}

# ── SIGINT: 부분 결과 보존 ────────────────────────────────────
trap 'echo ""; echo "⚠ INTERRUPTED at $(date) — 부분 CSV는 ${OUTDIR}에 보존됨"; exit 130' INT TERM

# ── 시간 추정 ─────────────────────────────────────────────────
NM=$(echo ${MODES_TO_RUN} | wc -w)
EST_PER_MODE=$(( CYCLES * NUM_PATTERNS * (PATTERN_RT + 2) + 120 ))
EST_TOTAL=$(( EST_PER_MODE * NM ))
echo "============================================"
echo " fio_sweep 시작: $(date)"
echo " 모드: ${MODES_TO_RUN}   cycles=${CYCLES}  rt=${PATTERN_RT}s"
echo " 예상: 모드당 ~$(format_eta ${EST_PER_MODE}), 총 ${NM}모드 ~$(format_eta ${EST_TOTAL})"
echo " 결과: ${OUTDIR}/gc_<n>_<name>.csv"
echo "============================================"

# ── 메인: 모드 순회 ───────────────────────────────────────────
SKIPPED=""
for i in ${MODES_TO_RUN}; do
    if [ -z "${MODES[$i]:-}" ]; then
        echo "❌ 잘못된 mode: $i (건너뜀)"; continue
    fi
    run_mode "$i" || SKIPPED="${SKIPPED} ${MODES[$i]}"
    sleep 3
done

# ── 요약: 모드별 마지막 5사이클 평균 비교 ─────────────────────
echo ""
echo "=== 요약 (마지막 5사이클 평균) ==="
printf "%-8s %10s %10s %10s %12s\n" "mode" "seg_waf" "ec_range" "cov" "wg_per_gc"
for i in ${MODES_TO_RUN}; do
    [ -z "${MODES[$i]:-}" ] && continue
    csv="${OUTDIR}/gc_${i}_${MODES[$i]}.csv"
    [ -f "${csv}" ] || continue
    awk -F, 'NR>1{n++; sw[n]=$5; rg[n]=$7; cv[n]=$9; wg[n]=$10}
        END{
            s=(n>5)?n-4:1; cw=0; cr=0; cc=0; cg=0; k=0;
            for(idx=s;idx<=n;idx++){cw+=sw[idx]; cr+=rg[idx]; cc+=cv[idx]; cg+=wg[idx]; k++}
            if(k>0) printf "%10.4f %10.1f %10.4f %12.4f\n", cw/k, cr/k, cc/k, cg/k;
        }' "${csv}" | sed "s/^/$(printf '%-8s' ${MODES[$i]}) /"
done

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "============================================"
echo " 🎉 전체 완료: $(format_eta ${TOTAL_ELAPSED})"
[ -n "${SKIPPED}" ] && echo " ⚠ Skip된 모드:${SKIPPED}"
echo " CSV: ${OUTDIR}/   raw: ${LOGS_DIR}/"
echo " 플롯: cycle별 seg_waf / ec_range 를 모드끼리 겹쳐 그리면"
echo "       'CAT 단조 악화 vs RL 안정'이 보이는지 확인 가능."
echo "============================================"