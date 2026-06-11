#!/bin/bash
#   ./fio_write9.sh                    # 기본 40 cycles
#   CYCLES=60 ./fio_write9.sh          # 천장 더 가까이
#   CYCLES=30 ./fio_write9.sh          # 시간 절약
# =============================================================
# fio_sweep.sh - 4-policy auto sweep + per-cycle trend CSV
#
# 기존 fio_write9.sh의 구조적 문제 3가지를 해결한 재작성본:
#
#   1) 모드 전환 자동화
#      기존: 사람이 정책마다 모듈을 다시 올리고 스크립트를 4번 실행
#            (= 19h 수동 운영). 본 버전은 GREEDY/CB/CAT/RL을 한 번에
#            순회하며 각 정책 사이 reload_module()로 gc_mode를 바꾼다.
#
#   2) 추세(trend) 데이터 보존
#      기존: log_phase가 'tail -2'로 *누적* FLUSH/Wear만 긁음. erase/WAF는
#            모듈 로드 후 단조 증가하는 누적치라 사이클 간 격차가 안 보임.
#      본 버전: 매 사이클 누적치를 읽어 직전 사이클과의 *증분(delta)*을
#            계산하고, 구간 WAF(=1+Δcopied/Δhost)와 WearGap per_gc를
#            CSV로 남긴다. "CAT은 단조 악화, RL은 안정"을 직접 플롯 가능.
#
#   3) 적정 실험 시간
#      기존: PATTERN_RT=60s × 7 × 40cyc = 정책당 ~4h50m.
#      본 버전: CYCLES 기본 20 (정책당 ~2.5h, 4정책 합 ~10h).
#            PATTERN_RT는 60s 유지 → v8과의 패턴 비교 가능성 보존,
#            시간 단축은 CYCLES로만 (명분이 깨지지 않는 축).
#
# 측정 지표:
#   WAF(구간/누적), erase range(max-min), CoV, WearGap per_gc.
#   특히 range 증분이 "GC당 wear-gap이 얼마나 벌어지는지"의 사이클 추세.
#
# 사용:
#   ./fio_sweep.sh                       # 4정책 × 20cyc
#   CYCLES=12 ./fio_sweep.sh             # 빠른 확인 (정책당 ~1.5h)
#   POLICIES="cat rl" ./fio_sweep.sh     # 일부 정책만
#   SKIP_RELOAD=1 ./fio_sweep.sh         # 현재 로드된 모드 하나만 측정
# =============================================================

set -u

# ── 설정 ──────────────────────────────────────────────────────
CYCLES=${CYCLES:-20}
PATTERN_RT=${PATTERN_RT:-60}
DIR="/home/meen/wild_cat/mnt"
DEV="/dev/nvme1n1"
FILE="${DIR}/workload.0.0"
FILL_SIZE="6G"
OUTDIR="${OUTDIR:-./sweep_results}"

# 순회할 정책 (이름 -> gc_mode 번호는 policy_to_mode 참조)
POLICIES="${POLICIES:-greedy cb cat rl}"

# 모듈 재로드를 건너뛰고 현재 로드된 모드만 측정할지
SKIP_RELOAD="${SKIP_RELOAD:-0}"

# ── 환경 의존: 모듈 경로/마운트 (★ 자기 환경에 맞게 채울 것) ──
#   비워두면 reload_module()이 수동 전환을 요구하고 멈춘다.
MODULE_KO="${MODULE_KO:-}"          # 예: /home/meen/wild_cat/nvmev.ko
MODULE_NAME="${MODULE_NAME:-nvmev}" # rmmod 대상 이름
# insmod 시 넘길 추가 파라미터 (디바이스 크기/CPU 등). 환경마다 다름.
MODULE_ARGS="${MODULE_ARGS:-}"      # 예: "memmap_start=16G memmap_size=12G cpus=0,1"

START_TIME=$(date +%s)
mkdir -p "${OUTDIR}"

# ── 유틸 ──────────────────────────────────────────────────────
format_eta() {
    local sec=$1 h m
    h=$((sec / 3600)); m=$(( (sec % 3600) / 60 ))
    [ $h -gt 0 ] && echo "${h}h ${m}m" || echo "${m}m"
}

policy_to_mode() {
    case "$1" in
        greedy) echo 0 ;;
        cb)     echo 1 ;;
        cat)    echo 2 ;;
        rl)     echo 3 ;;
        *)      echo -1 ;;
    esac
}

# dmesg 한 줄에서 key=value 추출 (정수/소수 공통)
get_field() { echo "$1" | grep -oP "$2=\K[0-9.]+" | head -1; }

# 가장 최근 FLUSH/Wear/WearGap 라인 1개씩
latest_flush()   { dmesg | grep "NVMeVirt: \[FLUSH\]"   | tail -1; }
latest_wear()    { dmesg | grep "NVMeVirt: \[Wear\]"    | tail -1; }
latest_weargap() { dmesg | grep "NVMeVirt: \[WearGap\]" | tail -1; }

# ── 모듈 재로드 (gc_mode 전환) ────────────────────────────────
#
# ★ 환경 의존 구간. rmmod -> insmod gc_mode=N -> (필요시) 마운트.
#   실제 mkfs/mount는 환경마다 다르고 잘못하면 데이터 유실이므로,
#   여기서는 모듈 로드까지만 수행하고 파일시스템 준비는 사용자가
#   PREP_CMD로 주입하도록 한다. MODULE_KO가 비면 수동 전환을 요청.
reload_module() {
    local mode=$1

    if [ "${SKIP_RELOAD}" = "1" ]; then
        echo "  [reload] SKIP_RELOAD=1 → 현재 로드된 모드 그대로 사용"
        return 0
    fi

    if [ -z "${MODULE_KO}" ]; then
        echo ""
        echo "  ⚠ MODULE_KO 미설정 → 자동 재로드 불가."
        echo "    지금 수동으로 gc_mode=${mode} 모듈을 올리고 마운트한 뒤 Enter."
        echo "    (자동화하려면 스크립트 상단 MODULE_KO/MODULE_ARGS를 채울 것)"
        read -r -p "    준비되면 Enter > " _
        return 0
    fi

    echo "  [reload] rmmod ${MODULE_NAME}; insmod gc_mode=${mode}"
    sync
    if lsmod | grep -q "^${MODULE_NAME}\b"; then
        rmmod "${MODULE_NAME}" || { echo "  ❌ rmmod 실패"; return 1; }
    fi
    sleep 2
    # shellcheck disable=SC2086
    insmod "${MODULE_KO}" gc_mode=${mode} ${MODULE_ARGS} || {
        echo "  ❌ insmod 실패"; return 1;
    }
    sleep 2

    # 디바이스가 다시 나타날 때까지 대기
    local w=0
    while [ ! -b "${DEV}" ] && [ $w -lt 15 ]; do sleep 1; w=$((w+1)); done
    [ -b "${DEV}" ] || { echo "  ❌ ${DEV} 미등장"; return 1; }

    # 파일시스템 준비 (환경 의존). PREP_CMD가 있으면 실행.
    if [ -n "${PREP_CMD:-}" ]; then
        echo "  [reload] PREP_CMD 실행"
        bash -c "${PREP_CMD}" || { echo "  ❌ PREP_CMD 실패"; return 1; }
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

PATTERN_NAMES=("HOT_strong" "COLD" "BIMODAL" "CLIFF" "RESIZE_wide" "MIXED" "DECAY")
PATTERN_FNS=("p_hot_strong" "p_cold" "p_bimodal" "p_cliff" "p_resize_wide" "p_mixed" "p_decay")
NUM_PATTERNS=${#PATTERN_FNS[@]}

# 한 사이클 = 7패턴을 연속 실행. flush는 사이클 끝에서 1회만
# (패턴마다 flush하면 오버헤드 + 누적 증분 해석이 흐려짐).
run_one_cycle() {
    local i fn
    for ((i=0; i<NUM_PATTERNS; i++)); do
        fn=${PATTERN_FNS[$i]}
        "${fn}" || return 1
    done
    return 0
}

# ── 정책 1개 실행: fill → CYCLES회 사이클 → 사이클별 증분 CSV ──
run_policy() {
    local policy=$1 mode csv raw
    mode=$(policy_to_mode "${policy}")
    csv="${OUTDIR}/${policy}.csv"
    raw="${OUTDIR}/${policy}.dmesg.txt"

    echo ""
    echo "############################################################"
    echo "# POLICY=${policy} (gc_mode=${mode})"
    echo "############################################################"

    reload_module "${mode}" || { echo "  ❌ reload 실패, 정책 건너뜀"; return 1; }

    echo "  [fill] ${FILL_SIZE}"
    do_fill "${FILL_SIZE}" || { echo "  ❌ fill 실패"; return 1; }

    # CSV 헤더. seg_waf = 이 사이클 구간의 WAF (누적 아님).
    echo "cycle,d_gc,d_copied,d_host,seg_waf,cum_waf,ec_range,d_range,cov,weargap_per_gc" > "${csv}"
    : > "${raw}"

    # 기준선(fill 직후) 스냅샷
    timeout 30 nvme flush "${DEV}" -n 1 2>/dev/null; sleep 1
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
            [ ${consec_fail} -ge 3 ] && { echo "  ❌ 3연속 실패, 정책 중단"; break; }
            continue
        fi
        consec_fail=0

        # 사이클 끝 flush → 누적 스냅샷
        timeout 30 nvme flush "${DEV}" -n 1 2>/dev/null; sleep 1
        fl=$(latest_flush); wr=$(latest_wear); local wg; wg=$(latest_weargap)
        {
            echo "=== cycle ${c} ==="; echo "$fl"; echo "$wr"; echo "$wg";
        } >> "${raw}"

        local cur_gc cur_cp cur_host cur_rng cum_waf cov pergc
        cur_gc=$(get_field "$fl" gc);      cur_gc=${cur_gc:-$prev_gc}
        cur_cp=$(get_field "$fl" copied);  cur_cp=${cur_cp:-$prev_cp}
        cur_host=$(get_field "$fl" host);  cur_host=${cur_host:-$prev_host}
        cur_rng=$(get_field "$wr" range);  cur_rng=${cur_rng:-$prev_rng}
        cum_waf=$(get_field "$fl" WAF);    cum_waf=${cum_waf:-0}
        cov=$(get_field "$wr" CoV);        cov=${cov:-0}
        pergc=$(get_field "$wg" per_gc);   pergc=${pergc:-0}

        # 증분
        local d_gc d_cp d_host d_rng seg_waf
        d_gc=$((cur_gc - prev_gc))
        d_cp=$((cur_cp - prev_cp))
        d_host=$((cur_host - prev_host))
        d_rng=$((cur_rng - prev_rng))

        # 구간 WAF = 1 + Δcopied/Δhost (Δhost=0이면 1.0)
        if [ "${d_host}" -gt 0 ]; then
            seg_waf=$(awk "BEGIN{printf \"%.4f\", 1 + ${d_cp}/${d_host}}")
        else
            seg_waf="1.0000"
        fi

        echo "${c},${d_gc},${d_cp},${d_host},${seg_waf},${cum_waf},${cur_rng},${d_rng},${cov},${pergc}" >> "${csv}"

        prev_gc=$cur_gc; prev_cp=$cur_cp; prev_host=$cur_host; prev_rng=$cur_rng

        local cend elapsed eta
        cend=$(date +%s)
        elapsed=$((cend - START_TIME))
        if [ $c -lt $CYCLES ]; then
            eta=$(( (CYCLES - c) * (cend - cbeg) ))
            printf "  cycle %2d/%d  seg_waf=%s range=%s (Δ%+d)  ETA(policy) %s\n" \
                   "$c" "$CYCLES" "$seg_waf" "$cur_rng" "$d_rng" "$(format_eta $eta)"
        else
            printf "  cycle %2d/%d  seg_waf=%s range=%s (Δ%+d)  [done]\n" \
                   "$c" "$CYCLES" "$seg_waf" "$cur_rng" "$d_rng"
        fi
    done

    echo "  ✓ ${policy} 완료 → ${csv}"
    return 0
}

# ── SIGINT: 부분 결과 보존 ────────────────────────────────────
trap 'echo ""; echo "⚠ INTERRUPTED at $(date) — 부분 CSV는 ${OUTDIR}에 보존됨"; exit 130' INT TERM

# ── 시간 추정 ─────────────────────────────────────────────────
NP=$(echo ${POLICIES} | wc -w)
EST_PER_POLICY=$(( CYCLES * NUM_PATTERNS * (PATTERN_RT + 2) + 120 ))  # +fill/flush
EST_TOTAL=$(( EST_PER_POLICY * NP ))
echo "=== fio_sweep === policies=[${POLICIES}] cycles=${CYCLES} rt=${PATTERN_RT}s"
echo "예상: 정책당 ~$(format_eta ${EST_PER_POLICY}), 총 ${NP}정책 ~$(format_eta ${EST_TOTAL})"
echo "결과: ${OUTDIR}/<policy>.csv"

# ── 메인: 정책 순회 ───────────────────────────────────────────
for policy in ${POLICIES}; do
    [ "$(policy_to_mode "${policy}")" = "-1" ] && { echo "알 수 없는 정책: ${policy} (건너뜀)"; continue; }
    run_policy "${policy}"
done

# ── 요약: 정책별 마지막 5사이클 평균 비교 ─────────────────────
echo ""
echo "=== 요약 (마지막 5사이클 평균) ==="
printf "%-8s %10s %10s %10s %12s\n" "policy" "seg_waf" "ec_range" "cov" "wg_per_gc"
for policy in ${POLICIES}; do
    csv="${OUTDIR}/${policy}.csv"
    [ -f "${csv}" ] || continue
    awk -F, 'NR>1{rows[NR]=$0; n++; sw[n]=$5; rg[n]=$7; cv[n]=$9; wg[n]=$10}
        END{
            s=(n>5)?n-4:1; cw=0; cr=0; cc=0; cg=0; k=0;
            for(i=s;i<=n;i++){cw+=sw[i]; cr+=rg[i]; cc+=cv[i]; cg+=wg[i]; k++}
            if(k>0) printf "%10.4f %10.1f %10.4f %12.4f\n", cw/k, cr/k, cc/k, cg/k;
        }' "${csv}" | sed "s/^/$(printf '%-8s' ${policy}) /"
done

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "=== 전체 완료: $(format_eta ${TOTAL_ELAPSED}) ==="
echo "CSV 위치: ${OUTDIR}/"
echo "플롯 예: cycle별 seg_waf / ec_range 추세를 정책끼리 겹쳐 그리면"
echo "        'CAT 단조 악화 vs RL 안정'이 보이는지 확인 가능."