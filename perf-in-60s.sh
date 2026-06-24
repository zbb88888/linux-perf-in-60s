#!/bin/bash
set -euo pipefail
# 性能问题快速扫描脚本 (Brendan Gregg "Linux 60-Second Analysis" 原版)
# 所有工具均为只读采集，不修改任何系统状态
# 采样命令并行执行，每条命令 ~10s，总耗时 ~10 秒

DURATION=10
INTERVAL=1
OUT_DIR="/tmp/perf_scan_60s"
# 每次运行清除旧数据，保证目录只包含本次扫描结果
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">>> 性能扫描开始 (采集 ${DURATION}s), 输出目录: $OUT_DIR"

# ── 1. 瞬时快照 (立即完成) ──────────────────────────────
{
  echo "=== 1. Load Averages & Uptime ==="
  uptime # 检查1/5/15分钟负载趋势

  echo -e "\n=== 2. Kernel Errors (last 50 lines) ==="
  dmesg -T 2>/dev/null | tail -n 50 || echo "(dmesg not available or no permission)"

  echo -e "\n=== 3. PSI Pressure Stall Information ==="
  for res in cpu memory io; do
    if [[ -f /proc/pressure/$res ]]; then
      echo "$res: $(head -n 1 /proc/pressure/$res)"
    fi
  done

  echo -e "\n=== 4. Memory Breakdown ==="
  free -m # 可用内存及缓存占比

  echo -e "\n=== 5. Slab Top Consumers ==="
  slabtop -o -sc 2>/dev/null | head -n 20 || echo "(slabtop not available)"
} > "$OUT_DIR/snapshot.txt" 2>&1

# ── 2. 并行采样 (各跑 60s, 总耗时 ~60s) ─────────────────
# 重点看: r (运行队列), si/so (交换), st (偷取时间)
vmstat -SM "$INTERVAL" "$DURATION" > "$OUT_DIR/vmstat.txt" 2>&1 &

# 重点看: %soft/%irq (中断压力), %idle (空闲度平衡)
mpstat -P ALL "$INTERVAL" "$DURATION" > "$OUT_DIR/mpstat.txt" 2>&1 &

# 重点看: await (响应时间), %util (利用率), aqu-sz (队列长度)
iostat -sxz "$INTERVAL" "$DURATION" > "$OUT_DIR/iostat.txt" 2>&1 &

# 识别具体的CPU/IO消耗进程
pidstat "$INTERVAL" "$DURATION" > "$OUT_DIR/pidstat.txt" 2>&1 &

# 重点看: rxkB/txkB (吞吐量), retrans/s (重传率)
sar -n DEV,TCP,ETCP "$INTERVAL" "$DURATION" > "$OUT_DIR/sar_net.txt" 2>&1 &

# ── 3. 等待所有后台采样完成 ─────────────────────────────
wait
echo ">>> 性能扫描完成, 结果目录: $OUT_DIR"
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