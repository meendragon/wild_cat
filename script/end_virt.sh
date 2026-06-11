#!/bin/bash
# =============================================================
# end_virt.sh - NVMeVirt 모듈 정리 해제 (research-pc)
# =============================================================

MOUNT_POINT="/home/meen/wild_cat/mnt"
VDEV="/dev/nvme1n1"

echo "----------------------------------------"
echo "🛑 NVMeVirt 종료 중..."

# 1. umount 먼저 (이게 없으면 다음 start_virt에서 mkfs 실패)
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "📂 $MOUNT_POINT umount 중..."
    sudo umount "$MOUNT_POINT"
else
    sudo umount "$VDEV" 2>/dev/null
fi
sleep 1

# 2. 모듈 제거
if lsmod | grep -q "nvmev"; then
    # GC/RL 통계 출력 (flush 트리거)
    echo "📊 dmesg 통계:"
    sudo dmesg | grep "NVMeVirt:" | tail -5

    echo "🔄 nvmev 모듈 제거 중..."
    sudo rmmod nvmev
    if [ $? -eq 0 ]; then
        echo "✅ 모듈 제거 완료"
    else
        echo "❌ rmmod 실패 — 사용 중인 프로세스 확인: lsof $VDEV"
    fi
else
    echo "ℹ️  nvmev 모듈이 이미 없음"
fi

echo "----------------------------------------"