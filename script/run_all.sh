#!/bin/bash
# =============================================================
# run_all2.sh v3 - meen 서버 + 모듈 hang 방어 강화
#
# v3 변경점:
#   - end_virt에 timeout (60초) → rmmod hang 방지
#   - rmmod 실패 시 force_cleanup + 검증 (lsmod)
#   - 모듈 정리 실패하면 즉시 종료 + 사용자에게 reboot 알림
#     (계속 시도해봐야 모든 후속 모드 실패)


#   iostat -x 5 /dev/nvme1n1
#   watch -n 60 'free -g; echo ---; df -h /home/meen/nvmevirt_gc/mnt'
# =============================================================

MODES=("greedy" "cb" "cat" "rl")
SCEN="${SCEN:-all}"
MODES_TO_RUN="${MODES_TO_RUN:-0 1 2 3}"
LOGS_DIR="./logs"
DEV="/dev/nvme1n1"
MOUNT_POINT="/home/meen/wild_cat/mnt"

mkdir -p "${LOGS_DIR}"

# ─── 모듈 로드 검증 (gc_mode 일치 + gc=0 fresh 확인) ─────────
verify_module() {
    local expected_mode=$1

    if ! lsmod | grep -q nvmev; then
        echo "  ❌ nvmev module not loaded"
        return 1
    fi
    if [ ! -b "${DEV}" ]; then
        echo "  ❌ ${DEV} not found"
        return 1
    fi

    sudo nvme flush "${DEV}" -n 1 >/dev/null 2>&1
    sleep 2

    local last_flush=$(sudo dmesg | grep "NVMeVirt: \[FLUSH\]" | tail -1)
    if [ -z "$last_flush" ]; then
        echo "  ❌ No FLUSH in dmesg"
        return 1
    fi

    local actual_mode=$(echo "$last_flush" | grep -oP 'gc_mode=\K[0-9]')
    local gc_count=$(echo "$last_flush" | grep -oP 'gc=\K[0-9]+')

    if [ "$actual_mode" != "$expected_mode" ]; then
        echo "  ❌ gc_mode mismatch: expected=${expected_mode}, actual=${actual_mode}"
        return 1
    fi
    if [ "$gc_count" != "0" ]; then
        echo "  ❌ gc_count=$gc_count (이전 모드 잔재, fresh 아님)"
        return 1
    fi

    echo "  ✅ 모듈 검증 통과: gc_mode=${actual_mode}, gc=0"
    return 0
}

# ─── end_virt 안전 실행: timeout + 검증 ──────────────────────
safe_end_virt() {
    echo "  · end_virt 실행 (60초 timeout)"

    # end_virt.sh를 timeout으로 실행 - rmmod가 hang하면 강제 종료
    timeout 60 ./end_virt.sh
    local ret=$?

    if [ $ret -eq 124 ]; then
        echo "  ⚠ end_virt timeout (rmmod hang 추정)"
    fi

    sleep 3

    # 검증: 모듈이 진짜로 빠졌는가?
    if lsmod | grep -q nvmev; then
        echo "  ⚠ 모듈 여전히 로드됨, force cleanup 시도"
        return 1
    fi

    echo "  ✅ 모듈 unload 완료"
    return 0
}

# ─── 강제 정리 (모든 수단 동원) ───────────────────────────────
force_cleanup() {
    echo "  · Force cleanup 시도..."

    # 1. 모든 fio 죽이기
    sudo pkill -9 fio 2>/dev/null
    sleep 1

    # 2. unmount (lazy + force)
    timeout 10 sudo umount -lf "${MOUNT_POINT}" 2>/dev/null
    sleep 1

    # 3. rmmod (timeout 30초)
    if lsmod | grep -q nvmev; then
        timeout 30 sudo rmmod nvmev 2>/dev/null
        sleep 2

        if lsmod | grep -q nvmev; then
            # force는 위험하지만 마지막 시도
            timeout 10 sudo rmmod -f nvmev 2>/dev/null
            sleep 2
        fi
    fi

    if lsmod | grep -q nvmev; then
        echo "  ❌ 모듈 정리 실패 - 시스템 reboot 필요"
        return 1
    fi

    echo "  ✅ Force cleanup 성공"
    return 0
}

# ─── 모드 시작 (검증 포함, 1회만 재시도) ──────────────────────
start_mode() {
    local mode=$1

    ./start_virt.sh ${mode}
    sleep 2

    if verify_module ${mode}; then
        return 0
    fi

    echo "  🔄 1차 실패, force cleanup 후 재시도"
    force_cleanup
    if [ $? -ne 0 ]; then
        # 정리 자체가 실패하면 재시도 무의미
        return 2  # 시스템 차원 실패 신호
    fi
    sleep 3

    ./start_virt.sh ${mode}
    sleep 2

    if verify_module ${mode}; then
        echo "  ✅ 2차 시도 성공"
        return 0
    fi

    return 1
}

# ─── 메인 루프 ────────────────────────────────────────────────
GLOBAL_START=$(date +%s)
echo "============================================"
echo " run_all2 v3 시작: $(date)"
echo " 모드: ${MODES_TO_RUN}"
echo " 시나리오: ${SCEN}"
echo "============================================"

SKIPPED_MODES=""
FATAL_STOP=0

for i in ${MODES_TO_RUN}; do
    if [ $FATAL_STOP -eq 1 ]; then
        echo ""
        echo "⛔ 시스템 차원 실패로 ${MODES[$i]} 이후 모든 모드 skip"
        SKIPPED_MODES="${SKIPPED_MODES} ${MODES[$i]}"
        continue
    fi

    if [ -z "${MODES[$i]}" ]; then
        echo "❌ 잘못된 mode: $i"
        continue
    fi

    MODE_START=$(date +%s)

    echo ""
    echo "############################################"
    echo "# gc_mode=${i} (${MODES[$i]}) 시작 - $(date)"
    echo "############################################"

    # 모듈 로드 + 검증
    start_mode ${i}
    local_ret=$?

    if [ $local_ret -eq 2 ]; then
        # 시스템 차원 실패 (cleanup 자체 실패)
        echo "⛔ 모듈 정리 불가 - 더 이상 진행 불가능. 시스템 reboot 후 재시도 필요."
        SKIPPED_MODES="${SKIPPED_MODES} ${MODES[$i]}+"
        FATAL_STOP=1
        continue
    fi

    if [ $local_ret -ne 0 ]; then
        echo "❌ mode=${i} (${MODES[$i]}) 시작 실패, skip"
        SKIPPED_MODES="${SKIPPED_MODES} ${MODES[$i]}"
        continue
    fi

    # 워크로드 실행
    if [ "${SCEN}" = "all" ]; then
        LOG_FILE="${LOGS_DIR}/gc_log_${i}_${MODES[$i]}.txt"
        LOG="${LOG_FILE}" ./fio_write9.sh
    else
        LOG_FILE="${LOGS_DIR}/gc_log_${i}_${MODES[$i]}_s${SCEN}.txt"
        LOG="${LOG_FILE}" ./fio_write9.sh ${SCEN}
    fi

    # 모듈 언로드 (timeout 적용)
    if ! safe_end_virt; then
        echo "  🔄 end_virt 실패, force cleanup"
        if ! force_cleanup; then
            echo "⛔ 모듈 정리 불가 - 이후 모드 skip"
            FATAL_STOP=1
        fi
    fi

    MODE_END=$(date +%s)
    MODE_ELAPSED=$((MODE_END - MODE_START))
    MODE_MIN=$((MODE_ELAPSED / 60))

    echo ""
    echo "✅ [${MODES[$i]}] 완료 - ${MODE_MIN}분"
    sleep 3
done

GLOBAL_END=$(date +%s)
ELAPSED=$((GLOBAL_END - GLOBAL_START))
HRS=$((ELAPSED / 3600))
MIN=$(( (ELAPSED % 3600) / 60 ))

echo ""
echo "============================================"
echo " 🎉 종료: $(date)"
echo " 총 소요: ${HRS}h ${MIN}m"
if [ -n "${SKIPPED_MODES}" ]; then
    echo " ⚠ Skip된 모드:${SKIPPED_MODES}"
fi
if [ $FATAL_STOP -eq 1 ]; then
    echo ""
    echo " ⛔⛔ 시스템 차원 실패 발생. 모듈이 메모리에 stuck됨."
    echo "    Reboot 후 재실행 필요."
    echo "    부분 결과는 ${LOGS_DIR}/ 에 남아있음."
fi
echo "============================================"
echo ""
ls -la "${LOGS_DIR}/"