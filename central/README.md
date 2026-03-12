# VPS Traffic Central Server

接收所有 Agent 上报的流量数据，存入 SQLite，并通过 Telegram Bot 提供查询和每日推送。

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux + systemd |
| Python | 3.8 及以上（安装脚本会自动检测并安装） |
| 权限 | root |
| 网络 | 能被所有 Agent 访问（开放对应端口）；能访问 Telegram API |
| 磁盘 | 极少（SQLite 数据库，按节点数和历史长度计） |

---

## 安装前准备

### 1. 创建 Telegram Bot

1. 在 Telegram 中打开 [@BotFather](https://t.me/BotFather)
2. 发送 `/newbot`，按提示命名
3. 复制返回的 **Bot Token**，格式：`123456789:ABCdef...`

### 2. 获取 Chat ID

1. 打开 [@userinfobot](https://t.me/userinfobot)，发送任意消息
2. 它会回复你的 **User ID**（即 Chat ID）
3. 如果要发送到群组，把 Bot 加入群组后发送 `/start`，然后访问：
   `https://api.telegram.org/bot<TOKEN>/getUpdates`
   在返回的 JSON 里找 `"chat":{"id": -100xxxxxxxxx}` （群组 ID 是负数）

### 3. 准备 API Secret

设置一个只有你知道的随机字符串，所有 Agent 都将使用它上报数据。

生成建议：
```bash
openssl rand -hex 32
# 示例输出：a3f8c2e1d4b7...（64位十六进制）
```

### 4. 确认端口可访问

安装完成后，Central 会监听一个 HTTP 端口（默认 `8080`），所有 Agent VPS 需要能访问它。

```bash
# 如果使用 ufw
ufw allow 8080/tcp

# 如果使用 firewalld
firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload

# 如果使用 iptables
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
```

> **安全提示**：HTTP 端口建议只对 Agent 所在 IP 开放，或将其置于内网。
> 若需要公网暴露，考虑在前面加一层 Nginx + HTTPS 反向代理。

---

## 安装步骤

```bash
# 1. 克隆仓库（或只下载 central/ 目录）
git clone https://github.com/yourname/vps-traffic-report.git
cd vps-traffic-report/central

# 2. 运行安装脚本
sudo bash install.sh
```

脚本会依次询问：

```
Telegram Bot Token:                               ← 输入时不回显
Telegram Chat ID:                                 ← 你的 User ID 或群组 ID
API Secret:                                       ← 输入时不回显
Server port [default: 8080]:                      ← 直接回车用默认值
Daily report time UTC HH:MM [default: 08:00]:     ← 每日推送时间（UTC）
```

> **时区说明**：每日报告时间为 **UTC 时间**。
> 北京时间 = UTC+8，若希望每天早上 8 点（北京时间）推送，填 `00:00`

安装脚本会自动完成：

1. 检测 Python 3.8+，若不存在则用包管理器安装
2. 创建 `/opt/vps-central/` 目录，复制程序文件
3. 写入 `/opt/vps-central/.env` 配置文件（权限 600）
4. 创建 Python 虚拟环境，安装 `flask`、`python-telegram-bot` 依赖
   （依赖较大，需要约 1 分钟）
5. 注册并启动 systemd 服务 `vps-central`
6. 打印 Agent 连接需要用到的 Central URL

安装完成后会看到：

```
[+] Central Server installed and running!

  HTTP port : 8080
  Daily rpt : 08:00 UTC

  Status : systemctl status vps-central
  Logs   : journalctl -u vps-central -f

  ── Next step ────────────────────────────────────────────
  On each Agent VPS, run agent/install.sh with:
    Central URL : http://1.2.3.4:8080
    API Secret  : (the secret you just entered)
```

---

## 验证安装

**方法一：查看服务日志**

```bash
journalctl -u vps-central -f

# 正常启动时日志示例：
# Initializing database…
# HTTP server started on 0.0.0.0:8080
# Starting Telegram Bot…
# Daily report scheduled at 08:00 UTC
```

**方法二：测试 HTTP 端口**

```bash
curl http://localhost:8080/health
# 期望返回：{"status":"ok"}
```

**方法三：给 Bot 发 /start**

在 Telegram 中向你的 Bot 发送 `/start`，应收到帮助信息。
若没有收到，检查 `TELEGRAM_CHAT_ID` 是否正确。

---

## Bot 命令

| 命令 | 说明 |
|------|------|
| `/start` | 显示帮助 |
| `/all` | 所有节点本月流量汇总 |
| `/<节点名>` | 某个节点的详细报告（如 `/tokyo-1`） |
| `/node <节点名>` | 同上 |

> Bot 只响应来自 `TELEGRAM_CHAT_ID` 的消息，其他人发送命令无任何响应。

---

## 常用操作

```bash
# 查看状态
systemctl status vps-central

# 实时日志
journalctl -u vps-central -f

# 停止
systemctl stop vps-central

# 启动
systemctl start vps-central

# 重启（修改配置后）
systemctl restart vps-central

# 查看当前配置
cat /opt/vps-central/.env

# 查看数据库（需要 sqlite3 命令）
sqlite3 /var/lib/vps-central/data.db "SELECT name,month,rx_month,tx_month FROM nodes;"
```

---

## 修改配置

```bash
nano /opt/vps-central/.env
systemctl restart vps-central
```

配置项说明：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `TELEGRAM_BOT_TOKEN` | Bot Token | 必填 |
| `TELEGRAM_CHAT_ID` | 接收消息的用户/群组 ID | 必填 |
| `API_SECRET` | 验证 Agent 上报的共享密钥 | 必填 |
| `SERVER_PORT` | HTTP 监听端口 | `8080` |
| `DAILY_REPORT_TIME` | 每日推送时间（UTC，`HH:MM`） | `08:00` |
| `OFFLINE_THRESHOLD` | 超过多少秒无上报视为离线（秒） | `300` |
| `DB_PATH` | SQLite 数据库路径 | `/var/lib/vps-central/data.db` |

---

## 卸载

```bash
sudo bash /opt/vps-central/uninstall.sh
```

脚本会询问是否同时删除 `/var/lib/vps-central/`（SQLite 数据库，含所有历史流量数据）。

**手动卸载（若脚本不可用）：**

```bash
systemctl stop vps-central
systemctl disable vps-central
rm /etc/systemd/system/vps-central.service
systemctl daemon-reload
rm -rf /opt/vps-central /var/lib/vps-central
```

---

## 故障排查

**问题：Bot 没有回复命令**

1. 确认 `TELEGRAM_CHAT_ID` 正确（不要填错成别人的 ID）
2. 检查日志有无 Telegram 相关报错：`journalctl -u vps-central -n 100`
3. 确认 Central Server 能访问 `api.telegram.org`（部分机房有封锁）

**问题：Agent 上报 401 Unauthorized**

Central 和 Agent 的密钥不一致。
- Central `.env` 里的 `API_SECRET`
- Agent `.env` 里的 `API_KEY`

两者必须完全相同（区分大小写）。

**问题：`/all` 返回 "No nodes registered yet"**

Agent 还没有成功上报过数据。检查：
1. Agent 服务是否在运行：`systemctl status vps-agent`（在 Agent VPS 上）
2. Central 端口是否开放：`curl http://CENTRAL_IP:PORT/health`
3. Agent 日志有无报错：`journalctl -u vps-agent -f`

**问题：每日报告没有按时发送**

- 确认时间填写的是 **UTC 时间**，不是本地时间
- 检查 `DAILY_REPORT_TIME` 格式是否为 `HH:MM`（如 `08:00`）
- Central Server 必须持续运行，重启后定时任务重新注册

**问题：依赖安装时间很长或失败**

`python-telegram-bot` 包较大（约 20MB），在网络较慢的 VPS 上可能需要几分钟。
如果 pip 安装失败：

```bash
# 使用国内镜像
/opt/vps-central/venv/bin/pip install \
    -i https://pypi.tuna.tsinghua.edu.cn/simple \
    flask 'python-telegram-bot[job-queue]'

# 然后重启服务
systemctl restart vps-central
```

---

## 安装路径一览

| 路径 | 内容 |
|------|------|
| `/opt/vps-central/main.py` | 入口程序 |
| `/opt/vps-central/server.py` | HTTP 服务器（接收上报） |
| `/opt/vps-central/bot.py` | Telegram Bot |
| `/opt/vps-central/store.py` | SQLite 封装 |
| `/opt/vps-central/message.py` | 消息格式化 |
| `/opt/vps-central/venv/` | Python 虚拟环境 |
| `/opt/vps-central/.env` | 配置文件（含 Token 和密钥，权限 600） |
| `/var/lib/vps-central/data.db` | SQLite 数据库 |
| `/etc/systemd/system/vps-central.service` | systemd 服务文件 |
