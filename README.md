# MurrCloud 17

## 阿里云 Ubuntu 24.04 安装指南（生产稳定版）

> 适用于：阿里云 ECS · Ubuntu 24.04  
> 部署方式：systemd（非 Docker，官方生产推荐）

---

## 一、部署思路（必读）

**推荐流程：**

Mac  
→ 打包源码 `tar.gz`  
→ 上传到阿里云 OSS  
→ ECS 内网 `wget` 下载  
→ `systemd` 启动服务

**为什么这样做？**

- 避免 `scp / rsync`（文件多、易中断）
- OSS 内网下载速度最快、最稳定
- `systemd` 更贴近 Odoo 官方生产部署方式
- 出问题可直接通过日志定位

---

## 二、前置条件

### 服务器

- Ubuntu 24.04（阿里云 ECS）
- 已开放端口：
  - 22（SSH）
  - 8069（MurrCloud / Odoo）

### 源码结构

```text
murrcloud17/
├── murrcloud-bin
├── murrcloud/
│   └── addons/
├── requirements.txt
├── setup.py
└── ...
```

---

## 三、Mac：打包源码

```bash
cd ~/Desktop
tar --exclude='.git' --exclude='**/.DS_Store'     -czf murrcloud17.tar.gz murrcloud17
ls -lh murrcloud17.tar.gz
```

---

## 四、OSS 上传与 ECS 下载

### 上传

- Bucket 与 ECS 同地域
- 上传 `murrcloud17.tar.gz`
- 生成 ≥1 小时临时 URL

### ECS 下载

```bash
sudo -i
cd /root
wget -O murrcloud17.tar.gz "你的 OSS 临时 URL"
```

### 解压

```bash
mkdir -p /opt/murrcloud/src
tar -xzf murrcloud17.tar.gz -C /opt/murrcloud/src/
ls /opt/murrcloud/src/murrcloud17
```

---

## 五、系统依赖

```bash
apt update && apt -y upgrade

apt install -y   python3 python3-venv python3-dev python3-pip   build-essential pkg-config   libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libssl-dev   libpq-dev libjpeg-dev zlib1g-dev libffi-dev   postgresql postgresql-contrib   nginx wkhtmltopdf
```

---

## 六、系统用户与目录

```bash
adduser --system --home=/opt/murrcloud --group murrcloud || true

mkdir -p /opt/murrcloud/{config,log,custom-addons,venv}
chown -R murrcloud:murrcloud /opt/murrcloud
chown -R murrcloud:murrcloud /opt/murrcloud/src/murrcloud17
```

---

## 七、PostgreSQL

```bash
sudo -u postgres createuser -s murrcloud || true
```

---

## 八、Python 虚拟环境

```bash
sudo -u murrcloud python3 -m venv /opt/murrcloud/venv
sudo -u murrcloud /opt/murrcloud/venv/bin/pip install --upgrade pip wheel setuptools
sudo -u murrcloud /opt/murrcloud/venv/bin/pip install -r   /opt/murrcloud/src/murrcloud17/requirements.txt
```

---

## 九、确认 addons 路径

```bash
find /opt/murrcloud/src/murrcloud17 -type d -name addons
```

正确路径：

```text
/opt/murrcloud/src/murrcloud17/murrcloud/addons
```

---

## 十、配置文件

```bash
nano /opt/murrcloud/config/murrcloud.conf
```

```ini
[options]
admin_passwd = CHANGE_ME

db_host = False
db_port = False
db_user = murrcloud
db_password = False

addons_path = /opt/murrcloud/src/murrcloud17/murrcloud/addons,/opt/murrcloud/custom-addons

logfile = /opt/murrcloud/log/murrcloud.log

xmlrpc_port = 8069
longpolling_port = 8072

proxy_mode = True
workers = 2
max_cron_threads = 1
```

```bash
chown murrcloud:murrcloud /opt/murrcloud/config/murrcloud.conf
chmod 640 /opt/murrcloud/config/murrcloud.conf
```

---

## 十一、systemd 服务

```bash
cat > /etc/systemd/system/murrcloud.service <<'EOF'
[Unit]
Description=MurrCloud 17
After=network.target postgresql.service

[Service]
User=murrcloud
Group=murrcloud
WorkingDirectory=/opt/murrcloud/src/murrcloud17
ExecStart=/opt/murrcloud/venv/bin/python3 /opt/murrcloud/src/murrcloud17/murrcloud-bin -c /opt/murrcloud/config/murrcloud.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
```

```bash
systemctl daemon-reload
systemctl enable murrcloud
systemctl start murrcloud
systemctl status murrcloud --no-pager
```

---

## 十二、访问

```text
http://SERVER_IP:8069
```

---

## 十三、常见问题

| 问题 | 原因 | 解决 |
|---|---|---|
| 500 错误 | addons_path 错误 | 使用真实 addons 目录 |
| pkg_resources 报错 | 缺 setuptools | pip install setuptools |
| 服务重启 | 依赖缺失 | 查看 journalctl |

```bash
journalctl -u murrcloud -n 200 --no-pager
tail -n 200 /opt/murrcloud/log/murrcloud.log
```

---

## 总结

**OSS 传包 → 正确 addons_path → setuptools → systemd**  
这是 MurrCloud / Odoo 17 在 Ubuntu 24.04 上最稳定的部署方案。
