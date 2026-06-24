# linux-perf-in-60s

Linux 系统性能快速诊断工具集，包含两个互补脚本：

| 脚本 | 定位 | 核心方法 |
|------|------|----------|
| `perf-in-60s.sh` | **实时采样** — 当前正在发生什么 | 并行运行 vmstat/mpstat/iostat/pidstat/sar，采集实时趋势 |
| `perf-past.sh` | **历史回溯** — 过去发生过什么 | 读取 `/proc` 累积计数器 + 周期性 delta 采样 |

## 快速开始

```bash
# 实时性能扫描 (默认 10s)
sudo bash perf-in-60s.sh

# 历史性能回溯 + delta 采样 (默认 10s, 可自定义)
sudo bash perf-past.sh        # 10 秒 delta
sudo bash perf-past.sh 30     # 30 秒 delta
```

输出目录：

- `perf-in-60s.sh` → `/tmp/perf_scan_60s/`
- `perf-past.sh` → `/tmp/perf_scan_past/`

---

## 一、perf-in-60s.sh — 实时性能采样

基于 Brendan Gregg 的 **"Linux 60-Second Analysis"** 方法论。采集跨度能准确反映系统负载的真实趋势，并足以观察周期性系统活动（如每 30 秒一次的磁盘刷新）。

### 采集内容

**瞬时快照（立即完成）：**

1. `uptime` — 1/5/15 分钟负载趋势
2. `dmesg -T` — 最近 50 行内核日志
3. PSI — Pressure Stall Information (cpu/memory/io)
4. `free -m` — 内存分布
5. `slabtop` — 内核 Slab 缓存 Top 消费者

**并行采样（DURATION 秒）：**

1. `vmstat` — 重点看 r (运行队列), si/so (交换), st (偷取时间)
2. `mpstat -P ALL` — 重点看 %soft/%irq, 各核均衡度
3. `iostat -sxz` — 重点看 await (响应时间), %util (利用率)
4. `pidstat` — 定位具体的 CPU/IO 消耗进程
5. `sar -n DEV,TCP,ETCP` — 网络吞吐 + 重传率

### 补强建议

- **VM 环境**：关注 `vmstat`/`mpstat` 中的 `st` (Stolen Time)
- **容器环境**：PSI 是衡量资源压力（饱和度）最直接的指标
- **调度压力**：`sar -w` 观察进程创建速率，`mpstat -I SUM` 观察中断分布
- **深度网络**：`nstat -s` 或 `sar -n ETCP` 观察 `TcpRetransSegs` (重传)

---

## 二、perf-past.sh — 历史性能回溯

适用场景：性能问题**已经发生过**，通过累积错误计数器回溯历史异常，同时通过 delta 采样确认问题是否仍在持续。

### 13 个采集模块

| # | 模块 | 数据源 | 关键指标 |
|---|------|--------|----------|
| 1 | 系统基本信息 | uptime, uname, who -b | 运行时长、负载趋势、启动时间 |
| 2 | 网络协议栈计数器 | nstat -as, /proc/net/snmp, /proc/net/netstat, ss -s | TcpRetransSegs, TcpInErrs, UdpInErrors, ListenDrops |
| 3 | 网卡接口错误 | ip -s link, /proc/net/dev | rx_errors, tx_errors, drops, overruns |
| 4 | conntrack | conntrack -S, nf_conntrack count/max | drop, early_drop, error |
| 5 | 磁盘 I/O | iostat -xz, /proc/diskstats, /sys ioerr_cnt | 累积读写、I/O 错误计数 |
| 6 | SMART 健康 | smartctl -a | Reallocated_Sector, Pending_Sector, Uncorrectable |
| 7 | 内存/Swap/OOM | free, /proc/vmstat, numastat, dmesg | pswpin/out, pgfault, oom_kill, allocstall |
| 8 | 内核错误事件 | dmesg grep | error, panic, lockup, MCE, hung_task, segfault |
| 9 | CPU 调度 & 硬件 | /proc/stat, MCE, /proc/interrupts, throttle | jiffies, ctxt, processes, ERR/MIS, 降频事件 |
| 10 | 文件系统错误 | mount, ext4 errors_count, xfs error stats | readonly 降级, 累积错误计数 |
| 11 | softnet 统计 | /proc/net/softnet_stat (hex) | dropped, time_squeeze |
| 12 | sar 归档 | /var/log/sa 或 /var/log/sysstat | 历史 sar 数据可用性 |
| 13 | **Delta 采样** | T0 → sleep → T1 → 计算 Δ | 见下表 |

### Delta 采样覆盖

Delta 模块在 `DURATION` 秒窗口内计算增量和速率，输出格式：`指标  绝对值=xxx  Δ=xxx  速率=xxx/s`

| 维度 | Delta 指标 |
|------|-----------|
| TCP/IP | TcpRetransSegs, TcpInErrs, TcpOutRsts, TcpAttemptFails, TcpEstabResets |
| UDP/IP | UdpInErrors, InDiscards, OutDiscards, InAddrErrors |
| TCP 扩展 | ListenDrops, ListenOverflows, TCPBacklogDrop |
| 内存 | pswpin, pswpout, pgfault, pgmajfault, oom_kill |
| CPU 调度 | context_switches, forks |
| 磁盘 | 每设备 reads/writes/read_ms/write_ms (支持 sd/vd/xvd/hd/nvme/dm-) |
| 网卡 | 每接口 rx_errors/rx_drops/tx_errors/tx_drops |
| softnet | 每 CPU processed/dropped/time_squeeze |

### 内核兼容性

脚本对字段数动态自适应，兼容不同内核版本：

| 数据源 | 内核字段差异 | 处理方式 |
|--------|-------------|----------|
| `/proc/diskstats` | 14 列 (≤4.18) / 18 列 / 20 列 (5.5+) | `half = int(NF/2)` 动态偏移 |
| `/proc/net/softnet_stat` | 3 / 9 / 11 / 13 列 | 同上 |
| `/proc/net/dev` | 固定 16 计数器 + 接口名 | 硬编码 34 列 (paste 后) |

---

## 三、发现异常后的 Debug 指向表

脚本运行结束后，若发现某些指标异常，转向更深层的 **BPF/追踪工具**：

| 发现的异常现象 | 建议使用的下一步 Debug 工具 |
| :--- | :--- |
| **`vmstat r > CPU核数` 或 `runq-sz` 高** | **`runqlat`** 查看调度延迟分布直方图 |
| **`iostat await > 10ms` 或 `%util` 持续 100%** | **`biolatency`** 查看磁盘延迟分布，**`biosnoop`** 追踪具体 PID |
| **`sar retrans/s` 非零且递增** | **`tcpretrans`** 实时显示重传包地址和 TCP 状态 |
| **`st (Stolen Time)` 明显非零** | 宿主机层面检查虚拟化资源超卖 |
| **系统 CPU (`sy`) 时间过高** | **`syscount`** 统计系统调用频率，**`profile`** 生成火焰图 |
| **短寿命进程频繁出现** | **`execsnoop`** 捕捉所有 `execve()` 调用 |
| **ListenDrops/Overflows 持续递增** | **`ss -lntp`** 检查 backlog 配置，调整 `net.core.somaxconn` |
| **softnet dropped 非零** | 增加 `net.core.netdev_budget`，启用 RPS/RFS 分散中断 |
| **pswpin/pswpout 持续递增** | **`cachestat`** / **`swapin`** 追踪换页热点进程 |
| **MCE/硬件错误** | `mcelog --client`，检查 DIMM/CPU 物理位置，准备换件 |

通过 **"perf-in-60s.sh 实时扫描 → perf-past.sh 历史回溯 → BPF 工具深入追踪"** 三层组合，完成从**"发现异常"→"确认历史"→"定位根因"**的完整诊断流程。
