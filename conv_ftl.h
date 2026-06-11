// SPDX-License-Identifier: GPL-2.0-only
/*
 * conv_ftl.h - Conventional FTL for NVMeVirt
 *
 * GC victim 선택 정책 4종을 gc_mode 파라미터로 비교하는 FTL.
 *   0 Greedy : min-VPC (PQ root)
 *   1 CB     : age-weighted cost-benefit
 *   2 CAT    : CB + erase-count 분모 (wear-aware)
 *   3 RL     : Q-learning으로 scoring 지수(α,δ)를 선택
 *
 * CB/CAT/RL은 모두 동일한 score 식의 특수화:
 *   score = AgeWeight^α x IPC / ((VPC+1) x (EraseCnt+1)^δ)
 *     CB  = (α=1, δ=0), CAT = (α=1, δ=2), RL = 학습된 (α,δ)
 *
 * 평가지표: WAF, 그리고 GC마다 (max-min erase) wear-gap이 얼마나
 * 누적적으로 벌어지는지 (gc_mode별 비교는 conv_flush 출력 참고).
 *
 * --- RL 설계 요약 ---
 *   State  : 6D (4x4x4x3x3x3 = 1728)
 *   Action : 2축 (alpha 3 x delta 4 = 12)
 *   Reward : R = -W - λ·E   (W=per-GC WAF, E=상대 wear 변화)
 *   Q-table: 1728 x 12 = 20,736 entries (~162KB)
 */

#ifndef _NVMEVIRT_CONV_FTL_H
#define _NVMEVIRT_CONV_FTL_H

#include <linux/types.h>
#include "pqueue/pqueue.h"
#include "ssd_config.h"
#include "ssd.h"

struct conv_ftl;
typedef struct line *(*victim_select_fn)(struct conv_ftl *, bool);

/* GC victim 선택 모드 */
#define GC_MODE_GREEDY  0
#define GC_MODE_CB      1
#define GC_MODE_CAT     2
#define GC_MODE_RL      3

/* GC write-pointer 라우팅 (hot/cold 분리) */
#define GC_IO_HOT   10
#define GC_IO_COLD  11

/* ----------------------------------------------------------------
 * RL state/action 차원
 *
 * State 6축:
 *   S1 Greedy-vs-CB gap   : α의 cost          (4)
 *   S2 CB-vs-CAT gap      : δ의 cost          (4)
 *   S3 hot write ratio    : α의 benefit       (4)
 *   S4 hot ratio 추세     : α benefit의 Δ     (3)
 *   S5 erase 분배 질      : δ leading 지표    (3)
 *   S6 victim erase 분산  : δ lagging 지표    (3)
 *
 * Action 2축:
 *   A1 alpha_level (3) : α = 0.5, 1.0, 2.0
 *   A2 delta_level (4) : δ = 0, 0.5, 1.0, 1.5
 *   action = a1 * RL_NUM_A2 + a2
 * ---------------------------------------------------------------- */
#define RL_NUM_S1       4
#define RL_NUM_S2       4
#define RL_NUM_S3       4
#define RL_NUM_S4       3
#define RL_NUM_S5       3
#define RL_NUM_S6       3
#define RL_NUM_STATES   (RL_NUM_S1 * RL_NUM_S2 * RL_NUM_S3 * \
                         RL_NUM_S4 * RL_NUM_S5 * RL_NUM_S6) /* 1728 */

#define RL_NUM_A1       3   /* alpha levels */
#define RL_NUM_A2       4   /* delta levels */
#define RL_NUM_ACTIONS  (RL_NUM_A1 * RL_NUM_A2)  /* 12 */

/* 고정소수점 스케일 (커널 = no-FPU) */
#define RL_Q_SCALE      1000

/* RL 하이퍼파라미터 (모두 x1000 고정소수점) */
#define RL_ALPHA         100   /* 학습률 0.1 */
#define RL_GAMMA         950   /* 할인율 0.95 */
#define RL_EPSILON_INIT  300   /* 초기 탐험율 0.3 */
#define RL_EPSILON_MIN    50   /* 최소 탐험율 0.05 */
#define RL_EPSILON_DECAY 999   /* 에피소드당 x0.999 */
#define RL_LAMBDA        500   /* wear 가중치 (WAF 대비) */

/*
 * RL 에이전트 상태.
 * window_*  : conv_write에서 갱신 (S3/S4용 hot write 통계)
 * last_victim_ec : do_gc에서 갱신 (S5용)
 * prev_*    : reward 계산을 위한 직전 GC 스냅샷
 */
struct rl_config {
	int64_t q_table[RL_NUM_STATES][RL_NUM_ACTIONS];

	uint32_t cur_state;
	uint32_t cur_action;
	uint32_t alpha_level;      /* 0,1,2   -> α = 0.5, 1.0, 2.0 */
	uint32_t delta_level;      /* 0,1,2,3 -> δ = 0, 0.5, 1.0, 1.5 */
	uint32_t epsilon;

	uint64_t prev_copied_pages;
	uint32_t prev_erase_max;
	uint32_t prev_erase_min;

	uint32_t window_hot;
	uint32_t window_total;
	uint32_t prev_hot_pct;

	uint32_t last_victim_ec;

	uint64_t total_episodes;
	int64_t  total_reward;
};

/* per-LPN hot/cold 메타데이터 */
struct page_meta {
	uint32_t update_cnt;
	uint64_t last_write_time;
};

struct convparams {
	uint32_t gc_thres_lines;
	uint32_t gc_thres_lines_high;
	bool enable_gc_delay;
	double op_area_pcent;
	int pba_pcent;
};

struct line {
	int id;
	int ipc;
	int vpc;
	struct list_head entry;
	size_t pos;
	uint64_t last_modified_time;
	uint32_t erase_cnt;
};

struct write_pointer {
	struct line *curline;
	uint32_t ch;
	uint32_t lun;
	uint32_t pg;
	uint32_t blk;
	uint32_t pl;
};

struct line_mgmt {
	struct line *lines;
	struct list_head free_line_list;
	pqueue_t *victim_line_pq;
	struct list_head full_line_list;
	uint32_t tt_lines;
	uint32_t free_line_cnt;
	uint32_t victim_line_cnt;
	uint32_t full_line_cnt;
};

struct write_flow_control {
	uint32_t write_credits;
	uint32_t credits_to_refill;
};

/*
 * GC당 wear-gap(max-min erase) 누적 추적 — 전 모드 공통.
 *
 * 매 GC 직후 range = (max-min)를 측정하고, 직전 GC의 range와의
 * 차이(diff)를 wear_gap_accum에 누적한다. gc_count로 나누면
 * "GC 1회당 평균적으로 wear-gap이 얼마나 벌어지는지"가 나오며,
 * 이 값이 작을수록 wear-leveling이 우수하다 (모드 비교 핵심 지표).
 */
struct wear_gap_stats {
	uint32_t prev_range;       /* 직전 GC 직후의 (max-min) */
	int64_t  accum_diff;       /* range diff 누적 합 (부호 있음) */
	uint64_t samples;          /* diff를 누적한 횟수 (= gc_count-1) */
	bool     initialized;      /* 첫 GC에서 기준선 설정 여부 */
};

struct conv_ftl {
	struct ssd *ssd;
	struct convparams cp;
	struct ppa *maptbl;
	uint64_t *rmap;

	struct write_pointer wp;
	struct write_pointer gc_wp_hot;
	struct write_pointer gc_wp_cold;

	struct line_mgmt lm;
	struct write_flow_control wfc;

	struct page_meta *page_meta;
	uint64_t avg_hot_degree;

	struct rl_config rl;
	struct wear_gap_stats wgs;

	uint64_t gc_count;
	uint64_t gc_copied_pages;
	uint64_t host_written_pages;
};

void conv_init_namespace(struct nvmev_ns *ns, uint32_t id, uint64_t size,
			 void *mapped_addr, uint32_t cpu_nr_dispatcher);
void conv_remove_namespace(struct nvmev_ns *ns);
bool conv_proc_nvme_io_cmd(struct nvmev_ns *ns, struct nvmev_request *req,
			   struct nvmev_result *ret);

#endif /* _NVMEVIRT_CONV_FTL_H */