# vps-node-install

一键安装脚本：在全新 Ubuntu 服务器上装好 VLESS + Reality、Shadowsocks、Hysteria2 三个节点，并做好加固。

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lxin233/vps-node-install/main/install.sh)
```

或下载后运行：

```bash
bash install.sh
```

## 装完有什么

- VLESS + Reality，443 端口（TCP）
- Shadowsocks（2022-blake3-aes-128-gcm），8443 端口
- Hysteria2，443 端口（UDP）
- 加固：UFW 防火墙（只开 22/443/8443）、fail2ban（封 1 天）、自动更新（半夜跑）

跑完会打印三个节点的链接，导入 Shadowrocket 就能用。链接也保存在服务器 `/root/node-links.txt`。

## 注意

- 适用 Ubuntu 22.04 / 24.04，需 root 运行
- UUID 和密码每次运行都是新随机生成的，不要公开分享链接
