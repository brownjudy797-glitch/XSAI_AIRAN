#!/bin/bash
# ============================================================================
#  add-oai-timer.sh —— OAI 计时器一键添加（纯 Shell，零依赖）
#
#  把《OAI 计时器添加指南》里的手工步骤工具化：一条命令加上 gNB FEP 的
#  "投递器 / 任务 / 符号" 三层耗时统计。
#
#  三个预设（均已在 K3 上验证）：
#     rx-symbol   RX 单符号 DFT       → symbol_dft (RX)          262.9 µs
#     tx-symbol   TX 单符号 IDFT      → symbol_idft (TX)         267.5 µs
#     rx-task     RX 任务级（3符号）  → feprx_task (3 symbols)   773.3 µs
#
#  用法
#   ----
#     ./add-oai-timer.sh --list                   # 看有哪些预设
#     ./add-oai-timer.sh --check                  # 检查源码能否匹配（不改文件）
#     ./add-oai-timer.sh --verify                 # 看当前已加了哪些
#     ./add-oai-timer.sh --preset all             # 预览改动（默认 dry-run）
#     ./add-oai-timer.sh --preset all --apply     # 真正应用
#     ./add-oai-timer.sh --preset all --apply --build   # 应用 + 编译
#     ./add-oai-timer.sh --rollback               # 列出备份
#     ./add-oai-timer.sh --rollback <时间戳>       # 回滚
#     OAI_DIR=/path/to/oai ./add-oai-timer.sh ... # 手动指定源码目录
#
#  这个脚本要放在哪里？
#   -------------------
#   本脚本不会修改自己所在的目录，它只改 OAI 源码里的 3 个文件：
#       openair1/PHY/defs_RU.h
#       openair1/SCHED_NR/nr_ru_procedures.c
#       executables/nr-gnb.c
#   所以放哪里都行，只要能「找到」OAI 源码：
#
#     [推荐] 放在项目的 scripts/ 下（自动向上找 ../ext/openairinterface5g）
#              ~/sionna-rk/scripts/add-oai-timer.sh
#
#     [也可以] 放在任意目录，用 --oai-dir 指定源码位置
#              ~/add-oai-timer.sh --oai-dir ~/sionna-rk/ext/openairinterface5g --check
#
#   自动探测顺序（都不中时会提示用 --oai-dir）：
#       脚本所在目录/../ext/openairinterface5g
#       脚本所在目录/ext/openairinterface5g
#       脚本所在目录/openairinterface5g
#       ~/sionna-rk/ext/openairinterface5g
#       ~/openairinterface5g
#
#   提示：别把脚本放进 OAI 源码目录内（会污染 git status）。
#
#  安全设计
#   --------
#     * 默认 dry-run：不加 --apply 绝不写文件
#     * 自动备份到 ~/.oai-timer-backups/<时间戳>/
#     * 幂等：已存在的计时器自动跳过（按精确 marker 判断）
#     * 锚点唯一性检查：重复匹配则报错中止（防误改）
#     * 原子性：任一编辑失败 → 自动恢复本次已改的文件
# ============================================================================

set -uo pipefail

BACKUP_ROOT="${HOME}/.oai-timer-backups"
OAI_DIR="${OAI_DIR:-}"
PRESET=""
DO_APPLY=0
DO_BUILD=0
RB_TS=""
TS=""

TX_FILES=(
    "openair1/PHY/defs_RU.h"
    "openair1/SCHED_NR/nr_ru_procedures.c"
    "executables/nr-gnb.c"
    # ldpc-prof 预设涉及的文件（前 3 个 FEP 预设不碰它们）
    "openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_decoder.c"
    "openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"
    "openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_interface.h"
    "openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_segment/nrLDPC_coding_segment_decoder.c"
    "openair1/PHY/defs_gNB.h"
    "openair1/PHY/NR_TRANSPORT/nr_ulsch_decoding.c"
)

if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; C=""; D=""; N=""
fi

ok()   { echo "  ${G}✅${N} $*"; }
info() { echo "  $*"; }
warn() { echo "  ${Y}⚠️ ${N} $*"; }
err()  { echo "  ${R}❌${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 文本编辑工具
# ---------------------------------------------------------------------------

# 在「匹配正则的最后一行」之后插入若干行
# 用法: ins_after <file> <ereg> <line> [line...]
ins_after() {
    local file="$1" pat="$2"; shift 2
    local n; n=$(grep -nE "$pat" "$file" | tail -1 | cut -d: -f1)
    [ -z "$n" ] && { err "锚点未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    local lf; lf=$(mktemp); printf '%s\n' "$@" > "$lf"
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v lf="$lf" '
        { print }
        NR == n { while ((getline l < lf) > 0) print l }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    rm -f "$lf"
}

# 把唯一匹配某正则的整行替换掉
# 用法: sub_line <file> <ereg> <newline>
# 注意：不用 `awk -v pat=` 传正则 —— awk 会吃掉反斜杠转义（如 `\(` 变 `(`）。
#       改为先由 grep 定位行号，再让 awk 按 NR 替换。
sub_line() {
    local file="$1" pat="$2" new="$3"
    local cnt; cnt=$(grep -cE "$pat" "$file")
    [ "$cnt" -eq 0 ] && { err "待替换行未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    [ "$cnt" -gt 1 ] && { err "/$pat/ 匹配 $cnt 行（要求唯一）于 $(basename "$file")"; return 1; }
    local n; n=$(grep -nE "$pat" "$file" | head -1 | cut -d: -f1)
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v new="$new" 'NR == n { print new; next } { print }' "$file" > "$tmp" \
        && mv "$tmp" "$file"
}

# 在「第 n 行」之前插入若干行
# 用法: ins_before_n <file> <n> <line> [line...]
ins_before_n() {
    local file="$1" n="$2"; shift 2
    local lf; lf=$(mktemp); printf '%s\n' "$@" > "$lf"
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v lf="$lf" '
        NR == n { while ((getline l < lf) > 0) print l }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    rm -f "$lf"
}

# 在「匹配正则的第一行」之前插入若干行
# 用法: ins_before <file> <ereg> <line> [line...]
ins_before() {
    local file="$1" pat="$2"; shift 2
    local n; n=$(grep -nE "$pat" "$file" | head -1 | cut -d: -f1)
    [ -z "$n" ] && { err "锚点未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    ins_before_n "$file" "$n" "$@"
}

has() { grep -qF "$2" "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 三个预设
#
# 每个 preset 函数签名：preset_xxx <root>       root = OAI 源码根目录
# 返回 0 = 成功（含跳过），非 0 = 失败
# ---------------------------------------------------------------------------

F_DEFS_REL="openair1/PHY/defs_RU.h"
F_PROC_REL="openair1/SCHED_NR/nr_ru_procedures.c"
F_GNB_REL="executables/nr-gnb.c"
F_DEFS_GNB_REL="openair1/PHY/defs_gNB.h"

# ---- ① RX 单符号 DFT ------------------------------------------------------
preset_rx_symbol() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段
    if has "$fdef" "time_stats_t symbol_dft_stats;"; then
        echo "      [rx-symbol] defs_RU.h：已存在，跳过"
    else
        ins_after "$fdef" '^  time_stats_t ofdm_demod_stats;$' \
            '  /// Timing statistics (single-symbol DFT, diagnostic)' \
            '  time_stats_t symbol_dft_stats;' || return 1
    fi

    # 计时点：符号循环
    if has "$fproc" "start_meas(&ru->symbol_dft_stats)"; then
        echo "      [rx-symbol] nr_ru_procedures.c：已存在，跳过"
    else
        # 1) for 行加花括号（原为单语句循环）
        sub_line "$fproc" '^  for \(int l = startSymbol; l <= endSymbol; l\+\+\) *$' \
            '  for (int l = startSymbol; l <= endSymbol; l++) {' || return 1
        # 2) 调用之前：start
        ins_before "$fproc" '^      nr_slot_fep_ul\(fp,$' \
            '      // 只对符号 0 计时：拆分后仅 p=0 那份的 startSymbol==0，' \
            '      // 保证同一时刻只有一个 worker 写该 time_stats_t（避免多线程竞态）' \
            '      if (l == 0)' \
            '        start_meas(&ru->symbol_dft_stats);' || return 1
        # 3) 调用之后：stop + 闭合花括号
        ins_after "$fproc" '^                     ru->N_TA_offset\);$' \
            '      if (l == 0)' \
            '        stop_meas(&ru->symbol_dft_stats);' \
            '  }' || return 1
    fi

    # 打印
    if has "$fgnb" '"symbol_dft (RX)"'; then
        echo "      [rx-symbol] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '  output += print_meas_log(&ru->symbol_dft_stats, "symbol_dft (RX)", NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ② TX 单符号 IDFT -----------------------------------------------------
preset_tx_symbol() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段（插在 ofdm_mod_stats 之前）
    if has "$fdef" "time_stats_t symbol_idft_stats;"; then
        echo "      [tx-symbol] defs_RU.h：已存在，跳过"
    else
        local n; n=$(grep -n '^  time_stats_t ofdm_mod_stats;$' "$fdef" | cut -d: -f1)
        [ -z "$n" ] && { err "[tx-symbol] defs_RU.h 里找不到 ofdm_mod_stats"; return 1; }
        # 若上一行是该字段的说明注释，则插到注释之前，避免把注释与新字段隔开
        local at="$n"
        if [ "$n" -gt 1 ] && sed -n "$((n-1))p" "$fdef" | grep -qE '^  ///'; then
            at=$((n-1))
        fi
        ins_before_n "$fdef" "$at" \
            '  /// Timing statistics (single-symbol IDFT, diagnostic)' \
            '  time_stats_t symbol_idft_stats;' || return 1
    fi

    # 计时点：符号 0 那次 PHY_ofdm_mod 调用（用状态机精确定位，避免误匹配）
    if has "$fproc" "start_meas(&ru->symbol_idft_stats)"; then
        echo "      [tx-symbol] nr_ru_procedures.c：已存在，跳过"
    else
        local tmp; tmp=$(mktemp)
        awk '
            # 武装：遇到「符号 0 用长 CP」的条件行
            /\/\/ case where first symbol in slot has longer prefix/ { armed = 1 }
            # 命中：紧接着的 PHY_ofdm_mod(slot_offsetF, ...) —— 即符号 0 那次调用
            armed && /PHY_ofdm_mod\(&ru->common\.txdataF_BF\[aa\]\[slot_offsetF\],/ {
                print "        // 只对符号 0 计时：aa==0 保证同一时刻只有一个 worker 写该 time_stats_t（避免多线程竞态）"
                print "        if (aa == 0)"
                print "          start_meas(&ru->symbol_idft_stats);"
                armed = 0; inblk = 1
            }
            { print }
            # 该次调用结束（第一次遇到 CYCLIC_PREFIX); ）
            inblk && /CYCLIC_PREFIX\);/ {
                print "        if (aa == 0)"
                print "          stop_meas(&ru->symbol_idft_stats);"
                inblk = 0
            }
        ' "$fproc" > "$tmp" && mv "$tmp" "$fproc"
        # 校验确实插进去了
        has "$fproc" "start_meas(&ru->symbol_idft_stats)" || {
            err "[tx-symbol] nr_ru_procedures.c 插入失败（锚点模式未命中）"; return 1; }
    fi

    # 打印
    if has "$fgnb" '"symbol_idft (TX)"'; then
        echo "      [tx-symbol] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->txdataF_copy_stats, "txdataF_copy"' \
            '    output += print_meas_log(&ru->symbol_idft_stats, "symbol_idft (TX)", NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ③ RX 任务级（3 符号）------------------------------------------------
preset_rx_task() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段
    if has "$fdef" "time_stats_t feprx_task_stats;"; then
        echo "      [rx-task] defs_RU.h：已存在，跳过"
    else
        ins_after "$fdef" '^  time_stats_t ofdm_demod_stats;$' \
            '  /// Timing statistics (RX FEP task, 3 symbols, diagnostic)' \
            '  time_stats_t feprx_task_stats;' || return 1
    fi

    # 计时点：包住整个符号循环
    if has "$fproc" "start_meas(&ru->feprx_task_stats)"; then
        echo "      [rx-task] nr_ru_procedures.c：已存在，跳过"
    else
        ins_after "$fproc" '^  int offset = \(slot % RU_RX_SLOT_DEPTH\)' \
            '  // 只对 p=0 那份任务计时（覆盖整个符号循环）：aid/beam/startSymbol 都是函数参数，' \
            '  // 天然只有一个 worker 满足条件（与 TX 的 aa==0 && first_symbol==0 完全对称）' \
            '  if (aid == 0 && beam == 0 && startSymbol == 0)' \
            '    start_meas(&ru->feprx_task_stats);' || return 1
        ins_before "$fproc" 'VCD_SIGNAL_DUMPER_FUNCTIONS_PHY_PROCEDURES_RU_FEPRX\+aid, 0\);$' \
            '  if (aid == 0 && beam == 0 && startSymbol == 0)' \
            '    stop_meas(&ru->feprx_task_stats);' || return 1
    fi

    # 打印
    if has "$fgnb" '"feprx_task (3 symbols)"'; then
        echo "      [rx-task] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '  output += print_meas_log(&ru->feprx_task_stats, "feprx_task (3 symbols)", NULL, NULL, output, end - output);' || return 1
    fi
}

# 预设名 → 函数
# ---- ④ LDPC 译码内部 11 项细分（ldpc-prof）----------------------------------
# 实测（run23）：cnProc 占 LDPC 的 57.2%；平均迭代 3 轮（进度表 §31）
# ★★ 这是唯一一个改了「gNB/UE 共用头文件」的预设 —— 应用后必须同时重编译两个二进制
F_LDPC_DEC_REL="openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_decoder.c"
F_LDPC_TYPES_REL="openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"
F_LDPC_IFACE_REL="openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_interface.h"
F_LDPC_SEG_REL="openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_segment/nrLDPC_coding_segment_decoder.c"
F_ULSCH_REL="openair1/PHY/NR_TRANSPORT/nr_ulsch_decoding.c"

preset_ldpc_prof() {
    local root="$1"
    local fdec="$root/$F_LDPC_DEC_REL"     ftypes="$root/$F_LDPC_TYPES_REL"
    local fiface="$root/$F_LDPC_IFACE_REL" fseg="$root/$F_LDPC_SEG_REL"
    local fgnbdef="$root/$F_DEFS_GNB_REL"  fulsch="$root/$F_ULSCH_REL"
    local fgnb="$root/$F_GNB_REL"

    # ① 打开宏（原本被定义为「空」，会禁用全部 32 处计时点）
    if has "$fdec" "【OAI-LDPC-PROF】原为「空定义」"; then
        echo "      [ldpc-prof] nrLDPC_decoder.c：已存在，跳过"
    else
        sub_line "$fdec" '^//#define NR_LDPC_PROFILER_DETAIL\(a\) a$' \
            '#define NR_LDPC_PROFILER_DETAIL(a) a' || return 1
        sub_line "$fdec" '^#define NR_LDPC_PROFILER_DETAIL\(a\)$' \
            '//#define NR_LDPC_PROFILER_DETAIL(a)   // 【OAI-LDPC-PROF】原为「空定义」，会禁用全部 32 处细分计时点' || return 1
    fi

    # ② 11 项合并辅助函数（放在 #ifndef CODEGEN 内 → 锚在结构体尾部）
    if has "$ftypes" "merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst"; then
        echo "      [ldpc-prof] nrLDPC_types.h：已存在，跳过"
    else
        ins_after "$ftypes" '^} t_nrLDPC_time_stats;$' \
            '' \
            '/**' \
            '   【OAI-LDPC-PROF】把一组 LDPC 细分统计合并到另一组。' \
            '   语义与 merge_meas() 一致：trials / diff / diff_square 累加，max 取较大者。' \
            '   用途：逐码块的统计 → gNB 级汇总。' \
            ' */' \
            'static inline void merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst, const t_nrLDPC_time_stats *src)' \
            '{' \
            '    merge_meas(&dst->llr2llrProcBuf, &src->llr2llrProcBuf);' \
            '    merge_meas(&dst->llr2CnProcBuf,  &src->llr2CnProcBuf);' \
            '    merge_meas(&dst->cnProc,         &src->cnProc);' \
            '    merge_meas(&dst->cnProcPc,       &src->cnProcPc);' \
            '    merge_meas(&dst->bnProcPc,       &src->bnProcPc);' \
            '    merge_meas(&dst->bnProc,         &src->bnProc);' \
            '    merge_meas(&dst->cn2bnProcBuf,   &src->cn2bnProcBuf);' \
            '    merge_meas(&dst->bn2cnProcBuf,   &src->bn2cnProcBuf);' \
            '    merge_meas(&dst->llrRes2llrOut,  &src->llrRes2llrOut);' \
            '    merge_meas(&dst->llr2bit,        &src->llr2bit);' \
            '    merge_meas(&dst->total,          &src->total);' \
            '}' || return 1
    fi

    # ③a 显式 include（防循环 include 时类型不可见）
    if has "$fiface" 'PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"'; then
        echo "      [ldpc-prof] nrLDPC_coding_interface.h（include）：已存在，跳过"
    else
        ins_after "$fiface" '^#include "PHY/defs_gNB.h"$' \
            '// 【OAI-LDPC-PROF】本文件用到 t_nrLDPC_time_stats。与 defs_gNB.h 存在循环 include，' \
            '// 故显式包含，保证该类型在任何包含顺序下都可见。' \
            '#include "PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"' || return 1
    fi

    # ③b 段参数加「指针」（★ 不能内嵌 528 字节）
    if has "$fiface" 't_nrLDPC_time_stats *ldpc_detail;'; then
        echo "      [ldpc-prof] nrLDPC_coding_interface.h（字段）：已存在，跳过"
    else
        ins_before "$fiface" '^} nrLDPC_segment_decoding_parameters_t;$' \
            '  /// 【OAI-LDPC-PROF】指向"LDPC 译码内部细分统计"的存储槽（cnProc/bnProc/total 等 11 项）' \
            '  /// ★ 这里用「指针」而不是内嵌结构体：本结构体 gNB/UE 共用，UE 侧是栈上变长数组' \
            '  ///   （segments[nb_dlsch][max_num_segments]），内嵌 528 字节会撑大该数组并踩坏相邻' \
            '  ///   的调度参数（实测导致 UE 断言崩溃）。用指针只增 8 字节；为 NULL 时表示不采集。' \
            '  t_nrLDPC_time_stats *ldpc_detail;' || return 1
    fi

    # ④a 任务参数加指针
    if has "$fseg" 't_nrLDPC_time_stats *p_ldpc_detail;'; then
        echo "      [ldpc-prof] segment_decoder.c（字段）：已存在，跳过"
    else
        ins_before "$fseg" '^} nrLDPC_decoding_parameters_t;$' \
            '  /// 【OAI-LDPC-PROF】指向本 segment 的细分统计存储槽（由 prepare 阶段接线；可为 NULL）' \
            '  t_nrLDPC_time_stats *p_ldpc_detail;' || return 1
    fi

    # ④b 把「收集到局部变量」改成「写进所属 segment 的存储槽」
    if has "$fseg" 'p_procTime = rdata->p_ldpc_detail'; then
        echo "      [ldpc-prof] segment_decoder.c（收集）：已存在，跳过"
    else
        ins_before "$fseg" '^  t_nrLDPC_time_stats procTime = \{0\};$' \
            '  // 【OAI-LDPC-PROF】原本用局部变量收集细分计时，函数返回即丢弃，数据永远看不到。' \
            '  // 现改为写入「所属 segment 的存储槽」——每 segment 只被一个线程写，无竞态。' \
            '  // 若未接线（p_ldpc_detail == NULL，例如 UE 侧），退回局部变量：不影响功能，只是不采集。' || return 1
        sub_line "$fseg" '^  t_nrLDPC_time_stats procTime = \{0\};$' \
            '  t_nrLDPC_time_stats procTime_fallback = {0};' || return 1
        sub_line "$fseg" '^  t_nrLDPC_time_stats \*p_procTime = &procTime;$' \
            '  t_nrLDPC_time_stats *p_procTime = rdata->p_ldpc_detail ? rdata->p_ldpc_detail : &procTime_fallback;' || return 1
    fi

    # ④c 接线（取「指针值」，不是取地址）
    if has "$fseg" 'rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters'; then
        echo "      [ldpc-prof] segment_decoder.c（接线）：已存在，跳过"
    else
        ins_after "$fseg" '^    rdata->p_ts_ldpc_decode = &nrLDPC_TB_decoding_parameters->segments\[r\]\.ts_ldpc_decode;$' \
            '    // 【OAI-LDPC-PROF】接线：这里取的是「指针值」——存储由调用者（gNB）分配；' \
            '    // 为 NULL 时该 segment 不采集细分数据（UE 侧即走此路径，零开销）' \
            '    rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters->segments[r].ldpc_detail;' || return 1
    fi

    # ⑤ gNB 级汇总字段
    if has "$fgnbdef" 't_nrLDPC_time_stats ldpc_detail;'; then
        echo "      [ldpc-prof] defs_gNB.h：已存在，跳过"
    else
        ins_after "$fgnbdef" '^  time_stats_t ts_ldpc_decode;$' \
            '  /// 【OAI-LDPC-PROF】LDPC 译码内部细分统计的 gNB 级汇总' \
            '  /// （cnProc / bnProc / 缓冲转换 / total 等 11 项，由 nr_ulsch_decoding.c 逐码块合并而来）' \
            '  t_nrLDPC_time_stats ldpc_detail;' || return 1
    fi

    # ⑥a 静态存储（★ 不能在栈上）
    if has "$fulsch" 'static t_nrLDPC_time_stats ldpc_detail_store'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（存储）：已存在，跳过"
    else
        ins_after "$fulsch" '^  memset\(segments, 0, sizeof\(segments\)\);$' \
            '' \
            '  // 【OAI-LDPC-PROF】LDPC 译码细分统计的存储槽。' \
            '  // ★ 用 static（不在栈上）：上面 segments[] 是栈上变长数组，若把 528 字节的统计内嵌进去' \
            '  //   会大幅撑大 VLA —— UE 侧正是因此崩溃。这里改为「结构体里只放指针 + 存储单独放」。' \
            '  // ★ 用 static 是安全的：本函数由 L1 RX 线程串行调用（每个 slot 一次），无并发写。' \
            '  #define OAI_LDPC_DETAIL_MAX_PUSCH 8' \
            '  #define OAI_LDPC_DETAIL_MAX_SEG   32' \
            '  static t_nrLDPC_time_stats ldpc_detail_store[OAI_LDPC_DETAIL_MAX_PUSCH][OAI_LDPC_DETAIL_MAX_SEG];' || return 1
    fi

    # ⑥b 逐码块分配存储槽
    if has "$fulsch" 'segment_parameters->ldpc_detail = &ldpc_detail_store'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（分配）：已存在，跳过"
    else
        ins_after "$fulsch" '^      reset_meas\(&segment_parameters->ts_ldpc_decode\);$' \
            '      // 【OAI-LDPC-PROF】分配并清零本码块的细分统计槽；越界则不采集（不影响功能）' \
            '      if (pusch_id < OAI_LDPC_DETAIL_MAX_PUSCH && r < OAI_LDPC_DETAIL_MAX_SEG) {' \
            '        segment_parameters->ldpc_detail = &ldpc_detail_store[pusch_id][r];' \
            '        memset(segment_parameters->ldpc_detail, 0, sizeof(t_nrLDPC_time_stats));' \
            '      } else {' \
            '        segment_parameters->ldpc_detail = NULL;' \
            '      }' || return 1
    fi

    # ⑥c 合并到 gNB 级汇总
    if has "$fulsch" 'merge_ldpc_detail_stats(&phy_vars_gNB->ldpc_detail'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（合并）：已存在，跳过"
    else
        ins_after "$fulsch" '^      merge_meas\(&phy_vars_gNB->ts_ldpc_decode, &nrLDPC_segment_decoding_parameters\.ts_ldpc_decode\);$' \
            '      // 【OAI-LDPC-PROF】把本码块的 11 项细分统计合并到 gNB 级汇总' \
            '      if (nrLDPC_segment_decoding_parameters.ldpc_detail)' \
            '        merge_ldpc_detail_stats(&phy_vars_gNB->ldpc_detail, nrLDPC_segment_decoding_parameters.ldpc_detail);' || return 1
    fi

    # ⑦ 打印 11 行
    if has "$fgnb" '"UL LDPC total"'; then
        echo "      [ldpc-prof] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->ts_ldpc_decode, "UL segments decoding"' \
            '  // 【OAI-LDPC-PROF】"UL segments decoding" 的内部细分（11 项）：' \
            '  //   输入装载 → 迭代主体(cnProc/bnProc) → 缓冲转换 → 输出 → total' \
            '  //   ★ cnProc/bnProc 每轮迭代计一次，故 calls ÷ (UL segments decoding).calls ≈ 平均迭代轮数' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2llrProcBuf, "UL LDPC llr2llrProcBuf", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2CnProcBuf,  "UL LDPC llr2CnProcBuf",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cnProc,         "UL LDPC cnProc",         NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cnProcPc,       "UL LDPC cnProcPc",       NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bnProcPc,       "UL LDPC bnProcPc",       NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bnProc,         "UL LDPC bnProc",         NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cn2bnProcBuf,   "UL LDPC cn2bnProcBuf",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bn2cnProcBuf,   "UL LDPC bn2cnProcBuf",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llrRes2llrOut,  "UL LDPC llrRes2llrOut",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2bit,        "UL LDPC llr2bit",        NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.total,          "UL LDPC total",          NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ⑤ DLSCH 编码细分（dlsch-enc）------------------------------------------
# 2026-09-12 加的（进度表 §11 + 后续）；run23 实测 parity 占 encoding 61.4%
# ★ 最轻的预设：字段/计时代码/指针链 OAI 原生全通，只缺 dump 里的 6 行打印
preset_dlsch_enc() {
    local root="$1"
    local fgnb="$root/$F_GNB_REL"

    if has "$fgnb" '"DLSCH segmentation"'; then
        echo "      [dlsch-enc] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->dlsch_encoding_stats, "DLSCH encoding"' \
            '  output += print_meas_log(&gNB->dlsch_segmentation_stats,   "DLSCH segmentation",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->tinput,  "LDPC enc input",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->tparity, "LDPC enc parity", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->toutput, "LDPC enc output", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->dlsch_rate_matching_stats,  "DLSCH rate matching",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->dlsch_interleaving_stats,   "DLSCH interleaving",   NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ⑥ PUSCH inner-receiver 原生子计时打印（pusch-native）-----------------
# 四个 time_stats_t 字段及 start/stop 测量点均为 OAI 原生代码；这里只补打印与清零。
# antenna processing 嵌套在 channel estimation 中，统计结果不能直接相加。
preset_pusch_native() {
    local root="$1" fgnb="$root/$F_GNB_REL"
    if has "$fgnb" '"PUSCH channel estimation"'; then
        echo "      [pusch-native] nr-gnb.c：打印项已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->rx_pusch_stats, "PUSCH inner-receiver"' \
            '  output += print_meas_log(&gNB->ulsch_channel_estimation_stats, "PUSCH channel estimation", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->pusch_channel_estimation_antenna_processing_stats, "PUSCH channel-estimation antenna processing", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->rx_pusch_init_stats, "PUSCH initialization", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->rx_pusch_symbol_processing_stats, "PUSCH symbol processing", NULL, NULL, output, end - output);' || return 1
    fi
    if has "$fgnb" 'reset_meas(&gNB->ulsch_channel_estimation_stats)'; then
        echo "      [pusch-native] nr-gnb.c：清零项已存在，跳过"
    else
        ins_after "$fgnb" 'reset_meas\(&gNB->rx_pusch_stats\);' \
            '  reset_meas(&gNB->ulsch_channel_estimation_stats);' \
            '  reset_meas(&gNB->pusch_channel_estimation_antenna_processing_stats);' \
            '  reset_meas(&gNB->rx_pusch_init_stats);' \
            '  reset_meas(&gNB->rx_pusch_symbol_processing_stats);' || return 1
    fi
}

# ---- FEP 原生调度计时打印（fep-native）------------------------------------
# 字段与测量点均为 OAI 原生代码；只把四项 wait/wakeup 输出到 nrL1_stats.log。
preset_fep_native() {
    local root="$1" fgnb="$root/$F_GNB_REL"
    if has "$fgnb" '"ofdm_demod wait"'; then
        echo "      [fep-native] RX wait/wakeup 已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '    output += print_meas_log(&ru->ofdm_demod_wait_stats, "ofdm_demod wait", NULL, NULL, output, end - output);' \
            '    output += print_meas_log(&ru->ofdm_demod_wakeup_stats, "ofdm_demod wakeup", NULL, NULL, output, end - output);' || return 1
    fi
    if has "$fgnb" '"ofdm_mod wait"'; then
        echo "      [fep-native] TX wait/wakeup 已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_total_stats,"feptx_total"' \
            '    output += print_meas_log(&ru->ofdm_mod_wait_stats, "ofdm_mod wait", NULL, NULL, output, end - output);' \
            '    output += print_meas_log(&ru->ofdm_mod_wakeup_stats, "ofdm_mod wakeup", NULL, NULL, output, end - output);' || return 1
    fi
}

run_preset() {
    local p="$1" root="$2"
    case "$p" in
        rx-symbol) preset_rx_symbol "$root" ;;
        tx-symbol) preset_tx_symbol "$root" ;;
        rx-task)   preset_rx_task   "$root" ;;
        pusch-native) preset_pusch_native "$root" ;;
        fep-native) preset_fep_native "$root" ;;
        ldpc-prof) preset_ldpc_prof "$root" ;;
        dlsch-enc) preset_dlsch_enc "$root" ;;
        *) err "未知预设：$p"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------

backup_all() {
    local bdir="$1" root="$2"
    local rel
    for rel in "${TX_FILES[@]}"; do
        mkdir -p "$bdir/$(dirname "$rel")"
        cp -p "$root/$rel" "$bdir/$rel" 2>/dev/null || true
    done
}

rollback_to() {
    local ts="$1"
    local bdir="$BACKUP_ROOT/$ts"
    [ -d "$bdir" ] || { err "找不到备份：$bdir"; return 1; }
    local n=0 rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        cp -p "$bdir/$rel" "$OAI_DIR/$rel" && n=$((n+1))
    done < <(cd "$bdir" && find . -type f | sed 's|^\./||')
    ok "已从备份 $ts 恢复 $n 个文件"
    echo "     重新编译：cd $OAI_DIR/cmake_targets/ran_build/build && make -j8 nr-softmodem"
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

cmd_list() {
    cat <<EOF

可用的计时器预设：

  1. rx-symbol    RX 单符号 DFT 计时器   →  symbol_dft (RX)          [262.9 µs]
                  ⚠️  需用 if (l == 0) 绕过竞态（l 是循环变量，5 个 worker 会并发）

  2. tx-symbol    TX 单符号 IDFT 计时器  →  symbol_idft (TX)         [267.5 µs]
                  ★ 天然无竞态（aa / first_symbol 都是函数参数）

  3. rx-task      RX 任务级（3 符号）    →  feprx_task (3 symbols)   [773.3 µs]
                  ★ 天然无竞态；补上它才能算出 RX 的调度开销

  4. pusch-native PUSCH 原生 4 项子计时   →  channel estimation/init/symbol processing
                  ★ 只补打印和清零，不向热点路径新增 start_meas/stop_meas

  5. fep-native   FEP 原生调度 4 项       →  RX/TX wait/wakeup
                  ★ 线程调度统计，不能与 FFT/IFFT 算法耗时直接相加

  6. ldpc-prof    LDPC 内部 11 项细分     →  UL LDPC cnProc/bnProc…  [cnProc 占 57%]
                  ★★ 改了 gNB/UE 共用头文件 → 应用后必须同时编译 gNB 和 UE，
                     否则两个二进制结构体布局不一致 → 崩溃（断言/段错误，进度表 §31）
                     用 --apply --build 会自动处理

  7. dlsch-enc    DLSCH 编码细分(6项)    →  seg/enc-parity/rate-match… [parity 占 61%]
                  ★ 最轻的预设：1 文件 6 行 —— 字段与指针链 OAI 原生全通，只缺打印

  另有：--preset all    依次应用以上全部七个

  OAI 源码目录：${OAI_DIR:-（未找到 —— 请用 OAI_DIR=... 或 --oai-dir 指定）}

EOF
}

# 检查一个预设的锚点是否就位
# 返回 0 = 可应用（或已存在），1 = 锚点有问题
check_preset() {
    local p="$1"
    local fdef="$OAI_DIR/$F_DEFS_REL" fproc="$OAI_DIR/$F_PROC_REL" fgnb="$OAI_DIR/$F_GNB_REL"
    local rc=0

    chk() {   # chk <tag> <file> <marker> <锚点正则> <说明>
        local tag="$1" f="$2" mk="$3" pat="$4" desc="$5"
        if has "$f" "$mk"; then
            info "$tag $desc：${D}已存在${N}"
        elif grep -qE "$pat" "$f"; then
            ok   "$tag $desc：可插入"
        else
            err  "$tag $desc：锚点缺失 → /$pat/"
            rc=1
        fi
    }

    case "$p" in
      rx-symbol)
        chk "[rx-symbol]" "$fdef"  "time_stats_t symbol_dft_stats;"  '^  time_stats_t ofdm_demod_stats;$'      "defs_RU.h"
        chk "[rx-symbol]" "$fproc" "start_meas(&ru->symbol_dft_stats)" '^  for \(int l = startSymbol; l <= endSymbol; l\+\+\) *$' "nr_ru_procedures.c"
        chk "[rx-symbol]" "$fgnb"  '"symbol_dft (RX)"'                'ofdm_demod_stats, "feprx"'               "nr-gnb.c"
        ;;
      tx-symbol)
        chk "[tx-symbol]" "$fdef"  "time_stats_t symbol_idft_stats;" "time_stats_t ofdm_mod_stats;"            "defs_RU.h"
        chk "[tx-symbol]" "$fproc" "start_meas(&ru->symbol_idft_stats)" 'case where first symbol in slot has longer prefix' "nr_ru_procedures.c"
        chk "[tx-symbol]" "$fgnb"  '"symbol_idft (TX)"'               'txdataF_copy_stats, "txdataF_copy"'      "nr-gnb.c"
        ;;
      rx-task)
        chk "[rx-task]" "$fdef"  "time_stats_t feprx_task_stats;"  '^  time_stats_t ofdm_demod_stats;$'          "defs_RU.h"
        chk "[rx-task]" "$fproc" "start_meas(&ru->feprx_task_stats)" 'slot % RU_RX_SLOT_DEPTH'                  "nr_ru_procedures.c"
        chk "[rx-task]" "$fgnb"  '"feprx_task (3 symbols)"'          'ofdm_demod_stats, "feprx"'                 "nr-gnb.c"
        ;;
      pusch-native)
        chk "[pusch-native]" "$fgnb" '"PUSCH channel estimation"' 'print_meas_log\(&gNB->rx_pusch_stats, "PUSCH inner-receiver"' "nr-gnb.c（打印）"
        chk "[pusch-native]" "$fgnb" 'reset_meas(&gNB->ulsch_channel_estimation_stats)' 'reset_meas\(&gNB->rx_pusch_stats\);' "nr-gnb.c（清零）"
        ;;
      fep-native)
        chk "[fep-native]" "$fgnb" '"ofdm_demod wait"' 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' "nr-gnb.c（RX）"
        chk "[fep-native]" "$fgnb" '"ofdm_mod wait"' 'print_meas_log\(&ru->ofdm_total_stats,"feptx_total"' "nr-gnb.c（TX）"
        ;;
        ldpc-prof)
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_DEC_REL"   "【OAI-LDPC-PROF】原为「空定义」"                       '^//#define NR_LDPC_PROFILER_DETAIL\(a\) a$'            "nrLDPC_decoder.c（宏）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_TYPES_REL" "merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst"      '^} t_nrLDPC_time_stats;$'                              "nrLDPC_types.h"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_IFACE_REL" 'PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"'             '^#include "PHY/defs_gNB.h"$'                          "iface.h（include）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_IFACE_REL" 't_nrLDPC_time_stats \*ldpc_detail;'                   '^} nrLDPC_segment_decoding_parameters_t;$'             "iface.h（字段）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   't_nrLDPC_time_stats \*p_ldpc_detail;'                 '^} nrLDPC_decoding_parameters_t;$'                    "seg_dec.c（字段）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   'p_procTime = rdata->p_ldpc_detail'                     '^  t_nrLDPC_time_stats procTime = \{0\};$'           "seg_dec.c（收集）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   'rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters'  'p_ts_ldpc_decode = &nrLDPC_TB_decoding_parameters'     "seg_dec.c（接线）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_DEFS_GNB_REL"   't_nrLDPC_time_stats ldpc_detail;'                      '^  time_stats_t ts_ldpc_decode;$'                     "defs_gNB.h"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'static t_nrLDPC_time_stats ldpc_detail_store'          '^  memset\(segments, 0, sizeof\(segments\)\);$'    "ulsch.c（存储）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'segment_parameters->ldpc_detail = &ldpc_detail_store'  'reset_meas\(&segment_parameters->ts_ldpc_decode\);'  "ulsch.c（分配）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'merge_ldpc_detail_stats\(&phy_vars_gNB->ldpc_detail'  'merge_meas\(&phy_vars_gNB->ts_ldpc_decode'           "ulsch.c（合并）"
          chk "[ldpc-prof]" "$fgnb"                      '"UL LDPC total"'                                       'ts_ldpc_decode, "UL segments decoding"'               "nr-gnb.c"
          ;;
        dlsch-enc)
          chk "[dlsch-enc]" "$fgnb" '"DLSCH segmentation"' 'print_meas_log\(&gNB->dlsch_encoding_stats, "DLSCH encoding"' "nr-gnb.c"
          ;;
    esac
    return $rc
}

cmd_check() {
    local presets="$1" rc=0 p
    echo
    echo "检查源码匹配情况（OAI 目录：$OAI_DIR）"
    echo
    for p in $presets; do
        check_preset "$p" || rc=1
    done
    echo
    if [ "$rc" -eq 0 ]; then
        ok "检查通过 —— 锚点就位，可以安全执行 --apply"
    else
        err "检查未通过 —— 请勿使用 --apply"
    fi
    echo
    return $rc
}

cmd_verify() {
    local fdef="$OAI_DIR/$F_DEFS_REL" fproc="$OAI_DIR/$F_PROC_REL" fgnb="$OAI_DIR/$F_GNB_REL"
    echo
    echo "当前源码里的计时器状态（OAI 目录：$OAI_DIR）"
    echo
    local one
    one() {   # one <name> <desc> <m1> <m2> <m3>
        local name="$1" desc="$2" m1="$3" m2="$4" m3="$5"
        local d=0
        has "$fdef"  "$m1" && d=$((d+1))
        has "$fproc" "$m2" && d=$((d+1))
        has "$fgnb"  "$m3" && d=$((d+1))
        local s
        if   [ "$d" -eq 3 ]; then s="${G}✅ 全部添加（3/3）${N}"
        elif [ "$d" -eq 0 ]; then s="${R}❌ 未添加（0/3）${N}"
        else                      s="${Y}⚠️  部分（$d/3）${N}"; fi
        echo "  ── $name"
        echo "     $desc"
        echo "     状态：$s"
        printf '     明细：%s defs_RU.h   %s nr_ru_procedures.c   %s nr-gnb.c\n' \
            "$(has "$fdef"  "$m1" && echo ✅ || echo ❌)" \
            "$(has "$fproc" "$m2" && echo ✅ || echo ❌)" \
            "$(has "$fgnb"  "$m3" && echo ✅ || echo ❌)"
        echo
    }
    one rx-symbol "RX 单符号 DFT"     "time_stats_t symbol_dft_stats;"  "start_meas(&ru->symbol_dft_stats)"  '"symbol_dft (RX)"'
    one tx-symbol "TX 单符号 IDFT"    "time_stats_t symbol_idft_stats;" "start_meas(&ru->symbol_idft_stats)" '"symbol_idft (TX)"'
    one rx-task   "RX 任务级（3 符号）" "time_stats_t feprx_task_stats;" "start_meas(&ru->feprx_task_stats)"  '"feprx_task (3 symbols)"'

      # ldpc-prof：7 文件 → 逐文件检查（每文件一个代表性 marker）
      local -a LDPC_CHK=(
        "$OAI_DIR/$F_LDPC_DEC_REL|【OAI-LDPC-PROF】原为「空定义」|nrLDPC_decoder.c"
        "$OAI_DIR/$F_LDPC_TYPES_REL|merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst|nrLDPC_types.h"
        "$OAI_DIR/$F_LDPC_IFACE_REL|t_nrLDPC_time_stats *ldpc_detail;|nrLDPC_coding_interface.h"
        "$OAI_DIR/$F_LDPC_SEG_REL|p_procTime = rdata->p_ldpc_detail|nrLDPC_coding_segment_decoder.c"
        "$OAI_DIR/$F_DEFS_GNB_REL|t_nrLDPC_time_stats ldpc_detail;|defs_gNB.h"
        "$OAI_DIR/$F_ULSCH_REL|static t_nrLDPC_time_stats ldpc_detail_store|nr_ulsch_decoding.c"
        "$OAI_DIR/$F_GNB_REL|\"UL LDPC total\"|nr-gnb.c"
      )
      local hit=0 detail="" entry ff mm nn
      for entry in "${LDPC_CHK[@]}"; do
          ff="${entry%%|*}"; mm="${entry#*|}"; nn="${mm##*|}"; mm="${mm%|*}"
          if has "$ff" "$mm"; then hit=$((hit+1)); detail="$detail ✅ $nn"
          else                    detail="$detail ❌ $nn"; fi
      done
      local ls
      if   [ "$hit" -eq 7 ]; then ls="${G}✅ 全部添加（7/7 文件）${N}"
      elif [ "$hit" -eq 0 ]; then ls="${R}❌ 未添加（0/7 文件）${N}"
      else                        ls="${Y}⚠️  部分（$hit/7 文件）${N}"; fi
      echo "  ── ldpc-prof"
      echo "     LDPC 译码内部 11 项细分"
      echo "     状态：$ls"
      echo "     明细：$detail"
      echo

      # dlsch-enc：1 文件 6 行
      if has "$fgnb" '"DLSCH segmentation"' && has "$fgnb" '"DLSCH rate matching"'; then
          echo "  ── dlsch-enc"
          echo "     DLSCH 编码细分（6 项）"
          echo "     状态：${G}✅ 已添加（1/1 文件）${N}"
          echo "     明细：✅ nr-gnb.c"
      else
          echo "  ── dlsch-enc"
          echo "     DLSCH 编码细分（6 项）"
          echo "     状态：${R}❌ 未添加${N}"
          echo "     明细：❌ nr-gnb.c"
      fi
      echo
    echo "  跑一轮实验即可看数据："
    echo "     cd ~/sionna-rk && ./scripts/run-k3-hotspot-experiment.sh ideal 1 <新编号>"
    echo
}

cmd_apply() {
    local presets="$1"

    echo
    if [ "$DO_APPLY" -eq 0 ]; then
        echo "──────────────────────────────────────────────────────────────────────"
        echo "  DRY-RUN 模式 —— 只预览，不会改动任何文件"
        echo "  确认无误后加 ${C}--apply${N} 真正执行"
        echo "──────────────────────────────────────────────────────────────────────"
        echo
        echo "  将对以下 3 个文件做修改（OAI 目录：$OAI_DIR）"
        echo
        local p
        for p in $presets; do
            echo "  ${C}[$p]${N}"
            check_preset "$p" || { echo; err "锚点检查未通过，请先修好再应用"; return 1; }
            echo
        done
        echo "  ⇒ 用 ${C}--check${N} 可看到逐文件的匹配详情。"
        echo "  ⇒ 确认后执行： $0 --preset $(echo "$presets" | tr ' ' ',') --apply"
        echo
        return 0
    fi

    # ── 真正应用 ──
    TS="$(date +%Y%m%d-%H%M%S)"
    local bdir="$BACKUP_ROOT/$TS"
    mkdir -p "$bdir"

    echo "开始应用（OAI 目录：$OAI_DIR）"
    echo
    backup_all "$bdir" "$OAI_DIR"
    local nbf; nbf=$(find "$bdir" -type f 2>/dev/null | wc -l)
    ok "已备份 $nbf 个文件 → $bdir"
    echo

    local p
    for p in $presets; do
        echo "  ${C}[$p]${N}"
        if ! run_preset "$p" "$OAI_DIR"; then
            echo
            err "预设 $p 失败 —— 正在恢复…"
            rollback_to "$TS"
            die "已恢复到改动前的状态。"
        fi
        echo
    done

    ok "应用完成"
    echo "     备份：$bdir"
    echo "     回滚：$0 --rollback $TS"
    echo

    if [ "$DO_BUILD" -eq 1 ]; then
        case "$presets" in
            *ldpc-prof*) do_build 1 ;;   # 改了共用头文件 → 必须连 UE 一起编
            *)           do_build 0 ;;
        esac
    fi
}

do_build() {
    # $1 = "1" → 同时编 nr-uesoftmodem
    #   ⚠️ 只要改了「gNB 和 UE 共用」的头文件/结构体（如 ldpc-prof 预设改的
    #      nrLDPC_coding_interface.h / nrLDPC_types.h），就**必须**一起编两个二进制，
    #      否则二者结构体布局不一致 → 运行期崩溃，症状与 LDPC 看似无关（进度表 §31）。
    local with_ue="${1:-0}"
    local bdir="$OAI_DIR/cmake_targets/ran_build/build"
    [ -d "$bdir" ] || { warn "构建目录不存在，跳过编译：$bdir"; return 1; }
    local jobs; jobs=$(nproc 2>/dev/null || echo 4)
    # RFsim experiments also require the runtime plugin.  Building only the
    # executables can leave a valid gNB binary that exits at startup because
    # librfsimulator.so is absent from the build directory.
    local targets="nr-softmodem rfsimulator"
    [ "$with_ue" = "1" ] && targets="nr-softmodem nr-uesoftmodem rfsimulator"
    echo "开始编译（make -j${jobs} ${targets}）…"
    if [ "$with_ue" = "1" ]; then
        echo "     ⚠️  本次同时编译 gNB + UE —— 因为改动了共用头文件，两者必须一起更新，"
        echo "        否则运行期会崩溃（详情见进度表 §31）"
    fi
    echo
    ( cd "$bdir" && make "-j${jobs}" $targets 2>&1 | tail -10 )
    echo
    local b
    for b in $targets; do
        [ -f "$bdir/$b" ] && ok "$b  sha256[:16] = $(sha256sum "$bdir/$b" | cut -c1-16)"
    done
    echo "     ⚠️  记录这些 sha：与旧数据不可直接比较"
    echo
}

cmd_rollback() {
    [ -d "$BACKUP_ROOT" ] || die "没有备份目录：$BACKUP_ROOT"

    if [ -z "$RB_TS" ]; then
        echo
        echo "可用的备份（最新在前）："
        echo
        local d n
        for d in $(ls -1 "$BACKUP_ROOT" | sort -r); do
            n=$(find "$BACKUP_ROOT/$d" -type f 2>/dev/null | wc -l)
            echo "  $d   （$n 个文件）"
        done
        echo
        echo "用法：$0 --rollback <时间戳>"
        echo
        return 0
    fi

    rollback_to "$RB_TS" || die "回滚失败"
}

usage() {
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
}

find_oai_dir() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local c
    for c in \
        "$here/../ext/openairinterface5g" \
        "$here/ext/openairinterface5g" \
        "$here/openairinterface5g" \
        "$HOME/sionna-rk/ext/openairinterface5g" \
        "$HOME/openairinterface5g"
    do
        [ -d "$c/openair1" ] && { (cd "$c" && pwd); return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list)       ACTION="list" ;;
        --check)      ACTION="check" ;;
        --verify)     ACTION="verify" ;;
        --apply)      DO_APPLY=1 ;;
        --build)      DO_BUILD=1 ;;
        --preset)     shift; PRESET="${1:-}" ;;
        --preset=*)   PRESET="${1#*=}" ;;
        --rollback)   ACTION="rollback" ;;
        --rollback=*) ACTION="rollback"; RB_TS="${1#*=}" ;;
        --oai-dir)    shift; OAI_DIR="${1:-}" ;;
        --oai-dir=*)  OAI_DIR="${1#*=}" ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "未知参数：$1（用 --help 看用法）" ;;
        *)            RB_TS="$1" ;;
    esac
    shift
done

if [ -z "$ACTION" ] && [ -z "$PRESET" ]; then
    usage; echo; exit 0
fi

# 定位 OAI 目录
if [ -n "$OAI_DIR" ]; then
    [ -d "$OAI_DIR/openair1" ] || die "指定的 OAI 目录不合法（找不到 openair1/）：$OAI_DIR"
    OAI_DIR="$(cd "$OAI_DIR" && pwd)"
else
    OAI_DIR="$(find_oai_dir)" || die "无法自动定位 OAI 源码目录。
     请用 --oai-dir 指定，例如：
       $0 --oai-dir ~/sionna-rk/ext/openairinterface5g --list"
fi

case "$ACTION" in
    list)     cmd_list ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback ;;
    check)
        if [ -z "$PRESET" ] || [ "$PRESET" = "all" ]; then
            cmd_check "rx-symbol tx-symbol rx-task pusch-native fep-native ldpc-prof dlsch-enc"
        else
            cmd_check "$PRESET"
        fi
        ;;
    "")
        case "$PRESET" in
            all)       cmd_apply "rx-symbol tx-symbol rx-task pusch-native fep-native ldpc-prof dlsch-enc" ;;
            rx-symbol|tx-symbol|rx-task|pusch-native|fep-native|ldpc-prof|dlsch-enc) cmd_apply "$PRESET" ;;
            *) die "未知预设：$PRESET（可用：rx-symbol / tx-symbol / rx-task / pusch-native / fep-native / ldpc-prof / dlsch-enc / all）" ;;
        esac
        ;;
esac
