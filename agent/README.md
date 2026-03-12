# VPS Traffic Agent

采集本机网卡流量，定期上报给 Central Server。

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（需要 `/proc/net/dev`） |
| Python | 3.8 及以上（安装脚本会自动检测并安装） |
| 权限 | root（读 `/proc/net/dev` 无需，但写 systemd 服务需要） |
| 网络 | 能访问 Central Server 的 HTTP 端口 |

常见发行版参考：

- Ubuntu 20.04 — Python 3.8 ✓
- Ubuntu 22.04 / 24.04 — Python 3.10 / 3.12 ✓
- Debian 11 / 12 — Python 3.9 / 3.11 ✓
- CentOS 8 / AlmaLinux 8 — Python 3.8 ✓

---

## 安装前准备

在安装 Agent 之前，**Central Server 必须已经在运行**，并且你需要准备好以下信息：

| 需要 | 说明 | 示例 |
|------|------|------|
| Central URL | Central Server 的地址和端口 | `http://1.2.3.4:8080` |
| 节点名称 | 这台 VPS 的标识，在 Bot 命令中使用 | `tokyo-1`、`us-east` |
| API Secret | 与 Central Server 约定的共享密钥 | 部署 Central 时设置的值 |

> **节点名称注意事项**
> - 只使用字母、数字、连字符（`-`）、下划线（`_`）
> - 不要含空格或特殊字符，因为它会直接用作 Telegram Bot 命令（`/tokyo-1`）
> - 建议使用有意义的名字，方便日后区分

---

## 安装步骤

```bash
# 1. 克隆仓库（或只下载 agent/ 目录）
git clone https://github.com/yourname/vps-traffic-report.git
cd vps-traffic-report/agent

# 2. 运行安装脚本
sudo bash install.sh
```

脚本会依次询问：

```
Central Server URL (e.g. http://1.2.3.4:8080):   ← Central 地址
Node name for this VPS (e.g. vps1, tokyo-1):       ← 节点名
API Secret:                                          ← 输入时不回显
Network interface [default: eth0]:                  ← 直接回车用默认值
Report interval in seconds [default: 60]:           ← 直接回车用默认值
```

安装脚本会自动完成：

1. 检测 Python 3.8+，若不存在则用包管理器安装
2. 创建 `/opt/vps-agent/` 目录，复制程序文件
3. 写入 `/opt/vps-agent/.env` 配置文件（权限 600）
4. 检测网卡是否存在，若不存在提示自动识别默认路由网卡
5. 创建 Python 虚拟环境，安装 `requests` 依赖
6. 注册并启动 systemd 服务 `vps-agent`

安装完成后会看到：

```
[+] Agent installed and running!

  Node name : tokyo-1
  Interface : eth0
  Interval  : 60s
  Central   : http://1.2.3.4:8080

  Status : systemctl status vps-agent
  Logs   : journalctl -u vps-agent -f
```

---

## 验证安装

```bash
# 查看服务状态
systemctl status vps-agent

# 实时查看日志
journalctl -u vps-agent -f

# 正常启动时日志示例：
# Agent starting — node=tokyo-1 interface=eth0 interval=60s
# First run on eth0 — saving baseline (rx=... tx=...)
# Reported to http://1.2.3.4:8080 — rx_delta=0.0B tx_delta=0.0B
```

> **首次上报 delta=0 是正常的**
> Agent 第一次启动时只保存当前计数器基准值，不上报任何流量，从第二个周期开始才上报真实增量。

---

## 常用操作

```bash
# 查看状态
systemctl status vps-agent

# 实时日志
journalctl -u vps-agent -f

# 停止
systemctl stop vps-agent

# 启动
systemctl start vps-agent

# 重启（修改配置后）
systemctl restart vps-agent

# 查看配置
cat /opt/vps-agent/.env
```

---

## 修改配置

直接编辑 `.env` 文件，然后重启服务：

```bash
nano /opt/vps-agent/.env
systemctl restart vps-agent
```

配置项说明：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CENTRAL_URL` | Central Server 地址 | 必填 |
| `NODE_NAME` | 节点名称 | 必填 |
| `API_KEY` | 共享密钥 | 必填 |
| `NETWORK_INTERFACE` | 监控的网卡名 | `eth0` |
| `REPORT_INTERVAL` | 上报间隔（秒） | `60` |
| `REQUEST_TIMEOUT` | HTTP 超时（秒） | `10` |
| `STATE_FILE` | 流量状态持久化文件路径 | `/var/lib/vps-agent/state.json` |

---

## 网卡名称查看

不确定网卡名称时：

```bash
# 方法一：查看所有网卡
ip link show

# 方法二：查看默认路由使用的网卡
ip route | grep default
# 输出示例：default via 10.0.0.1 dev eth0 proto dhcp
#                                      ^^^^

# 常见网卡名：
# eth0, ens3, ens18, enp1s0, venet0 (OpenVZ)
```

---

## 卸载

```bash
sudo bash /opt/vps-agent/uninstall.sh
```

脚本会询问是否同时删除 `/var/lib/vps-agent/`（流量基准状态文件）。

**手动卸载（若脚本不可用）：**

```bash
systemctl stop vps-agent
systemctl disable vps-agent
rm /etc/systemd/system/vps-agent.service
systemctl daemon-reload
rm -rf /opt/vps-agent /var/lib/vps-agent
```

---

## 故障排查

**问题：服务启动失败**

```bash
journalctl -u vps-agent -n 50 --no-pager
```

常见原因：
- `CENTRAL_URL` 填写错误或 Central Server 未启动 → 检查 URL 和端口
- `API_KEY` 与 Central 的 `API_SECRET` 不一致 → 检查两边配置
- 网卡名称不正确 → `ip link show` 查看正确名称后修改 `.env`

**问题：日志显示 `Interface 'eth0' not found`**

```bash
# 查看实际网卡名
ip link show
# 修改配置
nano /opt/vps-agent/.env  # 修改 NETWORK_INTERFACE=
systemctl restart vps-agent
```

**问题：服务正常但 Central 收不到数据**

```bash
# 手动测试连通性
curl -X POST http://YOUR_CENTRAL:8080/report \
  -H "Authorization: Bearer YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"node":"test","timestamp":1,"rx_delta":0,"tx_delta":0}'
# 期望返回：{"status":"ok"}
```

**问题：重装后流量数据从 0 开始**

卸载时选择了删除 `/var/lib/vps-agent/`，状态文件被清除，下次启动视为首次运行。这是正常行为。

---

## 安装路径一览

| 路径 | 内容 |
|------|------|
| `/opt/vps-agent/agent.py` | 主程序 |
| `/opt/vps-agent/traffic_lib.py` | 流量读取库 |
| `/opt/vps-agent/venv/` | Python 虚拟环境 |
| `/opt/vps-agent/.env` | 配置文件（含密钥，权限 600） |
| `/var/lib/vps-agent/state.json` | 网卡计数器基准值（持久化） |
| `/etc/systemd/system/vps-agent.service` | systemd 服务文件 |
