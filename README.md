# vps-traffic-report

监控多台 VPS 的月度网络流量，通过 Telegram Bot 查询和每日推送。

```
VPS 1 (Agent) ──POST /report──►
VPS 2 (Agent) ──POST /report──►  Central Server（Bot + SQLite）──► Telegram
VPS 3 (Agent) ──POST /report──►
```

- **Agent** — 部署在每台被监控的 VPS，读取 `/proc/net/dev`，定期将流量增量 POST 给 Central
- **Central** — 部署在任意一台机器，汇总数据，运行 Telegram Bot

---

## 安装文档

| 文档 | 说明 |
|------|------|
| [central/README.md](./central/README.md) | Central Server 安装指南（**先安装**） |
| [agent/README.md](./agent/README.md) | Agent 安装指南（每台被监控 VPS 各装一次） |

**安装顺序：先 Central，后 Agent。**

---

## 快速开始

在任意一台机器上运行：

```bash
wget -qO /tmp/vps.sh https://raw.githubusercontent.com/utada1stlove/vps-traffic-report/refs/heads/main/vps-traffic.sh && bash /tmp/vps.sh
```

或者克隆仓库后运行：

```bash
git clone https://github.com/utada1stlove/vps-traffic-report.git
sudo bash vps-traffic-report/vps-traffic.sh
```

脚本会显示交互式菜单，按需选择操作：

```
  ╔══════════════════════════════════════════╗
  ║       VPS 流量监控 — 管理脚本            ║
  ╚══════════════════════════════════════════╝

  Agent         : 未安装
  Central Server: 未安装

  ────────────────────────────────────────────
  1) 安装 Agent        （被监控 VPS 上运行）
  2) 安装 Central Server（接收数据 + Telegram Bot）
  3) 卸载 Agent
  4) 卸载 Central Server
  ────────────────────────────────────────────
  0) 退出
```

**部署顺序：先在一台机器选「2」装 Central，再在每台被监控 VPS 选「1」装 Agent。**

安装所需信息详见各组件文档：

---

## Bot 命令

| 命令 | 说明 |
|------|------|
| `/all` | 所有节点本月流量汇总 |
| `/<节点名>` | 单节点详细报告（如 `/tokyo-1`） |
| `/node <节点名>` | 同上 |
| `/start` | 显示帮助 |

---

## 卸载

重新运行管理脚本，选择「3」卸载 Agent 或「4」卸载 Central Server：

```bash
wget -qO /tmp/vps.sh https://raw.githubusercontent.com/utada1stlove/vps-traffic-report/refs/heads/main/vps-traffic.sh && bash /tmp/vps.sh
```

---

## 项目结构

```
vps-traffic.sh       ← 一键管理脚本（安装/卸载，内嵌所有源码）

agent/
  agent.py           主循环：采集流量 + POST 上报
  traffic_lib.py     读取 /proc/net/dev，计算增量，持久化状态
  .env.example       配置项说明
  README.md          Agent 详细文档

central/
  main.py            入口：启动 HTTP 服务线程 + Bot 主循环
  server.py          Flask HTTP 服务器，接收 POST /report
  bot.py             Telegram Bot，处理命令和定时推送
  store.py           SQLite 封装，按节点按月累计流量
  message.py         格式化 Telegram 消息
  .env.example       配置项说明
  README.md          Central 详细文档
```

---

## 技术说明

- 流量增量由 Agent 端计算，重启/网卡重置自动处理（计数器回绕检测）
- Agent 首次启动只记录基准值，不上报流量，避免虚报
- 月度计数在 Central 端随月份自动清零
- Bot 只响应 `TELEGRAM_CHAT_ID` 配置的用户/群组，拒绝其他来源
- HTTP 认证使用 Bearer Token + 常量时间比较（防时序攻击）
- 依赖：Agent 仅需 `requests`；Central 需 `flask` + `python-telegram-bot`
