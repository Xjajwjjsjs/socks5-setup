# SOCKS5 一键部署

在任意 Linux VPS 上一键部署 SOCKS5 代理节点，自动检测系统，随机端口/密码，开箱即用。

## 🚀 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xjajwjjsjs/socks5-setup/main/install.sh)
```

安装过程中可自定义端口、用户名、密码，直接回车则随机生成。

## 📋 功能

- ✅ 自动检测系统（Ubuntu/Debian/CentOS/Rocky/Alpine/Arch 等）
- ✅ 自动检测架构（amd64/arm64/armv7）
- ✅ 用户名 + 密码认证
- ✅ 随机端口 & 密码（可自定义）
- ✅ 开机自启（systemd）
- ✅ 自动放行防火墙（ufw/firewalld/iptables）
- ✅ 多用户管理
- ✅ 一键卸载
- ✅ 安装完成输出 `socks5://` 连接链接

## 🔧 管理命令

安装完成后可使用 `socks5` 命令管理：

```bash
socks5 info        # 查看连接信息
socks5 status      # 查看服务状态
socks5 start       # 启动服务
socks5 stop        # 停止服务
socks5 restart     # 重启服务
socks5 add         # 添加用户
socks5 del         # 删除用户
socks5 list        # 查看用户列表
socks5 uninstall   # 一键卸载
```

## 📦 技术栈

- 底层代理: [gost v3](https://github.com/go-gost/gost) — 轻量单二进制文件
- 服务管理: systemd
- 配置格式: YAML

## 🖥️ 支持系统

| 系统 | 版本 | 状态 |
|------|------|------|
| Ubuntu | 18.04+ | ✅ |
| Debian | 10+ | ✅ |
| CentOS | 7+ | ✅ |
| Rocky Linux | 8+ | ✅ |
| AlmaLinux | 8+ | ✅ |
| Fedora | 36+ | ✅ |
| Alpine | 3.15+ | ✅ |
| Arch Linux | latest | ✅ |

支持架构: `amd64` `arm64` `armv7`

## 📖 使用示例

### 安装

```
$ bash <(curl -fsSL https://raw.githubusercontent.com/Xjajwjjsjs/socks5-setup/main/install.sh)

╔═══════════════════════════════════════╗
║     SOCKS5 一键部署脚本               ║
╚═══════════════════════════════════════╝

[i] 检测到系统: ubuntu 22.04 (包管理器: apt)
[i] 检测到架构: amd64
[✓] 依赖安装完成
[?] 端口 (回车随机 34521):
[?] 用户名 (回车随机 user_a3Kx):
[?] 密码 (回车随机):
[i] 开始安装...
[✓] gost 下载完成
[✓] ufw 已放行端口 34521
[✓] 服务已启动并设置开机自启

═══════════════════════════════════════════
  ✓ 安装完成!
═══════════════════════════════════════════

  服务器:  1.2.3.4
  端口:    34521
  用户名:  user_a3Kx
  密码:    xK9mP2vL8nQw5rT1

  连接链接:
  socks5://user_a3Kx:xK9mP2vL8nQw5rT1@1.2.3.4:34521

═══════════════════════════════════════════
  管理命令: socks5 help
═══════════════════════════════════════════
```

### 测试连接

```bash
curl -x socks5://user:pass@ip:port https://httpbin.org/ip
```

## ⚠️ 注意事项

- 需要 root 权限运行
- 确保 VPS 安全组/面板防火墙已放行对应端口
- 建议使用强密码

## 📄 License

MIT


