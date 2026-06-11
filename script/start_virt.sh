#!/bin/bash
# =============================================================
# start_virt.sh - NVMeVirt 모듈 로드 (research-pc)
#
# 사용법:
#   ./start_virt.sh           → gc_mode=0 (Greedy)
#   ./start_virt.sh 0         → Greedy
#   ./start_virt.sh 1         → Cost-Benefit
#   ./start_virt.sh 2         → CAT
#   ./start_virt.sh 3         → RL
# =============================================================

GC_MODE=${1:-0}

# ── research-pc 설정 ──
MEM_START="4G"
MEM_SIZE="8192M"
CPUS="1,2,3,4"
MODULE_PATH="/home/meen/wild_cat/nvmev.ko"
MOUNT_POINT="/home/meen/wild_cat/mnt"
VDEV="/dev/nvme1n1"
OWNER="meen:meen"

# 모드 이름
case $GC_MODE in
    0) MODE_NAME="Greedy" ;;
    1) MODE_NAME="Cost-Benefit" ;;
    2) MODE_NAME="CAT" ;;
    3) MODE_NAME="RL" ;;
    *) echo "❌ 잘못된 gc_mode: $GC_MODE (0~3)"
       exit 1 ;;
esac

# 정리 함수
cleanup() {
    echo "🧹 정리 중..."
    sudo umount "$MOUNT_POINT" 2>/dev/null
    sudo umount "$VDEV" 2>/dev/null
    if lsmod | grep -q "nvmev"; then
        sudo rmmod nvmev 2>/dev/null
        sleep 1
    fi
}

echo "----------------------------------------"

# ── 1단계: 기존 환경 정리 (umount → rmmod) ──
sudo umount "$MOUNT_POINT" 2>/dev/null
sudo umount "$VDEV" 2>/dev/null

if lsmod | grep -q "nvmev"; then
    echo "🔄 기존 nvmev 모듈 제거 중..."
    sudo rmmod nvmev
    sleep 1
else
    echo "ℹ️  기존 모듈 없음"
fi

# ── 2단계: 모듈 삽입 ──
echo "🚀 nvmev.ko 로드 중... (gc_mode=$GC_MODE: $MODE_NAME)"
CMD="sudo insmod $MODULE_PATH memmap_start=$MEM_START memmap_size=$MEM_SIZE cpus=$CPUS gc_mode=$GC_MODE"
echo "   $CMD"

$CMD

if [ $? -ne 0 ]; then
    echo "❌ insmod 실패!"
    sudo dmesg | tail -10
    exit 1
fi

echo "✅ insmod 성공! gc_mode=$GC_MODE ($MODE_NAME)"
lsmod | grep nvmev
sleep 1

# ── 3단계: 디바이스 존재 확인 ──
if [ ! -b "$VDEV" ]; then
    echo "❌ $VDEV 가 생성되지 않음! 정리 후 중단."
    cleanup
    exit 1
fi

# OS 디스크 충돌 방지
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null)
if [ -n "$ROOT_DISK" ] && echo "$VDEV" | grep -q "$ROOT_DISK"; then
    echo "❌ $VDEV 가 OS 디스크($ROOT_DISK)와 동일! 정리 후 중단."
    cleanup
    exit 1
fi

echo "✅ $VDEV 확인 완료 (가상 디바이스)"

# ── 4단계: 포맷 + 마운트 ──
echo "📁 파일시스템 생성 중..."
sudo mkfs.ext4 -F "$VDEV"
if [ $? -ne 0 ]; then
    echo "❌ mkfs 실패! 정리 후 중단."
    cleanup
    exit 1
fi

mkdir -p "$MOUNT_POINT"
sudo mount "$VDEV" "$MOUNT_POINT"
if [ $? -ne 0 ]; then
    echo "❌ mount 실패! 정리 후 중단."
    cleanup
    exit 1
fi

sudo chown $OWNER "$MOUNT_POINT"
echo "✅ Mount 완료! ($VDEV → $MOUNT_POINT)"
echo "----------------------------------------"