#!/bin/bash
set -euo pipefail
# 历史性能问题分析脚本 — 采集系统自开机以来的累积计数器（绝对值）+ 周期性 delta 采样
# 所有工具均为只读采集，不修改任何系统状态
# 适用场景：性能问题已经发生过，通过累积错误计数器回溯历史异常
#           同时通过 delta 采样反映当前是否仍在持续

DURATION=${1:-10}  # 采样周期, 默认 10 秒, 可通过第一个参数覆盖
OUT_DIR="/tmp/perf_scan_past"
# 每次运行清除旧数据，保证目录只包含本次扫描结果
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">>> 历史性能指标采集开始 (delta 采样 ${DURATION}s), 输出目录: $OUT_DIR"

# ── 1. 系统基本信息 ─────────────────────────────────────
{
  echo "=== 系统运行时长 & 负载趋势 ==="
  uptime
  echo ""
  echo "=== 内核版本 ==="
  uname -r
  echo ""
  echo "=== 启动时间 ==="
  who -b 2>/dev/null || echo "(who -b not available)"
} > "$OUT_DIR/01_system_info.txt" 2>&1

# ── 2. 网络协议栈累积计数器 (重点) ──────────────────────
{
  echo "=== nstat 网络协议栈累积计数器 ==="
  echo "# 关键指标说明:"
  echo "#   TcpRetransSegs     — TCP 重传段总数"
  echo "#   TcpInErrs          — TCP 接收错误总数"
  echo "#   TcpOutRsts         — TCP 发送 RST 总数"
  echo "#   TcpActiveOpens     — TCP 主动连接总数"
  echo "#   TcpPassiveOpens    — TCP 被动连接总数"
  echo "#   TcpAttemptFails    — TCP 连接尝试失败总数"
  echo "#   TcpEstabResets     — TCP 已建连接被重置总数"
  echo "#   UdpInErrors        — UDP 接收错误总数"
  echo "#   IpInDiscards       — IP 层入站丢弃总数"
  echo "#   IpOutDiscards      — IP 层出站丢弃总数"
  echo "#   IpInAddrErrors     — IP 地址错误总数"
  echo "#   TcpExtListenDrops  — 全连接队列满丢弃总数"
  echo "#   TcpExtListenOverflows — 全连接队列溢出总数"
  echo "#   TcpExtTCPBacklogDrop  — Backlog 队列丢弃总数"
  echo ""
  # -a 显示绝对值（不做速率转换）, -s 不重置计数器
  nstat -as 2>/dev/null || echo "(nstat not available, falling back to /proc/net/snmp)"
  echo ""
  echo "=== /proc/net/snmp (TCP/UDP/IP 汇总) ==="
  cat /proc/net/snmp 2>/dev/null || echo "(not available)"
  echo ""
  echo "=== /proc/net/netstat (TCP 扩展计数器) ==="
  cat /proc/net/netstat 2>/dev/null || echo "(not available)"
  echo ""
  echo "=== Socket 汇总 (ss -s) ==="
  ss -s 2>/dev/null || echo "(ss not available)"
} > "$OUT_DIR/02_network_counters.txt" 2>&1

# ── 3. 网络接口错误计数器 ──────────────────────────────
{
  echo "=== 网络接口错误统计 (rx_errors/tx_errors/drops/overruns) ==="
  echo "# 关键指标: errors/dropped/overruns 非零即有历史丢包"
  echo ""
  ip -s link 2>/dev/null || ifconfig -a 2>/dev/null || echo "(ip/ifconfig not available)"
  echo ""
  echo "=== /proc/net/dev (原始计数器) ==="
  cat /proc/net/dev 2>/dev/null || echo "(not available)"
} > "$OUT_DIR/03_nic_errors.txt" 2>&1

# ── 4. conntrack 连接跟踪丢弃 ─────────────────────────
{
  echo "=== conntrack 统计 ==="
  echo "# 关键指标: drop/early_drop/error 非零说明曾发生连接跟踪表满"
  echo ""
  conntrack -S 2>/dev/null || echo "(conntrack not available or no permission)"
  echo ""
  echo "=== nf_conntrack 表当前使用量 ==="
  if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
    echo "count: $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
    echo "max:   $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
  else
    echo "(nf_conntrack not loaded)"
  fi
} > "$OUT_DIR/04_conntrack.txt" 2>&1

# ── 5. 磁盘 I/O 累积统计 ──────────────────────────────
{
  echo "=== iostat 自开机以来汇总 (首行输出即累积平均值) ==="
  iostat -xz 2>/dev/null | head -n 30 || echo "(iostat not available)"
  echo ""
  echo "=== /proc/diskstats (原始累积计数器) ==="
  echo "# 各列含义: reads_completed reads_merged sectors_read ms_reading writes_completed ..."
  cat /proc/diskstats 2>/dev/null || echo "(not available)"
  echo ""
  echo "=== 磁盘 I/O 错误计数 (/sys) ==="
  for dev in /sys/block/*/device/ioerr_cnt; do
    if [[ -f "$dev" ]]; then
      echo "$dev: $(cat "$dev")"
    fi
  done
  echo "(若无输出说明无 /sys 错误计数器或计数为 0)"
} > "$OUT_DIR/05_disk_io.txt" 2>&1

# ── 6. SMART 磁盘健康 ────────────────────────────────
{
  echo "=== SMART 磁盘健康检查 ==="
  echo "# 关键指标: Reallocated_Sector_Ct, Current_Pending_Sector, Offline_Uncorrectable"
  echo ""
  if command -v smartctl &>/dev/null; then
    for disk in /dev/sd? /dev/nvme?n?; do
      if [[ -b "$disk" ]]; then
        echo "--- $disk ---"
        smartctl -a "$disk" 2>/dev/null | grep -E '(SMART overall|Reallocated|Pending|Uncorrectable|Power_On_Hours|Temperature)' || echo "(no SMART data)"
        echo ""
      fi
    done
  else
    echo "(smartctl not installed, run: yum/apt install smartmontools)"
  fi
} > "$OUT_DIR/06_smart.txt" 2>&1

# ── 7. 内存 & Swap & OOM 历史 ─────────────────────────
{
  echo "=== 当前内存状态 ==="
  free -m
  echo ""
  echo "=== /proc/vmstat 累积计数器 ==="
  echo "# 关键指标:"
  echo "#   pswpin/pswpout     — Swap 换入换出页数 (非零说明曾发生内存不足)"
  echo "#   pgfault/pgmajfault — 页面故障/主要页面故障总数"
  echo "#   oom_kill           — OOM Killer 触发总数 (内核 4.13+)"
  echo ""
  cat /proc/vmstat 2>/dev/null | grep -E '^(pswpin|pswpout|pgfault|pgmajfault|oom_kill|pgpgin|pgpgout|allocstall|drop_pagecache|drop_slab)' || echo "(not available)"
  echo ""
  echo "=== NUMA 内存统计 ==="
  numastat 2>/dev/null || echo "(numastat not available)"
  echo ""
  echo "=== OOM Killer 历史事件 (dmesg) ==="
  dmesg -T 2>/dev/null | grep -i 'out of memory\|oom.*kill\|invoked oom' || echo "(无 OOM 事件)"
} > "$OUT_DIR/07_memory_oom.txt" 2>&1

# ── 8. 内核关键错误事件 (dmesg) ────────────────────────
{
  echo "=== 内核关键错误事件 ==="
  echo "# 扫描 dmesg 中的硬件错误、panic、hung task、MCE、soft lockup 等"
  echo ""
  dmesg -T 2>/dev/null | grep -iE \
    'error|fail|panic|oops|bug|warn|blocked for more than|hung_task|soft lockup|hard lockup|machine check|mce|call trace|segfault|unable to handle|readonly|i/o error|ext4.*error|xfs.*error|blk_update_request|buffer i/o error' \
    | tail -n 100 || echo "(无匹配的内核错误事件)"
} > "$OUT_DIR/08_kernel_errors.txt" 2>&1

# ── 9. CPU 调度统计 & 硬件错误 ─────────────────────────
{
  echo "=== /proc/stat CPU 累积时间 (单位: jiffies) ==="
  echo "# user nice system idle iowait irq softirq steal guest guest_nice"
  head -n 1 /proc/stat 2>/dev/null || echo "(not available)"
  echo ""
  echo "=== 上下文切换 & 进程创建 (自开机累积) ==="
  grep -E '^(ctxt|processes|procs_running|procs_blocked)' /proc/stat 2>/dev/null || echo "(not available)"
  echo ""
  echo "=== Machine Check Exceptions (MCE) ==="
  echo "# 非零说明 CPU/内存硬件存在校验错误历史"
  echo ""
  if command -v mcelog &>/dev/null; then
    mcelog --client 2>/dev/null || echo "(mcelog daemon not running)"
  fi
  if [[ -d /sys/devices/system/machinecheck ]]; then
    for mc in /sys/devices/system/machinecheck/machinecheck*/; do
      bank_count=$(cat "$mc/corrected_count" 2>/dev/null || echo "N/A")
      echo "$(basename "$mc"): corrected_count=$bank_count"
    done
  fi
  dmesg -T 2>/dev/null | grep -i 'machine check\|mce\|hardware error' || echo "(dmesg 中无 MCE 记录)"
  echo ""
  echo "=== /proc/interrupts (ERR/MIS 行) ==="
  grep -E '^(ERR|MIS)' /proc/interrupts 2>/dev/null || echo "(无中断错误)"
  echo ""
  echo "=== CPU throttling (过热降频) ==="
  dmesg -T 2>/dev/null | grep -i 'cpu.*throttl\|clock.*throttl' || echo "(无 CPU 降频事件)"
} > "$OUT_DIR/09_cpu_hw_errors.txt" 2>&1

# ── 10. 文件系统错误 ──────────────────────────────────
{
  echo "=== 文件系统挂载状态 & 错误 ==="
  echo "# 关键: 检查是否有文件系统被降级为 readonly"
  echo ""
  mount | grep -E '(ext4|xfs|btrfs|nfs)' 2>/dev/null || mount
  echo ""
  echo "=== ext4 文件系统错误计数 ==="
  for fs in /sys/fs/ext4/*/errors_count; do
    if [[ -f "$fs" ]]; then
      echo "$fs: $(cat "$fs")"
    fi
  done
  echo ""
  echo "=== XFS 错误统计 ==="
  for xfs_err in /sys/fs/xfs/*/error/*/; do
    if [[ -d "$xfs_err" ]]; then
      echo "$xfs_err"
      for f in "$xfs_err"*; do
        [[ -f "$f" ]] && echo "  $(basename "$f"): $(cat "$f")"
      done
    fi
  done
  echo "(若无输出说明无 ext4/xfs 错误或无该文件系统)"
} > "$OUT_DIR/10_filesystem_errors.txt" 2>&1

# ── 11. softnet 统计 (网卡软中断丢包) ─────────────────
{
  echo "=== /proc/net/softnet_stat ==="
  echo "# 各列 (hex): processed dropped time_squeeze flow_limit_count ..."
  echo "# 第2列 (dropped) 非零 = 网卡软中断处理不过来导致丢包"
  echo "# 第3列 (time_squeeze) 非零 = ksoftirqd 时间片不够"
  echo ""
  cat /proc/net/softnet_stat 2>/dev/null || echo "(not available)"
} > "$OUT_DIR/11_softnet.txt" 2>&1

# ── 12. sar 历史归档 (如果有) ─────────────────────────
{
  echo "=== sar 历史数据归档检查 ==="
  sar_dir="/var/log/sysstat"
  if [[ -d "$sar_dir" ]] || [[ -d "/var/log/sa" ]]; then
    [[ -d "/var/log/sa" ]] && sar_dir="/var/log/sa"
    echo "归档目录: $sar_dir"
    ls -lh "$sar_dir"/ 2>/dev/null || echo "(目录为空)"
    echo ""
    echo "=== 最近 sar 数据 (今日 CPU) ==="
    sar 2>/dev/null | tail -n 20 || echo "(sar 无历史数据, 检查 sysstat 是否已启用 cron)"
  else
    echo "(未找到 sar 归档目录, sysstat 可能未配置定时采集)"
    echo "启用方法: systemctl enable --now sysstat"
  fi
} > "$OUT_DIR/12_sar_history.txt" 2>&1

# ── 13. 周期性 delta 采样 (T0 → 等待 → T1 → 计算 delta) ──
echo ">>> 开始 delta 采样 (${DURATION}s) ..."

# -- 采集 T0 快照 --
t0_snmp=$(cat /proc/net/snmp 2>/dev/null)
t0_netstat=$(cat /proc/net/netstat 2>/dev/null)
t0_vmstat=$(cat /proc/vmstat 2>/dev/null)
t0_proc_stat=$(cat /proc/stat 2>/dev/null)
t0_diskstats=$(cat /proc/diskstats 2>/dev/null)
t0_softnet=$(cat /proc/net/softnet_stat 2>/dev/null)
t0_netdev=$(cat /proc/net/dev 2>/dev/null)

sleep "$DURATION"

# -- 采集 T1 快照 --
t1_snmp=$(cat /proc/net/snmp 2>/dev/null)
t1_netstat=$(cat /proc/net/netstat 2>/dev/null)
t1_vmstat=$(cat /proc/vmstat 2>/dev/null)
t1_proc_stat=$(cat /proc/stat 2>/dev/null)
t1_diskstats=$(cat /proc/diskstats 2>/dev/null)
t1_softnet=$(cat /proc/net/softnet_stat 2>/dev/null)
t1_netdev=$(cat /proc/net/dev 2>/dev/null)

# -- delta 计算辅助函数 --
# 从 /proc/net/snmp 或 /proc/net/netstat 中提取指定协议行的指定字段值
get_snmp_val() {
  local data="$1" proto="$2" field="$3"
  local headers values
  headers=$(echo "$data" | grep "^${proto}:" | head -n 1)
  values=$(echo "$data" | grep "^${proto}:" | tail -n 1)
  local idx=1
  for h in $headers; do
    if [[ "$h" == "$field" ]]; then
      echo "$values" | awk "{print \$$((idx))}"
      return
    fi
    ((idx++)) || true
  done
  echo "0"
}

# 从 /proc/vmstat 中提取字段值
get_vmstat_val() {
  local data="$1" field="$2"
  echo "$data" | awk "/^${field} /{print \$2}"
}

# delta 计算: t1 - t0
delta() {
  local v0="${1:-0}" v1="${2:-0}"
  echo $(( v1 - v0 ))
}

{
  echo "=== 周期性 Delta 采样 (${DURATION}s 内的增量与速率) ==="
  echo "# 以下数值反映采样窗口内的实时变化, 非零说明问题正在发生"
  echo ""

  echo "--- 网络协议栈 (TCP/IP) ---"
  for metric in TcpRetransSegs TcpInErrs TcpOutRsts TcpAttemptFails TcpEstabResets; do
    v0=$(get_snmp_val "$t0_snmp" "Tcp" "$metric")
    v1=$(get_snmp_val "$t1_snmp" "Tcp" "$metric")
    d=$(delta "$v0" "$v1")
    rate=$(awk "BEGIN{printf \"%.2f\", $d/$DURATION}")
    printf "  %-28s  绝对值=%-12s  Δ=%-8s  速率=%s/s\n" "$metric" "$v1" "$d" "$rate"
  done
  for metric in UdpInErrors InDiscards OutDiscards InAddrErrors; do
    proto="Udp"
    [[ "$metric" == In* || "$metric" == Out* ]] && proto="Ip"
    [[ "$metric" == UdpInErrors ]] && proto="Udp"
    v0=$(get_snmp_val "$t0_snmp" "$proto" "$metric")
    v1=$(get_snmp_val "$t1_snmp" "$proto" "$metric")
    d=$(delta "$v0" "$v1")
    rate=$(awk "BEGIN{printf \"%.2f\", $d/$DURATION}")
    printf "  %-28s  绝对值=%-12s  Δ=%-8s  速率=%s/s\n" "$metric" "$v1" "$d" "$rate"
  done
  echo ""

  echo "--- TCP 扩展 (Listen 队列) ---"
  for metric in ListenDrops ListenOverflows TCPBacklogDrop; do
    v0=$(get_snmp_val "$t0_netstat" "TcpExt" "$metric")
    v1=$(get_snmp_val "$t1_netstat" "TcpExt" "$metric")
    d=$(delta "$v0" "$v1")
    rate=$(awk "BEGIN{printf \"%.2f\", $d/$DURATION}")
    printf "  %-28s  绝对值=%-12s  Δ=%-8s  速率=%s/s\n" "$metric" "$v1" "$d" "$rate"
  done
  echo ""

  echo "--- 内存 & Swap ---"
  for metric in pswpin pswpout pgfault pgmajfault oom_kill; do
    v0=$(get_vmstat_val "$t0_vmstat" "$metric")
    v1=$(get_vmstat_val "$t1_vmstat" "$metric")
    [[ -z "$v0" ]] && v0=0
    [[ -z "$v1" ]] && v1=0
    d=$(delta "$v0" "$v1")
    rate=$(awk "BEGIN{printf \"%.2f\", $d/$DURATION}")
    printf "  %-28s  绝对值=%-12s  Δ=%-8s  速率=%s/s\n" "$metric" "$v1" "$d" "$rate"
  done
  echo ""

  echo "--- CPU 调度 ---"
  for metric in ctxt processes; do
    v0=$(grep "^${metric} " <<< "$t0_proc_stat" | awk '{print $2}')
    v1=$(grep "^${metric} " <<< "$t1_proc_stat" | awk '{print $2}')
    [[ -z "$v0" ]] && v0=0
    [[ -z "$v1" ]] && v1=0
    d=$(delta "$v0" "$v1")
    rate=$(awk "BEGIN{printf \"%.2f\", $d/$DURATION}")
    label="$metric"
    [[ "$metric" == "ctxt" ]] && label="context_switches"
    [[ "$metric" == "processes" ]] && label="forks"
    printf "  %-28s  绝对值=%-12s  Δ=%-8s  速率=%s/s\n" "$label" "$v1" "$d" "$rate"
  done
  echo ""

  echo "--- 磁盘 I/O ---"
  echo "# 主要块设备的读写完成数增量"
  paste <(echo "$t0_diskstats") <(echo "$t1_diskstats") | awk '{
    # 动态计算每侧字段数 (14/18/20 取决于内核版本)
    half = int(NF / 2)
    dev_t0 = $3; dev_t1 = $(half + 3)
    if (dev_t0 != dev_t1) next
    if (dev_t0 !~ /^(sd|vd|xvd|hd|nvme|dm-)/) next
    rd_delta    = $(half + 4) - $4    # reads completed
    wr_delta    = $(half + 8) - $8    # writes completed
    rd_ms_delta = $(half + 7) - $7    # ms reading
    wr_ms_delta = $(half + 11) - $11  # ms writing
    if (rd_delta == 0 && wr_delta == 0) next
    printf "  %-20s  reads: Δ=%-8d  writes: Δ=%-8d  read_ms: Δ=%-8d  write_ms: Δ=%d\n",
           dev_t0, rd_delta, wr_delta, rd_ms_delta, wr_ms_delta
  }' 2>/dev/null || echo "  (diskstats delta 计算不可用)"
  echo ""

  echo "--- 网卡接口 (rx/tx errors & drops) ---"
  paste <(echo "$t0_netdev") <(echo "$t1_netdev") | awk 'NR>2{
    # /proc/net/dev 每行: iface: rx_bytes rx_packets rx_errs rx_drop ... (共 16 个计数器)
    # paste 后 T0+T1 各 17 列 (iface + 16 counters), 共 34 列
    gsub(/:/, " ")
    n = split($0, f)
    if (n < 34) next
    iface = f[1]
    if (iface ~ /^(lo|docker|veth|br-)/) next
    rx_err_d  = f[21] - f[4]
    rx_drop_d = f[22] - f[5]
    tx_err_d  = f[29] - f[12]
    tx_drop_d = f[30] - f[13]
    printf "  %-16s  rx_errors: Δ=%-6d  rx_drops: Δ=%-6d  tx_errors: Δ=%-6d  tx_drops: Δ=%d\n",
           iface, rx_err_d, rx_drop_d, tx_err_d, tx_drop_d
  }' 2>/dev/null || echo "  (netdev delta 计算不可用)"
  echo ""

  echo "--- softnet (网卡软中断) ---"
  echo "# per-CPU: processed_delta  dropped_delta  time_squeeze_delta"
  paste <(echo "$t0_softnet") <(echo "$t1_softnet") | awk '{
    # 动态计算每侧列数 (3/9/11/13 取决于内核版本)
    half = int(NF / 2)
    t0_proc = strtonum("0x" $1);         t1_proc = strtonum("0x" $(half + 1))
    t0_drop = strtonum("0x" $2);         t1_drop = strtonum("0x" $(half + 2))
    t0_sq   = strtonum("0x" $3);         t1_sq   = strtonum("0x" $(half + 3))
    printf "  CPU%-3d  processed: Δ=%-10d  dropped: Δ=%-6d  time_squeeze: Δ=%d\n",
           NR-1, t1_proc-t0_proc, t1_drop-t0_drop, t1_sq-t0_sq
  }' 2>/dev/null || echo "  (softnet delta 计算不可用)"

} > "$OUT_DIR/13_delta_sampling.txt" 2>&1

# ── 输出汇总 ───────────────────────────────────────────
echo ">>> 历史性能指标采集完成, 结果目录: $OUT_DIR"
echo ""
echo "==================== 采集结果汇总 ===================="
for f in "$OUT_DIR"/*; do
  echo ""
  echo "────────────────────────────────────────────────────"
  echo "📄 $(basename "$f")"
  echo "────────────────────────────────────────────────────"
  cat "$f"
done
echo ""
echo "======================================================"
