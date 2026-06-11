#!/bin/bash
# =============================================================
# insmod.sh - NVMeVirt 모듈 로드
#
# 사용법:
#   ./insmod.sh           → gc_mode=0 (Greedy)
#   ./insmod.sh 0         → Greedy
#   ./insmod.sh 1         → Cost-Benefit
#   ./insmod.sh 2         → CAT
#   ./insmod.sh 3         → RL
# =============================================================

GC_MODE=${1:-0}

# 설정
MEM_START="4G"
MEM_SIZE="8192M"
CPUS="1,2,3,4"
MODULE_PATH="/home/meen/wild_cat/nvmev.ko"

# 모드 이름
case $GC_MODE in
    0) MODE_NAME="Greedy" ;;
    1) MODE_NAME="Cost-Benefit" ;;
    2) MODE_NAME="CAT" ;;
    3) MODE_NAME="RL" ;;
    *) echo "❌ 잘못된 gc_mode: $GC_MODE (0~3)"
       exit 1 ;;
esac

echo "----------------------------------------"

# 기존 모듈 제거
if lsmod | grep -q "nvmev"; then
    echo "🔄 기존 nvmev 모듈 제거 중..."
    sudo rmmod nvmev
    sleep 1
else
    echo "ℹ️  기존 모듈 없음"
fi

# 모듈 삽입
echo "🚀 nvmev.ko 로드 중... (gc_mode=$GC_MODE: $MODE_NAME)"
CMD="sudo insmod $MODULE_PATH memmap_start=$MEM_START memmap_size=$MEM_SIZE cpus=$CPUS gc_mode=$GC_MODE"
echo "   $CMD"

$CMD

if [ $? -eq 0 ]; then
    echo "✅ 성공! gc_mode=$GC_MODE ($MODE_NAME)"
    lsmod | grep nvmev

    #!/bin/sh
    sleep 1
    sudo mkfs.ext4 -F /dev/nvme1n1
    #파일시스템을 만든다 - 리눅스에서 가장 많이 쓰이는거 ㅇㅇ 해당 드라이브에 아이노드라든지 수퍼블록같은 메타데이터
    sudo mount /dev/nvme1n1 /home/meen/wild_cat/mnt
    sudo chown meen:meen /home/meen/wild_cat/mnt

else
    echo "❌ 실패!"
    sudo dmesg | tail -10
    exit 1
fi
echo "----------------------------------------"