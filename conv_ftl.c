// SPDX-License-Identifier: GPL-2.0-only
/*
 * conv_ftl.c - Conventional FTL (NVMeVirt 가상 SSD)
 *
 * gc_mode 파라미터로 4가지 GC victim 선택 정책을 비교한다.
 *   0 Greedy / 1 CB / 2 CAT / 3 RL
 *
 * CB/CAT/RL은 동일한 score 식의 특수화이며 (apply_alpha/apply_delta 참고),
 * compute_victim_score() 한 곳에서 (α,δ) 레벨만 바꿔 계산한다.
 *
 * 평가지표: WAF, 그리고 GC당 wear-gap(max-min erase) 누적 증가량.
 */
#include <linux/vmalloc.h>
#include <linux/ktime.h>
#include <linux/sched/clock.h>
#include <linux/moduleparam.h>
#include <linux/random.h>

#include "nvmev.h"
#include "conv_ftl.h"

static int gc_mode = GC_MODE_CAT;
module_param(gc_mode, int, 0644);
MODULE_PARM_DESC(gc_mode, "0=Greedy 1=CB 2=CAT 3=RL");

/* ================================================================
 * 수치 헬퍼
 * ================================================================ */

/* 정수 제곱근 (Newton-Raphson). 커널에 FPU가 없어 직접 구현. */
static uint32_t isqrt_u64(uint64_t n)
{
	uint64_t x, y;

	if (n <= 1)
		return (uint32_t)n;
	x = n;
	y = (x + 1) / 2;
	while (y < x) {
		x = y;
		y = (x + n / x) / 2;
	}
	return (uint32_t)x;
}

/* ================================================================
 * Age / Hot-degree
 * ================================================================ */

/*
 * Age를 4구간으로 정규화한 가중치.
 * 실제 age(ns)를 직접 쓰면 score가 overflow하거나 age가 지배적이
 * 되므로 구간별 고정 가중치로 매핑한다 (값이 클수록 cold).
 */
#define MS_TO_NS(x)  ((uint64_t)(x) * 1000000ULL)
#define SEC_TO_NS(x) ((uint64_t)(x) * 1000000000ULL)

#define TH_VERY_HOT  MS_TO_NS(100)   /* < 100ms : very hot */
#define TH_HOT       SEC_TO_NS(5)    /* < 5s    : hot      */
#define TH_WARM      SEC_TO_NS(60)   /* < 60s   : warm     */

static uint64_t get_age_weight(uint64_t age_ns)
{
	if (age_ns < TH_VERY_HOT)  return 1;
	if (age_ns < TH_HOT)       return 5;
	if (age_ns < TH_WARM)      return 20;
	return 100;
}

/* now 기준 line/page age. 시계 역행 방어 포함. */
static inline uint64_t elapsed_since(uint64_t now, uint64_t past)
{
	return (now > past) ? (now - past) : 0;
}

/*
 * Hot degree = update_cnt x HD_SCALE / age_weight.
 * 자주 갱신되고(높은 update_cnt) 최근에 쓰였을수록(작은 age_weight) 크다.
 */
#define HD_SCALE 1000

static uint64_t calc_hot_degree(struct page_meta *pm, uint64_t now)
{
	uint64_t aw;

	if (pm->update_cnt == 0)
		return 0;

	aw = get_age_weight(elapsed_since(now, pm->last_write_time));
	return ((uint64_t)pm->update_cnt * HD_SCALE) / aw;
}

/*
 * Hot/cold 판별. avg_hot_degree는 x16 고정소수점이므로 degree도 x16.
 * 전 모드 공통 (avg x 1.0 기준 고정).
 */
static bool page_is_hot(struct conv_ftl *ftl, uint64_t lpn, uint64_t now)
{
	uint64_t deg = calc_hot_degree(&ftl->page_meta[lpn], now);
	return (deg * 16) >= ftl->avg_hot_degree;
}

/* ================================================================
 * Victim score
 *
 * score = apply_alpha(AgeWeight, α) x IPC
 *         / ((VPC+1) x apply_delta(EraseCnt+1, δ))
 *
 * num/den을 분리 반환해 교차곱 비교(num1*den2 > num2*den1)로 분수
 * 나눗셈 없이 victim을 고른다.
 * ================================================================ */

/* AgeWeight^α : level 0/1/2 -> α=0.5/1.0/2.0 */
static uint64_t apply_alpha(uint64_t aw, uint32_t level)
{
	switch (level) {
	case 0:  return isqrt_u64(aw);
	case 1:  return aw;
	default: return aw * aw;
	}
}

/* (EraseCnt+1)^δ : level 0/1/2/3 -> δ=0/0.5/1.0/1.5 */
static uint64_t apply_delta(uint64_t ec1, uint32_t level)
{
	switch (level) {
	case 0:  return 1;
	case 1:  return isqrt_u64(ec1);
	case 2:  return ec1;
	default: return ec1 * isqrt_u64(ec1);
	}
}

/* line c의 score를 (num, den)으로 계산. */
static void compute_victim_score(struct line *c, uint64_t now,
				 uint32_t alpha_level, uint32_t delta_level,
				 uint64_t *num, uint64_t *den)
{
	uint64_t aw = get_age_weight(elapsed_since(now, c->last_modified_time));

	*num = apply_alpha(aw, alpha_level) * (uint64_t)c->ipc;
	*den = (uint64_t)(c->vpc + 1) *
	       apply_delta((uint64_t)c->erase_cnt + 1, delta_level);
	if (*den == 0)
		*den = 1;
}

/* ================================================================
 * 기본 유틸
 * ================================================================ */

/* 워드라인의 마지막 페이지인가 (실제 NAND_WRITE 발행 시점). */
static inline bool last_pg_in_wordline(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	return (ppa->g.pg % spp->pgs_per_oneshotpg) == (spp->pgs_per_oneshotpg - 1);
}

/* foreground GC 트리거 조건. open block 3개분 여유가 임계 이하면 GC. */
static inline bool should_gc_high(struct conv_ftl *ftl)
{
	return ftl->lm.free_line_cnt <= ftl->cp.gc_thres_lines_high;
}

/* ----- 매핑/역매핑 테이블 ----- */
static inline struct ppa get_maptbl_ent(struct conv_ftl *ftl, uint64_t lpn)
{
	return ftl->maptbl[lpn];
}

static inline void set_maptbl_ent(struct conv_ftl *ftl, uint64_t lpn,
				  struct ppa *ppa)
{
	NVMEV_ASSERT(lpn < ftl->ssd->sp.tt_pgs);
	ftl->maptbl[lpn] = *ppa;
}

/* PPA -> 선형 페이지 인덱스 (rmap 인덱스로 사용). */
static uint64_t ppa2pgidx(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	uint64_t idx = ppa->g.ch * spp->pgs_per_ch +
		       ppa->g.lun * spp->pgs_per_lun +
		       ppa->g.pl * spp->pgs_per_pl +
		       ppa->g.blk * spp->pgs_per_blk + ppa->g.pg;
	NVMEV_ASSERT(idx < spp->tt_pgs);
	return idx;
}

static inline uint64_t get_rmap_ent(struct conv_ftl *ftl, struct ppa *ppa)
{
	return ftl->rmap[ppa2pgidx(ftl, ppa)];
}

static inline void set_rmap_ent(struct conv_ftl *ftl, uint64_t lpn,
				struct ppa *ppa)
{
	ftl->rmap[ppa2pgidx(ftl, ppa)] = lpn;
}

/* ================================================================
 * PQ 콜백 (Greedy = vpc 기준 min-heap).
 * CB/CAT/RL은 linear scan이라 정렬엔 의존하지 않지만, 원소 삽입/제거/
 * 우선순위 갱신은 PQ를 통하므로 콜백은 필요하다.
 * ================================================================ */
static inline int victim_line_cmp_pri(pqueue_pri_t next, pqueue_pri_t curr)
{
	return (next > curr);
}
static inline pqueue_pri_t victim_line_get_pri(void *a)
{
	return ((struct line *)a)->vpc;
}
static inline void victim_line_set_pri(void *a, pqueue_pri_t pri)
{
	((struct line *)a)->vpc = pri;
}
static inline size_t victim_line_get_pos(void *a)
{
	return ((struct line *)a)->pos;
}
static inline void victim_line_set_pos(void *a, size_t pos)
{
	((struct line *)a)->pos = pos;
}

/* ================================================================
 * 쓰기 크레딧.
 * write_credits가 0 이하면 foreground_gc로 공간 확보 후 리필.
 * ================================================================ */
static inline void consume_write_credit(struct conv_ftl *ftl)
{
	ftl->wfc.write_credits--;
}

static void foreground_gc(struct conv_ftl *ftl);

static inline void check_and_refill_write_credit(struct conv_ftl *ftl)
{
	struct write_flow_control *wfc = &ftl->wfc;

	if (wfc->write_credits <= 0) {
		foreground_gc(ftl);
		if (wfc->credits_to_refill > 0)
			wfc->write_credits += wfc->credits_to_refill;
		else
			wfc->write_credits = 1; /* deadlock 방지 */
	}
}

/* ================================================================
 *
 *                 GC VICTIM 선택 전략
 *
 * select_fn은 do_gc에서 호출된다. RL은 do_gc 내부에서 score 레벨을
 * 결정한 뒤 select_victim_scored를 직접 호출한다.
 * ================================================================ */

/*
 * Greedy: PQ root(min VPC)를 O(1)로 꺼냄.
 * force=false면 vpc가 전체의 12.5% 이상일 때 NULL (비효율 GC 회피).
 */
static struct line *select_victim_greedy(struct conv_ftl *ftl, bool force)
{
	struct line_mgmt *lm = &ftl->lm;
	struct line *v = pqueue_peek(lm->victim_line_pq);

	if (!v)
		return NULL;
	if (!force && v->vpc > (ftl->ssd->sp.pgs_per_line / 8))
		return NULL;

	pqueue_pop(lm->victim_line_pq);
	v->pos = 0;
	lm->victim_line_cnt--;
	return v;
}

/*
 * score 기반 victim 선택 (CB/CAT/RL 공통).
 * victim queue를 linear scan하며 score가 최대인 line을 고른다.
 */
static struct line *select_victim_scored(struct conv_ftl *ftl,
					 uint32_t alpha_level,
					 uint32_t delta_level)
{
	struct line_mgmt *lm = &ftl->lm;
	pqueue_t *q = lm->victim_line_pq;
	struct line *best = NULL;
	uint64_t best_num = 0, best_den = 1;
	uint64_t now = ktime_get_ns();
	size_t i;

	/* pqueue는 1-based: size==1이면 비어 있음. d[1]..d[size-1]이 유효. */
	if (q->size <= 1)
		return NULL;

	for (i = 1; i < q->size; i++) {
		struct line *c = (struct line *)q->d[i];
		uint64_t num, den;

		if (!c)
			continue;

		compute_victim_score(c, now, alpha_level, delta_level,
				     &num, &den);

		if (best == NULL || num * best_den > best_num * den) {
			best = c;
			best_num = num;
			best_den = den;
		}
	}

	if (best) {
		pqueue_remove(q, best);
		best->pos = 0;
		lm->victim_line_cnt--;
	}
	return best;
}

/* CB = (α=1, δ=0) */
static struct line *select_victim_cb(struct conv_ftl *ftl, bool force)
{
	return select_victim_scored(ftl, 1, 0);
}

/* CAT = (α=1, δ=2) */
static struct line *select_victim_cat(struct conv_ftl *ftl, bool force)
{
	return select_victim_scored(ftl, 1, 2);
}

/* ================================================================
 *
 *                 RL (Q-learning) 인프라
 *
 * 학습 루프 (GC 1회 = 에피소드 1회):
 *   do_gc 진입
 *     1 rl_get_state()      : 6D -> 1728 state 이산화
 *     2 rl_select_action()  : ε-greedy로 12개 중 선택
 *     3 rl_decode_action()  : action -> (alpha, delta)
 *     4 select_victim_scored: 분해된 레벨로 victim scoring
 *     5 GC 수행 (copy + erase)
 *     6 rl_get_state()      : GC 후 next state
 *     7 rl_update()         : R = -W - λE -> Q 갱신 -> ε decay
 * ================================================================ */

/* 라인 배열 전체의 erase 통계 (max/min/sum). conv_flush/rl_update 공용. */
static void collect_erase_stats(struct line_mgmt *lm, uint32_t *ec_max,
				uint32_t *ec_min, uint64_t *ec_sum,
				uint64_t *ec_sqsum)
{
	uint32_t mx = 0, mn = UINT_MAX;
	uint64_t sum = 0, sqsum = 0;
	uint32_t i;

	for (i = 0; i < lm->tt_lines; i++) {
		uint32_t ec = lm->lines[i].erase_cnt;

		if (ec > mx) mx = ec;
		if (ec < mn) mn = ec;
		sum += ec;
		if (ec_sqsum)
			sqsum += (uint64_t)ec * ec;
	}
	if (lm->tt_lines == 0)
		mn = 0;

	*ec_max = mx;
	*ec_min = mn;
	*ec_sum = sum;
	if (ec_sqsum)
		*ec_sqsum = sqsum;
}

/*
 * GC당 wear-gap 누적 추적 (전 모드 공통, 매 GC 직후 호출).
 * range=(max-min)를 직전 GC range와 비교해 diff를 누적한다.
 * accum_diff / samples = "GC 1회당 평균 wear-gap 증가량".
 */
static void update_wear_gap(struct conv_ftl *ftl)
{
	struct wear_gap_stats *wgs = &ftl->wgs;
	uint32_t ec_max, ec_min, cur_range;
	uint64_t ec_sum;

	collect_erase_stats(&ftl->lm, &ec_max, &ec_min, &ec_sum, NULL);
	cur_range = ec_max - ec_min;

	if (!wgs->initialized) {
		wgs->prev_range = cur_range;
		wgs->initialized = true;
		return;
	}

	wgs->accum_diff += (int64_t)cur_range - (int64_t)wgs->prev_range;
	wgs->samples++;
	wgs->prev_range = cur_range;
}

/*
 * rl_get_state() - 6D state를 1차원 인덱스(0..1727)로 이산화.
 *
 * victim queue 1회 scan으로 S1,S2,S5,S6를 동시 계산.
 * S3,S4는 conv_write가 갱신한 window 카운터에서 읽는다.
 */
static uint32_t rl_get_state(struct conv_ftl *ftl)
{
	struct line_mgmt *lm = &ftl->lm;
	struct ssdparams *spp = &ftl->ssd->sp;
	struct rl_config *rl = &ftl->rl;
	pqueue_t *q = lm->victim_line_pq;
	uint32_t s1, s2, s3, s4, s5, s6;
	uint64_t now = ktime_get_ns();
	uint32_t i;

	struct line *greedy_best = NULL, *cb_best = NULL, *cat_best = NULL;
	uint32_t greedy_min_vpc = UINT_MAX;
	uint64_t cb_max = 0, cat_max = 0;
	uint32_t s1_gap, s2_gap;

	uint32_t v_ec_max = 0, v_ec_min = UINT_MAX;
	uint64_t v_ec_sum = 0;
	uint32_t v_count = 0, v_ec_mean, wear_rel;

	/* ---- victim queue scan: S1/S2/S5/S6 동시 계산 ---- */
	for (i = 1; i < q->size; i++) {
		struct line *c = (struct line *)q->d[i];
		uint64_t num, den, cb_score, cat_score;

		if (!c)
			continue;

		if (c->vpc < greedy_min_vpc) {
			greedy_min_vpc = c->vpc;
			greedy_best = c;
		}

		/* CB = (α=1,δ=0) */
		compute_victim_score(c, now, 1, 0, &num, &den);
		cb_score = num / den;
		if (cb_score > cb_max) {
			cb_max = cb_score;
			cb_best = c;
		}

		/* CAT = (α=1,δ=2) */
		compute_victim_score(c, now, 1, 2, &num, &den);
		cat_score = num / den;
		if (cat_score > cat_max) {
			cat_max = cat_score;
			cat_best = c;
		}

		if (c->erase_cnt > v_ec_max) v_ec_max = c->erase_cnt;
		if (c->erase_cnt < v_ec_min) v_ec_min = c->erase_cnt;
		v_ec_sum += c->erase_cnt;
		v_count++;
	}

	/* S1: Greedy vs CB VPC gap (α의 cost) */
	if (greedy_best && cb_best && greedy_best != cb_best &&
	    cb_best->vpc > greedy_best->vpc)
		s1_gap = (cb_best->vpc - greedy_best->vpc) * 100 / spp->pgs_per_line;
	else
		s1_gap = 0;
	if      (s1_gap < 3)   s1 = 0;
	else if (s1_gap < 8)   s1 = 1;
	else if (s1_gap < 18)  s1 = 2;
	else                   s1 = 3;

	/* S2: CB vs CAT VPC gap (δ의 cost) */
	if (cb_best && cat_best && cb_best != cat_best &&
	    cat_best->vpc > cb_best->vpc)
		s2_gap = (cat_best->vpc - cb_best->vpc) * 100 / spp->pgs_per_line;
	else
		s2_gap = 0;
	if      (s2_gap < 3)   s2 = 0;
	else if (s2_gap < 8)   s2 = 1;
	else if (s2_gap < 18)  s2 = 2;
	else                   s2 = 3;

	/* S5: 최근 victim ec vs queue 평균 (erase 분배 질) */
	v_ec_mean = (v_count > 0) ? (uint32_t)(v_ec_sum / v_count) : 0;
	if (rl->last_victim_ec <= v_ec_mean)
		s5 = 0;
	else if (rl->last_victim_ec <= v_ec_mean + v_ec_mean / 2)
		s5 = 1;
	else
		s5 = 2;

	/* S6: victim queue 내 상대편차 */
	wear_rel = (v_count > 0 && v_ec_mean > 0) ?
		   (v_ec_max - v_ec_min) * 100 / (v_ec_mean + 1) : 0;
	if      (wear_rel < 5)   s6 = 0;
	else if (wear_rel < 20)  s6 = 1;
	else                     s6 = 2;

	/* S3: hot write ratio */
	{
		uint32_t hot_pct = (rl->window_total > 0) ?
			rl->window_hot * 100 / rl->window_total : 0;
		if      (hot_pct < 10)  s3 = 0;
		else if (hot_pct < 30)  s3 = 1;
		else if (hot_pct < 55)  s3 = 2;
		else                    s3 = 3;
	}

	/* S4: hot ratio 추세 */
	{
		uint32_t cur_pct = (rl->window_total > 0) ?
			rl->window_hot * 100 / rl->window_total : 0;
		int32_t diff = (int32_t)cur_pct - (int32_t)rl->prev_hot_pct;
		if      (diff < -8)  s4 = 0;
		else if (diff > 8)   s4 = 2;
		else                 s4 = 1;
	}

	return s1 * (RL_NUM_S2 * RL_NUM_S3 * RL_NUM_S4 * RL_NUM_S5 * RL_NUM_S6) +
	       s2 * (RL_NUM_S3 * RL_NUM_S4 * RL_NUM_S5 * RL_NUM_S6) +
	       s3 * (RL_NUM_S4 * RL_NUM_S5 * RL_NUM_S6) +
	       s4 * (RL_NUM_S5 * RL_NUM_S6) +
	       s5 * RL_NUM_S6 + s6;
}

/* action -> (alpha_level, delta_level) */
static void rl_decode_action(struct rl_config *rl, uint32_t action)
{
	rl->cur_action = action;
	rl->alpha_level = action / RL_NUM_A2;
	rl->delta_level = action % RL_NUM_A2;
}

/*
 * ε-greedy action 선택.
 * 확률 ε: 랜덤(탐험), 1-ε: argmax Q(state,·)(활용).
 */
static uint32_t rl_select_action(struct rl_config *rl, uint32_t state)
{
	uint32_t a, best_a = 0;
	int64_t best_q;

	if ((get_random_u32() % 1000) < rl->epsilon)
		return get_random_u32() % RL_NUM_ACTIONS;

	best_q = rl->q_table[state][0];
	for (a = 1; a < RL_NUM_ACTIONS; a++) {
		if (rl->q_table[state][a] > best_q) {
			best_q = rl->q_table[state][a];
			best_a = a;
		}
	}
	return best_a;
}

/*
 * rl_update() - reward 계산 + Q 갱신.
 *
 *   Q(s,a) += α[R + γ·max Q(s',·) - Q(s,a)]
 *   R = -W - λE
 *     W = copied x 1000 / pgs_per_line                  (per-GC WAF)
 *     E = Δrange x 1000/(mean+1) + range x 250/(mean+1)  ([-2000,2000] clamp)
 */
static void rl_update(struct conv_ftl *ftl, uint32_t new_state)
{
	struct rl_config *rl = &ftl->rl;
	struct line_mgmt *lm = &ftl->lm;
	int64_t reward, waf_penalty, wear_penalty;
	int64_t max_q_next, old_q;
	uint64_t copied, erase_sum;
	uint32_t ppl = ftl->ssd->sp.pgs_per_line;
	uint32_t erase_max, erase_min, erase_mean, cur_range, prev_range;
	int32_t wear_delta;
	uint32_t i;

	/* W: WAF 항 */
	copied = ftl->gc_copied_pages - rl->prev_copied_pages;
	waf_penalty = (ppl > 0) ? (int64_t)copied * 1000 / (int64_t)ppl : 0;

	/* E: wear 항 (level + delta 결합) */
	collect_erase_stats(lm, &erase_max, &erase_min, &erase_sum, NULL);
	erase_mean = (lm->tt_lines > 0) ?
		     (uint32_t)(erase_sum / lm->tt_lines) : 1;

	cur_range  = erase_max - erase_min;
	prev_range = (rl->prev_erase_max >= rl->prev_erase_min) ?
		     rl->prev_erase_max - rl->prev_erase_min : 0;
	wear_delta = (int32_t)cur_range - (int32_t)prev_range;

	{
		int64_t delta_term = (int64_t)wear_delta * 1000 / (erase_mean + 1);
		int64_t level_term = (int64_t)cur_range  * 1000 / (erase_mean + 1);

		wear_penalty = delta_term + level_term / 4;
		if (wear_penalty >  2000) wear_penalty =  2000;
		if (wear_penalty < -2000) wear_penalty = -2000;
	}

	reward = -waf_penalty - RL_LAMBDA * wear_penalty / RL_Q_SCALE;

	/* Q-learning 갱신 */
	max_q_next = rl->q_table[new_state][0];
	for (i = 1; i < RL_NUM_ACTIONS; i++) {
		if (rl->q_table[new_state][i] > max_q_next)
			max_q_next = rl->q_table[new_state][i];
	}
	old_q = rl->q_table[rl->cur_state][rl->cur_action];
	rl->q_table[rl->cur_state][rl->cur_action] = old_q +
		RL_ALPHA * (reward + RL_GAMMA * max_q_next / RL_Q_SCALE - old_q)
		/ RL_Q_SCALE;

	/* ε decay */
	rl->epsilon = (rl->epsilon * RL_EPSILON_DECAY) / 1000;
	if (rl->epsilon < RL_EPSILON_MIN)
		rl->epsilon = RL_EPSILON_MIN;

	rl->total_episodes++;
	rl->total_reward += reward;

	rl->prev_copied_pages = ftl->gc_copied_pages;
	rl->prev_erase_max = erase_max;
	rl->prev_erase_min = erase_min;
}

/* ================================================================
 *
 *                 초기화 / 해제
 *
 * ================================================================ */

static void init_lines(struct conv_ftl *ftl)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct line_mgmt *lm = &ftl->lm;
	int i;

	lm->tt_lines = spp->tt_lines;
	lm->lines = vmalloc(sizeof(struct line) * lm->tt_lines);

	lm->victim_line_pq = pqueue_init(lm->tt_lines,
					 victim_line_cmp_pri,
					 victim_line_get_pri,
					 victim_line_set_pri,
					 victim_line_get_pos,
					 victim_line_set_pos);

	INIT_LIST_HEAD(&lm->free_line_list);
	INIT_LIST_HEAD(&lm->full_line_list);
	lm->free_line_cnt = 0;

	for (i = 0; i < (int)lm->tt_lines; i++) {
		lm->lines[i] = (struct line){
			.id = i,
			.ipc = 0,
			.vpc = 0,
			.pos = 0,
			.last_modified_time = 0,
			.erase_cnt = 0,
			.entry = LIST_HEAD_INIT(lm->lines[i].entry),
		};
		list_add_tail(&lm->lines[i].entry, &lm->free_line_list);
		lm->free_line_cnt++;
	}

	NVMEV_ASSERT(lm->free_line_cnt == spp->tt_lines);
	lm->victim_line_cnt = 0;
	lm->full_line_cnt = 0;
}

static void remove_lines(struct conv_ftl *ftl)
{
	pqueue_free(ftl->lm.victim_line_pq);
	vfree(ftl->lm.lines);
}

static void init_page_meta(struct conv_ftl *ftl)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	int i;

	ftl->page_meta = vmalloc(sizeof(struct page_meta) * spp->tt_pgs);
	for (i = 0; i < spp->tt_pgs; i++) {
		ftl->page_meta[i].update_cnt = 0;
		ftl->page_meta[i].last_write_time = 0;
	}
	ftl->avg_hot_degree = 16;  /* x16 고정소수점에서 1.0 */
}

static void remove_page_meta(struct conv_ftl *ftl)
{
	vfree(ftl->page_meta);
}

/* RL 에이전트 초기화. Q-table=0, 기본 (α,δ)=CAT 수준에서 시작. */
static void init_rl(struct conv_ftl *ftl)
{
	struct rl_config *rl = &ftl->rl;

	memset(rl->q_table, 0, sizeof(rl->q_table));
	rl->cur_state = 0;
	rl->cur_action = 0;
	rl->alpha_level = 1;   /* α=1.0 */
	rl->delta_level = 2;   /* δ=1.0 */
	rl->epsilon = RL_EPSILON_INIT;
	rl->prev_copied_pages = 0;
	rl->prev_erase_max = 0;
	rl->prev_erase_min = 0;
	rl->window_hot = 0;
	rl->window_total = 0;
	rl->prev_hot_pct = 0;
	rl->last_victim_ec = 0;
	rl->total_episodes = 0;
	rl->total_reward = 0;
}

static void init_wear_gap(struct conv_ftl *ftl)
{
	ftl->wgs.prev_range = 0;
	ftl->wgs.accum_diff = 0;
	ftl->wgs.samples = 0;
	ftl->wgs.initialized = false;
}

static void init_write_flow_control(struct conv_ftl *ftl)
{
	ftl->wfc.write_credits = ftl->ssd->sp.pgs_per_line;
	ftl->wfc.credits_to_refill = ftl->ssd->sp.pgs_per_line;
}

/* ================================================================
 * Write pointer
 * ================================================================ */
static inline void check_addr(int a, int max)
{
	NVMEV_ASSERT(a >= 0 && a < max);
}

static struct line *get_next_free_line(struct conv_ftl *ftl)
{
	struct line_mgmt *lm = &ftl->lm;
	struct line *cur = list_first_entry_or_null(&lm->free_line_list,
						    struct line, entry);
	if (!cur) {
		NVMEV_ERROR("No free line!\n");
		return NULL;
	}
	list_del_init(&cur->entry);
	lm->free_line_cnt--;
	return cur;
}

/* io_type -> write pointer. USER / GC_HOT / GC_COLD. */
static struct write_pointer *__get_wp(struct conv_ftl *ftl, uint32_t io_type)
{
	switch (io_type) {
	case USER_IO:    return &ftl->wp;
	case GC_IO_HOT:  return &ftl->gc_wp_hot;
	case GC_IO_COLD: return &ftl->gc_wp_cold;
	default: NVMEV_ASSERT(0); return NULL;
	}
}

static void prepare_write_pointer(struct conv_ftl *ftl, uint32_t io_type)
{
	struct write_pointer *wp = __get_wp(ftl, io_type);
	struct line *cur = get_next_free_line(ftl);

	NVMEV_ASSERT(wp && cur);
	*wp = (struct write_pointer){
		.curline = cur, .ch = 0, .lun = 0,
		.pg = 0, .blk = cur->id, .pl = 0,
	};
}

/*
 * Write pointer 전진. 인터리빙: pg -> ch -> lun -> wordline -> 블록끝.
 * 블록 끝에서 현재 라인을 full/victim으로 전이하고 새 free 라인을 연다.
 */
static void advance_write_pointer(struct conv_ftl *ftl, uint32_t io_type)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct line_mgmt *lm = &ftl->lm;
	struct write_pointer *wpp = __get_wp(ftl, io_type);

	check_addr(wpp->pg, spp->pgs_per_blk);
	wpp->pg++;
	if ((wpp->pg % spp->pgs_per_oneshotpg) != 0)
		return;

	wpp->pg -= spp->pgs_per_oneshotpg;
	check_addr(wpp->ch, spp->nchs);
	wpp->ch++;
	if (wpp->ch != spp->nchs)
		return;

	wpp->ch = 0;
	check_addr(wpp->lun, spp->luns_per_ch);
	wpp->lun++;
	if (wpp->lun != spp->luns_per_ch)
		return;

	wpp->lun = 0;
	wpp->pg += spp->pgs_per_oneshotpg;
	if (wpp->pg != spp->pgs_per_blk)
		return;

	/* 블록 끝: 라인 전이 */
	wpp->pg = 0;
	if (wpp->curline->vpc == spp->pgs_per_line) {
		NVMEV_ASSERT(wpp->curline->ipc == 0);
		list_add_tail(&wpp->curline->entry, &lm->full_line_list);
		lm->full_line_cnt++;
	} else {
		NVMEV_ASSERT(wpp->curline->ipc > 0);
		pqueue_insert(lm->victim_line_pq, wpp->curline);
		lm->victim_line_cnt++;
	}

	check_addr(wpp->blk, spp->blks_per_pl);
	wpp->curline = get_next_free_line(ftl);
	wpp->blk = wpp->curline->id;
	check_addr(wpp->blk, spp->blks_per_pl);

	NVMEV_ASSERT(wpp->pg == 0 && wpp->lun == 0 &&
		     wpp->ch == 0 && wpp->pl == 0);
}

static struct ppa get_new_page(struct conv_ftl *ftl, uint32_t io_type)
{
	struct write_pointer *wp = __get_wp(ftl, io_type);
	struct ppa ppa = { .ppa = 0 };

	ppa.g.ch = wp->ch;
	ppa.g.lun = wp->lun;
	ppa.g.pg = wp->pg;
	ppa.g.blk = wp->blk;
	ppa.g.pl = wp->pl;

	NVMEV_ASSERT(ppa.g.pl == 0);
	return ppa;
}

/* ================================================================
 * 매핑/역매핑 테이블 초기화
 * ================================================================ */
static void init_maptbl(struct conv_ftl *ftl)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	int i;

	ftl->maptbl = vmalloc(sizeof(struct ppa) * spp->tt_pgs);
	for (i = 0; i < spp->tt_pgs; i++)
		ftl->maptbl[i].ppa = UNMAPPED_PPA;
}
static void remove_maptbl(struct conv_ftl *ftl) { vfree(ftl->maptbl); }

static void init_rmap(struct conv_ftl *ftl)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	int i;

	ftl->rmap = vmalloc(sizeof(uint64_t) * spp->tt_pgs);
	for (i = 0; i < spp->tt_pgs; i++)
		ftl->rmap[i] = INVALID_LPN;
}
static void remove_rmap(struct conv_ftl *ftl) { vfree(ftl->rmap); }

/* ================================================================
 * FTL 인스턴스 초기화 / 제거
 * ================================================================ */
static void conv_init_ftl(struct conv_ftl *ftl, struct convparams *cpp,
			  struct ssd *ssd)
{
	ftl->cp = *cpp;
	ftl->ssd = ssd;
	ftl->gc_count = 0;
	ftl->gc_copied_pages = 0;
	ftl->host_written_pages = 0;

	init_maptbl(ftl);
	init_rmap(ftl);
	init_page_meta(ftl);
	init_lines(ftl);
	init_rl(ftl);
	init_wear_gap(ftl);

	/* write pointer 3개 = open block 3개 (gc_thres_lines=3의 근거). */
	prepare_write_pointer(ftl, USER_IO);
	prepare_write_pointer(ftl, GC_IO_HOT);
	prepare_write_pointer(ftl, GC_IO_COLD);

	init_write_flow_control(ftl);

	NVMEV_INFO("Init FTL: %d ch, %ld pgs, gc_mode=%d\n",
		   ssd->sp.nchs, ssd->sp.tt_pgs, gc_mode);
}

static void conv_remove_ftl(struct conv_ftl *ftl)
{
	remove_lines(ftl);
	remove_rmap(ftl);
	remove_maptbl(ftl);
	remove_page_meta(ftl);
}

static void conv_init_params(struct convparams *cpp, struct ssdparams *spp)
{
	cpp->op_area_pcent = OP_AREA_PERCENT;
	cpp->gc_thres_lines = 3;
	cpp->gc_thres_lines_high = spp->tlc_tt_lines * 15 / 100;
	cpp->enable_gc_delay = 1;
	cpp->pba_pcent = (int)((1 + cpp->op_area_pcent) * 100);
}

/* ================================================================
 * 네임스페이스 초기화 / 제거
 * SSD_PARTITIONS개의 FTL 생성. PCIe/write_buffer는 0번을 공유.
 * ================================================================ */
void conv_init_namespace(struct nvmev_ns *ns, uint32_t id, uint64_t size,
			 void *mapped_addr, uint32_t cpu_nr_dispatcher)
{
	struct ssdparams spp;
	struct convparams cpp;
	struct conv_ftl *conv_ftls;
	struct ssd *ssd;
	uint32_t i;
	const uint32_t nr_parts = SSD_PARTITIONS;

	ssd_init_params(&spp, size, nr_parts);
	conv_init_params(&cpp, &spp);
	conv_ftls = kmalloc(sizeof(struct conv_ftl) * nr_parts, GFP_KERNEL);

	for (i = 0; i < nr_parts; i++) {
		ssd = kmalloc(sizeof(struct ssd), GFP_KERNEL);
		ssd_init(ssd, &spp, cpu_nr_dispatcher);
		conv_init_ftl(&conv_ftls[i], &cpp, ssd);
	}

	for (i = 1; i < nr_parts; i++) {
		kfree(conv_ftls[i].ssd->pcie->perf_model);
		kfree(conv_ftls[i].ssd->pcie);
		kfree(conv_ftls[i].ssd->write_buffer);
		conv_ftls[i].ssd->pcie = conv_ftls[0].ssd->pcie;
		conv_ftls[i].ssd->write_buffer = conv_ftls[0].ssd->write_buffer;
	}

	ns->id = id;
	ns->csi = NVME_CSI_NVM;
	ns->nr_parts = nr_parts;
	ns->ftls = (void *)conv_ftls;
	ns->size = (uint64_t)((size * 100) / cpp.pba_pcent);
	ns->mapped = mapped_addr;
	ns->proc_io_cmd = conv_proc_nvme_io_cmd;

	NVMEV_INFO("FTL physical=%lld logical=%lld (ratio=%d) gc_mode=%d\n",
		   size, ns->size, cpp.pba_pcent, gc_mode);
}

void conv_remove_namespace(struct nvmev_ns *ns)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	const uint32_t nr_parts = SSD_PARTITIONS;
	uint32_t i;

	for (i = 1; i < nr_parts; i++) {
		conv_ftls[i].ssd->pcie = NULL;
		conv_ftls[i].ssd->write_buffer = NULL;
	}
	for (i = 0; i < nr_parts; i++) {
		conv_remove_ftl(&conv_ftls[i]);
		ssd_remove(conv_ftls[i].ssd);
		kfree(conv_ftls[i].ssd);
	}
	kfree(conv_ftls);
	ns->ftls = NULL;
}

/* ================================================================
 * PPA/LPN 유효성
 * ================================================================ */
static inline bool valid_ppa(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;

	if (ppa->g.ch  < 0 || ppa->g.ch  >= spp->nchs)        return false;
	if (ppa->g.lun < 0 || ppa->g.lun >= spp->luns_per_ch) return false;
	if (ppa->g.pl  < 0 || ppa->g.pl  >= spp->pls_per_lun) return false;
	if (ppa->g.blk < 0 || ppa->g.blk >= spp->blks_per_pl) return false;
	if (ppa->g.pg  < 0 || ppa->g.pg  >= spp->pgs_per_blk) return false;
	return true;
}

static inline bool valid_lpn(struct conv_ftl *ftl, uint64_t lpn)
{
	return lpn < ftl->ssd->sp.tt_pgs;
}

static inline bool mapped_ppa(struct ppa *ppa)
{
	return ppa->ppa != UNMAPPED_PPA;
}

static inline struct line *get_line(struct conv_ftl *ftl, struct ppa *ppa)
{
	return &ftl->lm.lines[ppa->g.blk];
}

/* ================================================================
 *
 *                 페이지 상태 관리
 *   PG_FREE -(write)-> PG_VALID -(overwrite)-> PG_INVALID
 *
 * ================================================================ */

/*
 * 페이지 무효화 (update write 시 구 페이지 대상).
 * 블록/라인 카운터 갱신 + (PQ에 있으면 우선순위 갱신) + full->victim 전이.
 */
static void mark_page_invalid(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct line_mgmt *lm = &ftl->lm;
	struct nand_block *blk;
	struct nand_page *pg;
	struct line *line;
	bool was_full = false;

	pg = get_pg(ftl->ssd, ppa);
	NVMEV_ASSERT(pg->status == PG_VALID);
	pg->status = PG_INVALID;

	blk = get_blk(ftl->ssd, ppa);
	blk->ipc++;
	blk->vpc--;

	line = get_line(ftl, ppa);
	if (line->vpc == spp->pgs_per_line)
		was_full = true;
	line->ipc++;

	/* PQ 우선순위가 vpc이므로 PQ에 있으면 PQ를 통해 갱신해야 heap 유지. */
	if (line->pos)
		pqueue_change_priority(lm->victim_line_pq, line->vpc - 1, line);
	else
		line->vpc--;

	if (was_full) {
		list_del_init(&line->entry);
		lm->full_line_cnt--;
		pqueue_insert(lm->victim_line_pq, line);
		lm->victim_line_cnt++;
	}

	line->last_modified_time = ktime_get_ns();
}

/* 페이지 유효화 (호스트 write / GC copy 시 새 페이지 대상). */
static void mark_page_valid(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct nand_block *blk;
	struct nand_page *pg;
	struct line *line;

	pg = get_pg(ftl->ssd, ppa);
	NVMEV_ASSERT(pg->status == PG_FREE);
	pg->status = PG_VALID;

	blk = get_blk(ftl->ssd, ppa);
	blk->vpc++;

	line = get_line(ftl, ppa);
	line->vpc++;
}

/* 블록 erase: 모든 페이지 FREE로, NAND 레벨 erase_cnt++. */
static void mark_block_free(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct nand_block *blk = get_blk(ftl->ssd, ppa);
	int i;

	for (i = 0; i < spp->pgs_per_blk; i++)
		blk->pg[i].status = PG_FREE;
	blk->ipc = 0;
	blk->vpc = 0;
	blk->erase_cnt++;
}

/* 라인을 free 리스트로 복귀. line->erase_cnt++가 CAT/RL wear scoring의 핵심. */
static void mark_line_free(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct line *line = get_line(ftl, ppa);

	line->ipc = 0;
	line->vpc = 0;
	line->erase_cnt++;

	list_add_tail(&line->entry, &ftl->lm.free_line_list);
	ftl->lm.free_line_cnt++;
}

/* ================================================================
 *
 *                 GC 실행 경로
 *
 * ================================================================ */


/*
 * valid page를 새 위치로 복사 (hot/cold 분기 포함).
 * page_is_hot()으로 gc_wp_hot/gc_wp_cold를 선택해 데이터를 분리한다.
 * -> hot 블록은 빠르게 무효화되어 다음 GC가 효율적, cold 블록은 오래 유효.
 */
static uint64_t gc_write_page(struct conv_ftl *ftl, struct ppa *old_ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	uint64_t lpn = get_rmap_ent(ftl, old_ppa);
	uint64_t now = ktime_get_ns();
	uint32_t wp_type;
	struct ppa new_ppa;

	NVMEV_ASSERT(valid_lpn(ftl, lpn));

	wp_type = page_is_hot(ftl, lpn, now) ? GC_IO_HOT : GC_IO_COLD;
	new_ppa = get_new_page(ftl, wp_type);

	set_maptbl_ent(ftl, lpn, &new_ppa);
	set_rmap_ent(ftl, lpn, &new_ppa);

	mark_page_valid(ftl, &new_ppa);
	ftl->gc_copied_pages++;

	advance_write_pointer(ftl, wp_type);

	if (ftl->cp.enable_gc_delay) {
		struct nand_cmd gcw = {
			.type = GC_IO,
			.cmd = NAND_NOP,
			.stime = 0,
			.interleave_pci_dma = false,
			.ppa = &new_ppa,
		};
		if (last_pg_in_wordline(ftl, &new_ppa)) {
			gcw.cmd = NAND_WRITE;
			gcw.xfer_size = spp->pgsz * spp->pgs_per_oneshotpg;
		}
		ssd_advance_nand(ftl->ssd, &gcw);
	}
	return 0;
}

/* flash page 단위로 valid page를 일괄 읽고 하나씩 복사. */
static void clean_one_flashpg(struct conv_ftl *ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct nand_page *pg;
	int cnt = 0, i;
	struct ppa copy = *ppa;

	for (i = 0; i < spp->pgs_per_flashpg; i++) {
		pg = get_pg(ftl->ssd, &copy);
		NVMEV_ASSERT(pg->status != PG_FREE);
		if (pg->status == PG_VALID)
			cnt++;
		copy.g.pg++;
	}

	copy = *ppa;
	if (cnt <= 0)
		return;

	if (ftl->cp.enable_gc_delay) {
		struct nand_cmd gcr = {
			.type = GC_IO,
			.cmd = NAND_READ,
			.stime = 0,
			.xfer_size = spp->pgsz * cnt,
			.interleave_pci_dma = false,
			.ppa = &copy,
		};
		ssd_advance_nand(ftl->ssd, &gcr);
	}

	for (i = 0; i < spp->pgs_per_flashpg; i++) {
		pg = get_pg(ftl->ssd, &copy);
		if (pg->status == PG_VALID)
			gc_write_page(ftl, &copy);
		copy.g.pg++;
	}
}

/*
 * do_gc() - GC 메인.
 *
 * RL 모드: state 관찰 -> action 선택 -> (α,δ) 적용 -> scored victim.
 * 그 외:   select_fn으로 victim 선택.
 * GC 후 wear-gap 누적을 갱신하고(전 모드), RL이면 reward로 Q를 갱신한다.
 */
static int do_gc(struct conv_ftl *ftl, bool force, victim_select_fn select_fn)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	struct line *victim = NULL;
	struct ppa ppa;
	int flashpg;

	if (gc_mode == GC_MODE_RL) {
		struct rl_config *rl = &ftl->rl;
		uint32_t state = rl_get_state(ftl);
		uint32_t action = rl_select_action(rl, state);

		rl->cur_state = state;
		rl_decode_action(rl, action);
		victim = select_victim_scored(ftl, rl->alpha_level,
					      rl->delta_level);
	} else {
		victim = select_fn(ftl, force);
	}

	if (!victim) {
		ftl->wfc.credits_to_refill = 0;
		return -1;
	}

	ftl->gc_count++;
	ppa.g.blk = victim->id;

	if (gc_mode == GC_MODE_RL)
		ftl->rl.last_victim_ec = victim->erase_cnt;

	/* 회수 공간 = victim의 무효 페이지 수. */
	ftl->wfc.credits_to_refill = victim->ipc;

	for (flashpg = 0; flashpg < spp->flashpgs_per_blk; flashpg++) {
		int ch, lun;

		ppa.g.pg = flashpg * spp->pgs_per_flashpg;
		for (ch = 0; ch < spp->nchs; ch++) {
			for (lun = 0; lun < spp->luns_per_ch; lun++) {
				struct nand_lun *lunp;

				ppa.g.ch = ch;
				ppa.g.lun = lun;
				ppa.g.pl = 0;
				lunp = get_lun(ftl->ssd, &ppa);

				clean_one_flashpg(ftl, &ppa);

				if (flashpg == (spp->flashpgs_per_blk - 1)) {
					mark_block_free(ftl, &ppa);
					if (ftl->cp.enable_gc_delay) {
						struct nand_cmd gce = {
							.type = GC_IO,
							.cmd = NAND_ERASE,
							.stime = 0,
							.interleave_pci_dma = false,
							.ppa = &ppa,
						};
						ssd_advance_nand(ftl->ssd, &gce);
					}
					lunp->gc_endtime = lunp->next_lun_avail_time;
				}
			}
		}
	}

	mark_line_free(ftl, &ppa);

	/* GC당 wear-gap 누적 (전 모드 공통, 평가지표). */
	update_wear_gap(ftl);

	if (gc_mode == GC_MODE_RL) {
		uint32_t new_state = rl_get_state(ftl);
		rl_update(ftl, new_state);
	}

	return 0;
}

/* 공간 부족 시 진입점. gc_mode별로 victim 선택 함수를 골라 do_gc 호출. */
static void foreground_gc(struct conv_ftl *ftl)
{
	if (!should_gc_high(ftl))
		return;

	switch (gc_mode) {
	case GC_MODE_GREEDY:
		do_gc(ftl, true, select_victim_greedy);
		break;
	case GC_MODE_CB:
		do_gc(ftl, true, select_victim_cb);
		break;
	case GC_MODE_CAT:
		do_gc(ftl, true, select_victim_cat);
		break;
	case GC_MODE_RL:
		do_gc(ftl, true, NULL);
		break;
	default:
		do_gc(ftl, true, select_victim_greedy);
		break;
	}
}

/* ================================================================
 *
 *                 NVMe IO 명령 처리
 *
 * ================================================================ */

static bool is_same_flash_page(struct conv_ftl *ftl,
			       struct ppa p1, struct ppa p2)
{
	struct ssdparams *spp = &ftl->ssd->sp;
	return (p1.h.blk_in_ssd == p2.h.blk_in_ssd) &&
	       (p1.g.pg / spp->pgs_per_flashpg == p2.g.pg / spp->pgs_per_flashpg);
}

/*
 * conv_read() - NVMe Read.
 * LPN -> PPA 조회 후, 같은 flash page 읽기를 합쳐 NAND 타이밍 시뮬레이션.
 */
static bool conv_read(struct nvmev_ns *ns, struct nvmev_request *req,
		      struct nvmev_result *ret)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	struct conv_ftl *ftl = &conv_ftls[0];
	struct ssdparams *spp = &ftl->ssd->sp;
	struct nvme_command *cmd = req->cmd;
	uint64_t lba = cmd->rw.slba;
	uint64_t nr_lba = cmd->rw.length + 1;
	uint64_t start_lpn = lba / spp->secs_per_pg;
	uint64_t end_lpn = (lba + nr_lba - 1) / spp->secs_per_pg;
	uint64_t lpn, nsecs_start = req->nsecs_start;
	uint64_t nsecs_completed, nsecs_latest = nsecs_start;
	uint32_t xfer_size, i, nr_parts = ns->nr_parts;
	struct ppa prev_ppa;
	struct nand_cmd srd = {
		.type = USER_IO,
		.cmd = NAND_READ,
		.stime = nsecs_start,
		.interleave_pci_dma = true,
	};

	if ((end_lpn / nr_parts) >= spp->tt_pgs) {
		ret->status = NVME_SC_LBA_RANGE | NVME_SC_DNR;
		return false;
	}

	srd.stime += (LBA_TO_BYTE(nr_lba) <= KB(4) * nr_parts) ?
		     spp->fw_4kb_rd_lat : spp->fw_rd_lat;

	for (i = 0; (i < nr_parts) && (start_lpn <= end_lpn); i++, start_lpn++) {
		ftl = &conv_ftls[start_lpn % nr_parts];
		xfer_size = 0;
		prev_ppa = get_maptbl_ent(ftl, start_lpn / nr_parts);

		for (lpn = start_lpn; lpn <= end_lpn; lpn += nr_parts) {
			struct ppa cur = get_maptbl_ent(ftl, lpn / nr_parts);

			if (!mapped_ppa(&cur) || !valid_ppa(ftl, &cur))
				continue;

			if (mapped_ppa(&prev_ppa) &&
			    is_same_flash_page(ftl, cur, prev_ppa)) {
				xfer_size += spp->pgsz;
				continue;
			}

			if (xfer_size > 0) {
				srd.xfer_size = xfer_size;
				srd.ppa = &prev_ppa;
				nsecs_completed = ssd_advance_nand(ftl->ssd, &srd);
				nsecs_latest = max(nsecs_completed, nsecs_latest);
			}

			xfer_size = spp->pgsz;
			prev_ppa = cur;
		}

		if (xfer_size > 0) {
			srd.xfer_size = xfer_size;
			srd.ppa = &prev_ppa;
			nsecs_completed = ssd_advance_nand(ftl->ssd, &srd);
			nsecs_latest = max(nsecs_completed, nsecs_latest);
		}
	}

	ret->nsecs_target = nsecs_latest;
	ret->status = NVME_SC_SUCCESS;
	return true;
}

/*
 * conv_write() - NVMe Write.
 * LPN별로: 구 페이지 무효화 -> 새 PPA 할당/유효화 -> page_meta 갱신
 * -> avg_hot_degree EMA -> wp 전진 -> (워드라인 끝) NAND WRITE
 * -> 크레딧 소모/리필(필요 시 GC).
 *
 * page_meta(update_cnt, last_write_time)는 이후 GC의 hot/cold 판별 기초.
 */
static bool conv_write(struct nvmev_ns *ns, struct nvmev_request *req,
		       struct nvmev_result *ret)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	struct conv_ftl *ftl = &conv_ftls[0];
	struct ssdparams *spp = &ftl->ssd->sp;
	struct buffer *wbuf = ftl->ssd->write_buffer;
	struct nvme_command *cmd = req->cmd;
	uint64_t lba = cmd->rw.slba;
	uint64_t nr_lba = cmd->rw.length + 1;
	uint64_t start_lpn = lba / spp->secs_per_pg;
	uint64_t end_lpn = (lba + nr_lba - 1) / spp->secs_per_pg;
	uint64_t lpn, nsecs_latest, nsecs_xfer;
	uint32_t nr_parts = ns->nr_parts, alloc;
	struct nand_cmd swr = {
		.type = USER_IO,
		.cmd = NAND_WRITE,
		.interleave_pci_dma = false,
		.xfer_size = spp->pgsz * spp->pgs_per_oneshotpg,
	};

	if ((end_lpn / nr_parts) >= spp->tt_pgs) {
		ret->status = NVME_SC_LBA_RANGE | NVME_SC_DNR;
		return false;
	}

	alloc = buffer_allocate(wbuf, LBA_TO_BYTE(nr_lba));
	if (alloc < LBA_TO_BYTE(nr_lba)) {
		ret->status = NVME_SC_INTERNAL | NVME_SC_DNR;
		return false;
	}

	nsecs_latest = ssd_advance_write_buffer(ftl->ssd, req->nsecs_start,
						LBA_TO_BYTE(nr_lba));
	nsecs_xfer = nsecs_latest;
	swr.stime = nsecs_latest;

	for (lpn = start_lpn; lpn <= end_lpn; lpn++) {
		uint64_t local_lpn, nsecs_done = 0;
		struct ppa ppa;
		struct page_meta *pm;
		uint64_t degree;

		ftl = &conv_ftls[lpn % nr_parts];
		local_lpn = lpn / nr_parts;

		/* update write면 구 페이지 무효화. */
		ppa = get_maptbl_ent(ftl, local_lpn);
		if (mapped_ppa(&ppa)) {
			mark_page_invalid(ftl, &ppa);
			set_rmap_ent(ftl, INVALID_LPN, &ppa);
		}

		/* 새 PPA (호스트 쓰기 = USER_IO). */
		ppa = get_new_page(ftl, USER_IO);
		set_maptbl_ent(ftl, local_lpn, &ppa);
		set_rmap_ent(ftl, local_lpn, &ppa);
		mark_page_valid(ftl, &ppa);
		ftl->host_written_pages++;

		pm = &ftl->page_meta[local_lpn];

		/* RL: hot write 통계 (pm 갱신 전에 판정). */
		if (gc_mode == GC_MODE_RL) {
			uint64_t cur_time = ktime_get_ns();
			bool repeated = (pm->update_cnt > 0);
			bool recent = (cur_time > pm->last_write_time) &&
				      ((cur_time - pm->last_write_time) < TH_HOT);

			if (repeated && recent)
				ftl->rl.window_hot++;
			ftl->rl.window_total++;

			if (ftl->rl.window_total >= spp->pgs_per_line) {
				ftl->rl.prev_hot_pct =
					ftl->rl.window_hot * 100 /
					ftl->rl.window_total;
				ftl->rl.window_hot = 0;
				ftl->rl.window_total = 0;
			}
		}

		pm->update_cnt++;
		pm->last_write_time = ktime_get_ns();

		/* avg_hot_degree EMA (x16 고정소수점). */
		degree = calc_hot_degree(pm, pm->last_write_time);
		ftl->avg_hot_degree = (ftl->avg_hot_degree * 15 + degree * 16) / 16;

		advance_write_pointer(ftl, USER_IO);

		if (last_pg_in_wordline(ftl, &ppa)) {
			swr.ppa = &ppa;
			nsecs_done = ssd_advance_nand(ftl->ssd, &swr);
			nsecs_latest = max(nsecs_done, nsecs_latest);
			schedule_internal_operation(req->sq_id, nsecs_done, wbuf,
						    spp->pgs_per_oneshotpg * spp->pgsz);
		}

		consume_write_credit(ftl);
		check_and_refill_write_credit(ftl);
	}

	if ((cmd->rw.control & NVME_RW_FUA) || !spp->write_early_completion)
		ret->nsecs_target = nsecs_latest;
	else
		ret->nsecs_target = nsecs_xfer;

	ret->status = NVME_SC_SUCCESS;
	return true;
}

/*
 * conv_flush() - Flush + 모드 비교용 통계 출력 (dmesg).
 *
 * 전 파티션을 집계해 다음을 출력한다:
 *   [PERF]  WAF, copy_ratio (useless migration 지표)
 *   [GC]    gc_count, GC당 평균 copy
 *   [Wear]  avg/min/max/range/std/CoV
 *   [WearGap] GC당 wear-gap(max-min) 누적 증가량  <- 핵심 비교지표
 *   [RL]    episodes, avg_reward, p0 (eps/alpha/delta)
 *
 * WearGap: 매 GC마다 (max-min)이 직전 대비 얼마나 벌어졌는지의 누적/평균.
 * avg가 작을수록(또는 음수일수록) wear가 덜 벌어지는 모드.
 */
static void conv_flush(struct nvmev_ns *ns, struct nvmev_request *req,
		       struct nvmev_result *ret)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	struct ssdparams *spp;
	uint64_t start, latest;
	uint64_t total_gc = 0, total_cp = 0, total_host = 0;
	uint64_t total_erases = 0;
	uint64_t ec_sum = 0, ec_sqsum = 0;
	uint64_t total_lines = 0;
	uint32_t ec_max = 0, ec_min = UINT_MAX;
	uint64_t waf_x1000 = 1000;
	uint64_t copy_ratio_x1000 = 0;
	uint64_t ec_avg = 0, ec_std = 0, ec_cov_x1000 = 0;
	uint32_t ec_range = 0;
	uint64_t rl_episodes = 0;
	int64_t  rl_reward_sum = 0;
	int64_t  wg_accum = 0;
	uint64_t wg_samples = 0;
	uint32_t i, j;

	if (ns->nr_parts == 0) {
		ret->status = NVME_SC_SUCCESS;
		ret->nsecs_target = local_clock();
		return;
	}

	spp = &conv_ftls[0].ssd->sp;
	start = local_clock();
	latest = start;

	for (i = 0; i < ns->nr_parts; i++) {
		struct conv_ftl *ftl = &conv_ftls[i];
		struct line_mgmt *lm = &ftl->lm;

		latest = max(latest, ssd_next_idle_time(ftl->ssd));
		total_gc   += ftl->gc_count;
		total_cp   += ftl->gc_copied_pages;
		total_host += ftl->host_written_pages;

		for (j = 0; j < lm->tt_lines; j++) {
			uint32_t ec = lm->lines[j].erase_cnt;

			ec_sum       += ec;
			ec_sqsum     += (uint64_t)ec * ec;
			total_erases += ec;
			if (ec > ec_max) ec_max = ec;
			if (ec < ec_min) ec_min = ec;
		}
		total_lines += lm->tt_lines;

		rl_episodes   += ftl->rl.total_episodes;
		rl_reward_sum += ftl->rl.total_reward;

		wg_accum   += ftl->wgs.accum_diff;
		wg_samples += ftl->wgs.samples;
	}

	/* WAF = (host + gc_copy) / host */
	if (total_host > 0)
		waf_x1000 = (total_host + total_cp) * 1000 / total_host;

	/* copy_ratio = gc_copy / (erase로 처리된 총 페이지). 낮을수록 효율적. */
	{
		uint64_t erased_pgs = total_erases * (uint64_t)spp->pgs_per_line;

		if (erased_pgs > 0)
			copy_ratio_x1000 = total_cp * 1000 / erased_pgs;
	}

	/* Wear 분산/CoV. var = E[X^2] - E[X]^2. */
	if (total_lines > 0) {
		uint64_t avg_sq, mean_sq, var;

		ec_avg = ec_sum / total_lines;
		ec_range = (ec_min == UINT_MAX) ? 0 : (ec_max - ec_min);

		avg_sq  = ec_sqsum / total_lines;
		mean_sq = ec_avg * ec_avg;
		var     = (avg_sq > mean_sq) ? (avg_sq - mean_sq) : 0;
		ec_std  = isqrt_u64(var);

		if (ec_avg > 0)
			ec_cov_x1000 = ec_std * 1000 / ec_avg;
	} else {
		ec_min = 0;
	}

	printk(KERN_INFO
	       "NVMeVirt: [FLUSH] gc_mode=%d gc=%llu copied=%llu avg=%llu "
	       "host=%llu erases=%llu WAF=%llu.%03llu copy_ratio=%llu.%03llu\n",
	       gc_mode, total_gc, total_cp,
	       total_gc > 0 ? total_cp / total_gc : 0,
	       total_host, total_erases,
	       waf_x1000 / 1000, waf_x1000 % 1000,
	       copy_ratio_x1000 / 1000, copy_ratio_x1000 % 1000);

	printk(KERN_INFO
	       "NVMeVirt: [Wear] avg=%llu min=%u max=%u "
	       "range=%u std=%llu CoV=%llu.%03llu lines=%llu\n",
	       ec_avg, ec_min == UINT_MAX ? 0 : ec_min, ec_max,
	       ec_range, ec_std,
	       ec_cov_x1000 / 1000, ec_cov_x1000 % 1000,
	       total_lines);

	/*
	 * [WearGap] GC당 wear-gap(max-min) 누적 증가량.
	 *   total   = 측정 구간 동안 range가 순증가한 총량 (부호 있음)
	 *   samples = diff를 누적한 GC 횟수
	 *   per_gc  = total / samples (x1000 고정소수점, 부호 보존)
	 * 모드 간 비교: per_gc가 작을수록 GC마다 wear가 덜 벌어짐.
	 */
	{
		int64_t per_gc_x1000 = 0;
		int64_t whole, frac;

		if (wg_samples > 0)
			per_gc_x1000 = wg_accum * 1000 / (int64_t)wg_samples;

		whole = per_gc_x1000 / 1000;
		frac  = per_gc_x1000 % 1000;
		if (frac < 0) frac = -frac;

		printk(KERN_INFO
		       "NVMeVirt: [WearGap] total_diff=%lld samples=%llu "
		       "per_gc=%lld.%03lld\n",
		       wg_accum, wg_samples, whole, frac);
	}

	if (gc_mode == GC_MODE_RL) {
		int64_t avg_r = (rl_episodes > 0) ?
			(rl_reward_sum / (int64_t)rl_episodes) : 0;

		printk(KERN_INFO
		       "NVMeVirt: [RL] episodes=%llu avg_reward=%lld "
		       "p0_eps=%u p0_alpha=%u p0_delta=%u\n",
		       rl_episodes, avg_r,
		       conv_ftls[0].rl.epsilon,
		       conv_ftls[0].rl.alpha_level,
		       conv_ftls[0].rl.delta_level);
	}

	ret->status = NVME_SC_SUCCESS;
	ret->nsecs_target = latest;
}

/* NVMe IO 디스패처. conv_init_namespace에서 ns->proc_io_cmd로 등록됨. */
bool conv_proc_nvme_io_cmd(struct nvmev_ns *ns, struct nvmev_request *req,
			   struct nvmev_result *ret)
{
	struct nvme_command *cmd = req->cmd;

	NVMEV_ASSERT(ns->csi == NVME_CSI_NVM);

	switch (cmd->common.opcode) {
	case nvme_cmd_write:
		if (!conv_write(ns, req, ret)) return false;
		break;
	case nvme_cmd_read:
		if (!conv_read(ns, req, ret)) return false;
		break;
	case nvme_cmd_flush:
		conv_flush(ns, req, ret);
		break;
	default:
		NVMEV_ERROR("%s: unimplemented: %s (0x%x)\n", __func__,
			    nvme_opcode_string(cmd->common.opcode),
			    cmd->common.opcode);
		break;
	}
	return true;
}