#!/bin/bash
# =============================================================
# fio_static.sh - 정적 단일 워크로드 × 정책 그리드 (6.2용)
#
# 목적:
#   "어느 정보(축)를 강조해야 유리한지가 워크로드에 따라 갈린다"를
#   보이기 위한 실험. fio_sweep.sh(6.3 적응 실험)와 달리, 여기서는
#   하나의 *순수* 워크로드를 한 정책에 끝까지 정적으로 인가하고
#   최종 WAF / CoV / ec_range "한 점"만 뽑는다.
#
#   결과 표(워크로드 × 정책)에서:
#     - 워크로드마다 WAF 최저 정책과 CoV 최저 정책이 서로 다르고
#     - 그 정체가 워크로드에 따라 바뀜 (우위 교차)
#   을 직접 확인한다.
#
# fio_sweep.sh와의 차이:
#   - 사이클/증분 없음. fill → 단일 패턴을 RUNTIME 동안 → flush → 1점 측정.
#   - 패턴은 "축 반영비가 갈리도록" 설계된 순수 분포들:
#       uniform   : 핫스팟 없음 → 마모 자연 분산. wear 항(δ) 이득 적고
#                   age/cost 항이 WAF를 좌우. (CB/Greedy 유리 가설)
#       hot_zipf  : 강한 핫스팟 → 특정 블록에 erase 집중. wear 항(δ)이
#                   CoV를 좌우. (CAT 유리 가설)
#       hot_narrow: 핫 영역이 더 좁음 → 쏠림 극대화.
#       skew_mid  : 중간 쏠림 → 교차 지점 관찰용.
#
# 사용:
#   ./fio_static.sh                              # 4워크로드 × gc_mode 0~3
#   MODES_TO_RUN="1 2" ./fio_static.sh           # cb, cat 만
#   WORKLOADS="uniform hot_zipf" ./fio_static.sh # 일부 워크로드만
#   RUNTIME=120 ./fio_static.sh                  # 패턴당 런타임 늘려 GC 더 유발
# =============================================================

set -u

# ── 설정 (fio_sweep.sh 컨벤션과 동일) ─────────────────────────
MODES=("greedy" "cb" "cat" "rl")
MODES_TO_RUN="${MODES_TO_RUN:-0 1 2 3}"
WORKLOADS="${WORKLOADS:-uniform hot_zipf hot_narrow skew_mid}"
RUNTIME="${RUNTIME:-90}"            # 단일 패턴 정적 인가 시간 (GC 충분 유발)

DEV="/dev/nvme1n1"
MOUNT_POINT="/home/meen/wild_cat/mnt"
FILE="${MOUNT_POINT}/workload.0.0"
FILL_SIZE="6G"
LOGS_DIR="./logs"
OUTDIR="${OUTDIR:-./static_results}"

START_VIRT="${START_VIRT:-./start_virt.sh}"
END_VIRT="${END_VIRT:-./end_virt.sh}"
RELOAD_TIMEOUT="${RELOAD_TIMEOUT:-60}"
SKIP_RELOAD="${SKIP_RELOAD:-0}"

START_TIME=$(date +%s)
mkdir -p "${OUTDIR}" "${LOGS_DIR}"

# ── 유틸 (fio_sweep.sh와 동일) ────────────────────────────────
format_eta() { local sec=$1 h m; h=$((sec/3600)); m=$(((sec%3600)/60)); [ $h -gt 0 ] && echo "${h}h ${m}m" || echo "${m}m"; }
get_field()  { echo "$1" | grep -oP "$2=\K[0-9.]+" | head -1; }
latest_flush()   { sudo dmesg | grep "NVMeVirt: \[FLUSH\]"   | tail -1; }
latest_wear()    { sudo dmesg | grep "NVMeVirt: \[Wear\]"    | tail -1; }
latest_weargap() { sudo dmesg | grep "NVMeVirt: \[WearGap\]" | tail -1; }

# ── 모듈 로드/언로드 (start_virt/end_virt 위임) ──────────────
load_mode() {
    local mode=$1
    if [ "${SKIP_RELOAD}" = "1" ]; then
        echo "  [load] SKIP_RELOAD=1 → 현재 로드된 모드 사용"; return 0
    fi
    if [ ! -x "${START_VIRT}" ]; then
        echo "  ❌ ${START_VIRT} 실행 불가"; return 1
    fi
    echo "  [load] ${START_VIRT} ${mode}"
    "${START_VIRT}" "${mode}"; sleep 2
    local w=0
    while [ ! -b "${DEV}" ] && [ $w -lt 15 ]; do sleep 1; w=$((w+1)); done
    [ ! -b "${DEV}" ] && { echo "  ❌ ${DEV} 미등장"; return 1; }
    sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1; sleep 2
    local fl actual gc
    fl=$(latest_flush)
    [ -z "$fl" ] && { echo "  ❌ FLUSH 없음 (모듈 비정상)"; return 1; }
    actual=$(echo "$fl" | grep -oP 'gc_mode=\K[0-9]')
    gc=$(echo "$fl" | grep -oP 'gc=\K[0-9]+')
    [ "$actual" != "$mode" ] && { echo "  ❌ gc_mode mismatch exp=${mode} act=${actual}"; return 1; }
    [ "$gc" != "0" ] && { echo "  ❌ gc=${gc} (fresh 아님)"; return 1; }
    echo "  ✅ 검증 통과: gc_mode=${actual}, gc=0"; return 0
}
unload_mode() {
    [ "${SKIP_RELOAD}" = "1" ] && return 0
    [ ! -x "${END_VIRT}" ] && { echo "  ⚠ ${END_VIRT} 없음 — 언로드 생략"; return 0; }
    echo "  [unload] ${END_VIRT}"
    timeout "${RELOAD_TIMEOUT}" "${END_VIRT}"
    [ $? -eq 124 ] && echo "  ⚠ end_virt timeout"
    sleep 3
    lsmod | grep -q nvmev && { echo "  ⚠ 모듈 잔존"; return 1; }
    return 0
}

do_fill() {
    local size=$1 attempt=1
    while [ $attempt -le 2 ]; do
        if timeout 300 fio --filename="${FILE}" --direct=1 --ioengine=libaio \
            --rw=write --bs=128k --size=${size} --numjobs=1 --name=fill >/dev/null 2>&1
        then return 0; fi
        echo "  ⚠ fill ${size} attempt ${attempt} 실패"; attempt=$((attempt+1)); sleep 30
    done
    return 1
}

# ── 순수 단일 워크로드 (축 반영비가 갈리도록 설계) ───────────
#
# 모든 패턴: 4k randwrite, time_based. 분포/영역만 다르게 하여
# "핫스팟 없음 ↔ 강한 쏠림" 스펙트럼을 만든다.
wl_uniform() {     # 핫스팟 없음: 전 영역 균등 → 마모 자연 분산
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=random \
        --time_based --runtime=${RUNTIME} --name=wl_uniform >/dev/null 2>&1
}
wl_hot_zipf() {    # 강한 핫스팟: zipf 2.0 전역 → 일부 블록에 erase 집중
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:2.0 \
        --time_based --runtime=${RUNTIME} --name=wl_hot_zipf >/dev/null 2>&1
}
wl_hot_narrow() {  # 쏠림 극대화: 좁은 1G 영역에 zipf 2.5
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=1G --random_distribution=zipf:2.5 \
        --time_based --runtime=${RUNTIME} --name=wl_hot_narrow >/dev/null 2>&1
}
wl_skew_mid() {    # 중간 쏠림: zipf 1.2 → 교차점 관찰용
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:1.2 \
        --time_based --runtime=${RUNTIME} --name=wl_skew_mid >/dev/null 2>&1
}

run_workload() {   # 워크로드 함수명으로 디스패치
    case "$1" in
        uniform)    wl_uniform ;;
        hot_zipf)   wl_hot_zipf ;;
        hot_narrow) wl_hot_narrow ;;
        skew_mid)   wl_skew_mid ;;
        *) echo "  ❌ 알 수 없는 워크로드: $1"; return 1 ;;
    esac
}

# ── 모드 1개 실행: load → (워크로드마다 fresh fill → 인가 → 1점) → unload
#
# 주의: 워크로드 간 erase 누적이 섞이면 정적 비교가 흐려지므로,
#       워크로드마다 모듈을 reload하여 fresh(gc=0)에서 시작한다.
#       SKIP_RELOAD=1이면 reload 없이 순차 측정(빠르지만 누적 섞임 주의).
run_mode() {
    local mode=$1 name csv raw wl
    name=${MODES[$mode]}
    csv="${OUTDIR}/static_${mode}_${name}.csv"
    raw="${LOGS_DIR}/static_log_${mode}_${name}.txt"

    echo ""
    echo "############################################"
    echo "# gc_mode=${mode} (${name}) - $(date)"
    echo "############################################"
    echo "workload,gc,copied,host,waf,ec_avg,ec_min,ec_max,ec_range,std,cov,weargap_per_gc" > "${csv}"
    : > "${raw}"

    for wl in ${WORKLOADS}; do
        echo "  --- workload=${wl} ---"

        # fresh 시작: 워크로드마다 reload (정적 비교 격리)
        load_mode "${mode}" || { echo "  ❌ load 실패 → ${wl} skip"; continue; }

        echo "  [fill] ${FILL_SIZE}"
        do_fill "${FILL_SIZE}" || { echo "  ❌ fill 실패 → ${wl} skip"; unload_mode; continue; }

        echo "  [run] ${wl} (${RUNTIME}s)"
        run_workload "${wl}" || echo "  ⚠ ${wl} fio 비정상 종료 (측정은 시도)"

        sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1; sleep 1
        local fl wr wg
        fl=$(latest_flush); wr=$(latest_wear); wg=$(latest_weargap)
        { echo "=== ${wl} ==="; echo "$fl"; echo "$wr"; echo "$wg"; } >> "${raw}"

        local gc cp host waf ec_avg ec_min ec_max ec_rng std cov pergc
        gc=$(get_field "$fl" gc);        gc=${gc:-0}
        cp=$(get_field "$fl" copied);    cp=${cp:-0}
        host=$(get_field "$fl" host);    host=${host:-0}
        waf=$(get_field "$fl" WAF);      waf=${waf:-0}
        ec_avg=$(get_field "$wr" avg);   ec_avg=${ec_avg:-0}
        ec_min=$(get_field "$wr" min);   ec_min=${ec_min:-0}
        ec_max=$(get_field "$wr" max);   ec_max=${ec_max:-0}
        ec_rng=$(get_field "$wr" range); ec_rng=${ec_rng:-0}
        std=$(get_field "$wr" std);      std=${std:-0}
        cov=$(get_field "$wr" CoV);      cov=${cov:-0}
        pergc=$(get_field "$wg" per_gc); pergc=${pergc:-0}

        echo "${wl},${gc},${cp},${host},${waf},${ec_avg},${ec_min},${ec_max},${ec_rng},${std},${cov},${pergc}" >> "${csv}"
        printf "    → WAF=%s  CoV=%s  range=%s  gc=%s\n" "$waf" "$cov" "$ec_rng" "$gc"

        unload_mode
        sleep 2
    done

    echo "  ✓ ${name} 완료 → ${csv}"
    return 0
}

# ── SIGINT 방어 ───────────────────────────────────────────────
trap 'echo ""; echo "⚠ INTERRUPTED — 부분 CSV는 ${OUTDIR}에 보존됨"; exit 130' INT TERM

# ── 시간 추정 ─────────────────────────────────────────────────
NM=$(echo ${MODES_TO_RUN} | wc -w)
NW=$(echo ${WORKLOADS}    | wc -w)
# 워크로드마다 reload+fill(~90s) + run(RUNTIME)
EST_PER_WL=$(( RUNTIME + 130 ))
EST_TOTAL=$(( EST_PER_WL * NW * NM ))
echo "============================================"
echo " fio_static (6.2 정적 그리드) 시작: $(date)"
echo " 모드: ${MODES_TO_RUN}   워크로드: ${WORKLOADS}"
echo " 패턴당 런타임=${RUNTIME}s   (워크로드마다 reload→fresh)"
echo " 예상: 총 ${NM}모드 × ${NW}워크로드 ~$(format_eta ${EST_TOTAL})"
echo " 결과: ${OUTDIR}/static_<n>_<name>.csv"
echo "============================================"

# ── 메인 ──────────────────────────────────────────────────────
SKIPPED=""
for i in ${MODES_TO_RUN}; do
    [ -z "${MODES[$i]:-}" ] && { echo "❌ 잘못된 mode: $i"; continue; }
    run_mode "$i" || SKIPPED="${SKIPPED} ${MODES[$i]}"
    sleep 3
done

# ── 요약: 워크로드 × 정책 그리드 (우위 교차 확인) ────────────
echo ""
echo "=== 요약: WAF 그리드 (행=워크로드, 열=정책) ==="
{
    printf "%-12s" "workload"
    for i in ${MODES_TO_RUN}; do printf "%10s" "${MODES[$i]}"; done
    echo ""
    for wl in ${WORKLOADS}; do
        printf "%-12s" "$wl"
        for i in ${MODES_TO_RUN}; do
            csv="${OUTDIR}/static_${i}_${MODES[$i]}.csv"
            v=$(awk -F, -v w="$wl" 'NR>1 && $1==w{print $5}' "${csv}" 2>/dev/null)
            printf "%10s" "${v:--}"
        done
        echo ""
    done
}
echo ""
echo "=== 요약: CoV 그리드 (행=워크로드, 열=정책) ==="
{
    printf "%-12s" "workload"
    for i in ${MODES_TO_RUN}; do printf "%10s" "${MODES[$i]}"; done
    echo ""
    for wl in ${WORKLOADS}; do
        printf "%-12s" "$wl"
        for i in ${MODES_TO_RUN}; do
            csv="${OUTDIR}/static_${i}_${MODES[$i]}.csv"
            v=$(awk -F, -v w="$wl" 'NR>1 && $1==w{print $11}' "${csv}" 2>/dev/null)
            printf "%10s" "${v:--}"
        done
        echo ""
    done
}

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "============================================"
echo " 🎉 완료: $(format_eta ${TOTAL_ELAPSED})"
[ -n "${SKIPPED}" ] && echo " ⚠ Skip:${SKIPPED}"
echo " CSV: ${OUTDIR}/   raw: ${LOGS_DIR}/"
echo " 분석: WAF 그리드에서 행마다 최저 정책, CoV 그리드에서 행마다"
echo "       최저 정책을 표시 → 두 최저가 다르고 워크로드마다 바뀌면"
echo "       '축 반영비가 워크로드에 따라 갈린다'(6.2 우위 교차) 입증."
echo "============================================"