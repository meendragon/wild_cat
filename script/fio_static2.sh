#!/bin/bash
# =============================================================
# fio_static.sh - "각 factor가 개이득 보는 워크로드" 1:1 매핑 (6.2/4.1용)
#
# 목적:
#   정책마다 "그 정책이 단독 1등을 먹는" 순수 워크로드를 하나씩 짠다.
#   각 워크로드는 해당 정책이 반영하는 factor가 결정적으로 유리하도록
#   설계되어, 결과 표에서 "의도한 정책이 실제로 최저(=1등)인지"를
#   바로 확인할 수 있다. 정책마다 1등이 갈리면 → 우위 교차(6.2) 입증.
#
#   factor ↔ 정책 ↔ 워크로드 매핑:
#   ┌──────────┬─────────┬───────────┬────────────────────────────────┐
#   │ factor   │ 1등 정책│ 워크로드  │ 왜 그 정책이 이기나             │
#   ├──────────┼─────────┼───────────┼────────────────────────────────┤
#   │ cost     │ greedy  │ uniform   │ 핫스팟 없음. age/wear 정보가    │
#   │ (무효PG) │         │           │ 노이즈일 뿐 → 무효PG 최다 블록  │
#   │          │         │           │ 회수가 정답. WAF 기준 greedy.   │
#   ├──────────┼─────────┼───────────┼────────────────────────────────┤
#   │ age      │ cb      │ hot_shift │ hot 영역이 시간에 따라 이동.    │
#   │ (연령)   │         │           │ "무효화 멈춘 지 오래된" 블록을  │
#   │          │         │           │ 골라야 헛복사 회피. WAF 기준 cb.│
#   ├──────────┼─────────┼───────────┼────────────────────────────────┤
#   │ wear     │ cat     │ hot_zipf  │ 특정 블록에 erase 강하게 쏠림.  │
#   │ (마모)   │         │ hot_narrow│ 마모 분산 안 하면 CoV 폭발.     │
#   │          │         │           │ CoV 기준 cat.                   │
#   └──────────┴─────────┴───────────┴────────────────────────────────┘
#
#   판정 지표 (워크로드별로 "이 지표에서 1등이어야 한다"):
#     uniform    → WAF 에서 greedy 최저
#     hot_shift  → WAF 에서 cb     최저
#     hot_zipf   → CoV 에서 cat    최저
#     hot_narrow → CoV 에서 cat    최저
#
# 사용:
#   ./fio_static.sh                          # 4워크로드 × greedy/cb/cat (+rl)
#   MODES_TO_RUN="0 1 2" ./fio_static.sh     # rl 빼고 정적 3종만
#   RUNTIME=120 ./fio_static.sh              # 런타임 늘려 GC 더 유발
#   PHASES=4 ./fio_static.sh                 # hot_shift hot 이동 페이즈 수
# =============================================================

set -u

# ── 설정 ──────────────────────────────────────────────────────
MODES=("greedy" "cb" "cat" "rl")
MODES_TO_RUN="${MODES_TO_RUN:-0 1 2 3}"
WORKLOADS="${WORKLOADS:-uniform hot_shift hot_zipf hot_narrow}"
RUNTIME="${RUNTIME:-90}"
PHASES="${PHASES:-4}"              # hot_shift: hot 영역 이동 페이즈 수

DEV="/dev/nvme1n1"
MOUNT_POINT="/home/meen/wild_cat/mnt"
FILE="${MOUNT_POINT}/workload.0.0"
FILL_SIZE="6G"
DEV_SIZE_G="${DEV_SIZE_G:-6}"
LOGS_DIR="./logs"
OUTDIR="${OUTDIR:-./static_results}"

START_VIRT="${START_VIRT:-./start_virt.sh}"
END_VIRT="${END_VIRT:-./end_virt.sh}"
RELOAD_TIMEOUT="${RELOAD_TIMEOUT:-60}"
SKIP_RELOAD="${SKIP_RELOAD:-0}"

# 각 워크로드의 "이겨야 하는 정책"과 "판정 지표" (검증용)
declare -A WIN_POLICY=( [uniform]="greedy" [hot_shift]="cb" [hot_zipf]="cat" [hot_narrow]="cat" )
declare -A WIN_METRIC=( [uniform]="waf"    [hot_shift]="waf" [hot_zipf]="cov" [hot_narrow]="cov" )

START_TIME=$(date +%s)
mkdir -p "${OUTDIR}" "${LOGS_DIR}"

# ── 유틸 ──────────────────────────────────────────────────────
format_eta() { local sec=$1 h m; h=$((sec/3600)); m=$(((sec%3600)/60)); [ $h -gt 0 ] && echo "${h}h ${m}m" || echo "${m}m"; }
get_field()  { echo "$1" | grep -oP "$2=\K[0-9.]+" | head -1; }
latest_flush()   { sudo dmesg | grep "NVMeVirt: \[FLUSH\]"   | tail -1; }
latest_wear()    { sudo dmesg | grep "NVMeVirt: \[Wear\]"    | tail -1; }
latest_weargap() { sudo dmesg | grep "NVMeVirt: \[WearGap\]" | tail -1; }

# ── 모듈 로드/언로드 ─────────────────────────────────────────
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

# =============================================================
# 워크로드: 각 factor가 개이득 보는 순수 상황 1:1
# =============================================================

# ── [cost / greedy 1등] uniform ──────────────────────────────
# 핫스팟 없음 → 마모 자연 분산. age/wear 정보가 변별력이 없어
# 무효 페이지 최다 블록 회수(=greedy)가 곧 최선. WAF 기준 greedy.
wl_uniform() {
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=random \
        --time_based --runtime=${RUNTIME} --name=wl_uniform >/dev/null 2>&1
}

# ── [age / cb 1등] hot_shift ─────────────────────────────────
# hot 영역을 PHASES개 슬라이스로 순차 이동. 직전 페이즈의 hot
# 슬라이스는 다음 페이즈에 갱신이 멈춰 "무효화 멈춘 지 오래된"
# cold가 된다. greedy는 막 hot이 된(곧 또 무효화될) 슬라이스를
# 회수해 헛복사 → WAF 악화. cb(age)는 오래된 슬라이스를 우선
# 회수해 재무효화 회피 → WAF 최저. cat은 마모 분산하느라 곧
# 재무효화될 블록을 피해 다녀 WAF에서 cb보다 손해.
wl_hot_shift() {
    local slice_g phase_rt off nslice i
    slice_g=$(( DEV_SIZE_G / PHASES )); [ "$slice_g" -lt 1 ] && slice_g=1
    nslice=$(( DEV_SIZE_G / slice_g )); [ "$nslice" -lt 1 ] && nslice=1
    phase_rt=$(( RUNTIME / PHASES ));   [ "$phase_rt" -lt 5 ] && phase_rt=5
    for i in $(seq 0 $((PHASES-1))); do
        off=$(( (i % nslice) * slice_g ))
        echo "      [hot_shift] phase $((i+1))/${PHASES}  offset=${off}G size=${slice_g}G rt=${phase_rt}s"
        timeout $((phase_rt+15)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
            --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
            --offset=${off}G --size=${slice_g}G --random_distribution=zipf:1.8 \
            --time_based --runtime=${phase_rt} --name=wl_hot_shift_p${i} >/dev/null 2>&1
    done
}

# ── [wear / cat 1등] hot_zipf ────────────────────────────────
# 강한 핫스팟(zipf 2.0 전역) → 소수 블록에 erase 집중. 마모
# 분산을 안 하면 CoV 폭발. cat(wear)이 덜 마모된 블록을 우선
# 회수해 CoV 최저.
wl_hot_zipf() {
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --random_distribution=zipf:2.0 \
        --time_based --runtime=${RUNTIME} --name=wl_hot_zipf >/dev/null 2>&1
}

# ── [wear / cat 1등, 극단] hot_narrow ────────────────────────
# 쏠림 극대화: 좁은 1G 영역에 zipf 2.5 → 마모 편차 극대.
# cat의 CoV 우위가 가장 크게 벌어지는 지점.
wl_hot_narrow() {
    timeout $((RUNTIME+30)) fio --filename="${FILE}" --direct=1 --ioengine=libaio \
        --rw=randwrite --bs=4k --numjobs=1 --iodepth=32 --norandommap=1 --randrepeat=0 \
        --offset=0 --size=1G --random_distribution=zipf:2.5 \
        --time_based --runtime=${RUNTIME} --name=wl_hot_narrow >/dev/null 2>&1
}

run_workload() {
    case "$1" in
        uniform)    wl_uniform ;;
        hot_shift)  wl_hot_shift ;;
        hot_zipf)   wl_hot_zipf ;;
        hot_narrow) wl_hot_narrow ;;
        *) echo "  ❌ 알 수 없는 워크로드: $1"; return 1 ;;
    esac
}

# ── 모드 1개 실행 ─────────────────────────────────────────────
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
EST_PER_WL=$(( RUNTIME + 130 ))
EST_TOTAL=$(( EST_PER_WL * NW * NM ))
echo "============================================"
echo " fio_static (factor별 1등 워크로드) 시작: $(date)"
echo " 모드: ${MODES_TO_RUN}   워크로드: ${WORKLOADS}"
echo " 런타임=${RUNTIME}s  hot_shift 페이즈=${PHASES}"
echo " 매핑: uniform→greedy(WAF), hot_shift→cb(WAF), hot_zipf/narrow→cat(CoV)"
echo " 예상: 총 ${NM}모드 × ${NW}워크로드 ~$(format_eta ${EST_TOTAL})"
echo "============================================"

# ── 메인 ──────────────────────────────────────────────────────
SKIPPED=""
for i in ${MODES_TO_RUN}; do
    [ -z "${MODES[$i]:-}" ] && { echo "❌ 잘못된 mode: $i"; continue; }
    run_mode "$i" || SKIPPED="${SKIPPED} ${MODES[$i]}"
    sleep 3
done

# =============================================================
# 요약 + 판정
# =============================================================
cell() {  # cell <mode_idx> <workload> <col>
    awk -F, -v w="$2" -v c="$3" 'NR>1 && $1==w{print $c}' \
        "${OUTDIR}/static_${1}_${MODES[$1]}.csv" 2>/dev/null
}
print_grid() {  # print_grid <title> <col>
    echo ""
    echo "=== $1 (행=워크로드, 열=정책) ==="
    printf "%-12s" "workload"
    for i in ${MODES_TO_RUN}; do printf "%10s" "${MODES[$i]}"; done
    echo ""
    for wl in ${WORKLOADS}; do
        printf "%-12s" "$wl"
        for i in ${MODES_TO_RUN}; do
            local v; v=$(cell "$i" "$wl" "$2")
            printf "%10s" "${v:--}"
        done
        echo ""
    done
}
print_grid "WAF 그리드" 5
print_grid "CoV 그리드" 11

# ── 판정표: 워크로드마다 "의도한 정책"이 판정 지표에서 실제 1등인가 ──
echo ""
echo "=== 판정: 각 워크로드에서 의도한 정책이 1등인가 (정적 3종 greedy/cb/cat 기준) ==="
printf "%-12s %-6s %-7s %-12s %-14s %s\n" "workload" "지표" "기대" "기대값" "실제1등" "판정"
PASS=0; FAIL=0
for wl in ${WORKLOADS}; do
    metric="${WIN_METRIC[$wl]:-waf}"
    want="${WIN_POLICY[$wl]:-?}"
    [ "$metric" = "cov" ] && col=11 || col=5
    best_pol=""; best_val=""
    for i in 0 1 2; do
        echo " ${MODES_TO_RUN} " | grep -q " $i " || continue
        v=$(cell "$i" "$wl" "$col"); [ -z "$v" ] && continue
        if [ -z "$best_val" ] || awk -v a="$v" -v b="$best_val" 'BEGIN{exit !(a+0<b+0)}'; then
            best_val=$v; best_pol="${MODES[$i]}"
        fi
    done
    want_idx=-1
    case "$want" in greedy) want_idx=0;; cb) want_idx=1;; cat) want_idx=2;; esac
    want_val=$(cell "$want_idx" "$wl" "$col")
    verdict="?"
    if [ -n "$best_pol" ] && [ -n "$want_val" ]; then
        if [ "$best_pol" = "$want" ] || awk -v a="$want_val" -v b="$best_val" 'BEGIN{exit !(a+0<=b+0)}'; then
            verdict="✅PASS"; PASS=$((PASS+1))
        else
            verdict="❌FAIL"; FAIL=$((FAIL+1))
        fi
    fi
    printf "%-12s %-6s %-7s %-12s %-14s %s\n" \
        "$wl" "${metric^^}" "$want" "${want_val:--}" "${best_pol:--}(${best_val:--})" "$verdict"
done
echo "  ─────────────────────────────────────────────"
echo "  PASS=${PASS}  FAIL=${FAIL}"
echo "  → 워크로드마다 1등 정책이 갈리면(greedy/cb/cat 각각 1등 존재)"
echo "    '어느 factor를 강조해야 유리한지가 워크로드에 따라 갈린다'(6.2) 입증."

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "============================================"
echo " 🎉 완료: $(format_eta ${TOTAL_ELAPSED})"
[ -n "${SKIPPED}" ] && echo " ⚠ Skip:${SKIPPED}"
echo " CSV: ${OUTDIR}/   raw: ${LOGS_DIR}/"
echo "============================================"