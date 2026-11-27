# komari-next-pro-extension-go

Komari Next Pro 配套扩展的 **Go 重写版**：单个静态二进制，无 Node、无 CGO、无运行时依赖，专为 Alpine / OpenRC 这类精简环境准备。

前端接口契约（`/komari-ds-api/v1`）与 Node 版完全一致，播放列表、媒体库、节点任务、IP 质量查询都由同一个服务提供，主题侧无需改动。

## 特点

- **一个文件就是服务**：`CGO_ENABLED=0` 静态链接，amd64 约 9.7 MB、arm64 约 9.3 MB，空载常驻内存约 9 MB
- **不依赖 Node**：没有 `node_modules`、没有 npm 安装步骤，`scp` 上去就能跑
- **数据可复用**：直接打开 Node 版留下的 `komari-ds.db`，播放列表、媒体索引、任务记录都还在
- **SQLite 纯 Go 驱动**（`modernc.org/sqlite`）：不需要 `libsqlite3`、不需要 glibc 兼容层
- 内建 SSRF 防护、CSRF / Origin 校验、Range 媒体服务、任务去重与并发上限
- 可选 FFmpeg 转码：装了 FFmpeg 并配置路径即启用，否则接口自动降级

## 一键安装

```sh
curl -fsSL -o /tmp/kds-install.sh https://raw.githubusercontent.com/yu0o/komari-next-pro-extension-go/main/install.sh
sh /tmp/kds-install.sh
```

raw 访问受限时，给整条地址加加速前缀：

```sh
curl -fsSL -o /tmp/kds-install.sh "https://ghfast.top/https://raw.githubusercontent.com/yu0o/komari-next-pro-extension-go/main/install.sh"
sh /tmp/kds-install.sh
```

> 不要用 `curl ... | sh`：安装向导需要从终端读取端口、origin 等输入，管道会把 stdin 吃掉。先落盘再执行。

进入菜单后：

```
1) 安装 / 更新
2) 卸载
3) 设置 GitHub 加速地址
4) 查看状态
0) 退出
```

首次安装会依次完成：下载校验 → 建 `komari-ds` 系统用户 → 建数据目录 → 写服务配置（交互填 Komari 后端地址、站点 origin、端口）→ 注册并启动服务 → 探测 `/capabilities` 自检。

非交互 / 批量部署：

```sh
sh install.sh install --version v0.1.0 --mirror https://ghfast.top
sh install.sh uninstall            # 保留数据与配置
sh install.sh uninstall --purge    # 连数据、配置、用户一起删
sh install.sh status
```

## Release 资产约定

脚本按固定地址下载，因此每个 tag 的 Release 里至少要放这两个资产（文件名不要带版本号）：

| 资产 | 说明 |
| --- | --- |
| `komari-ds-extension-linux-amd64` | x86_64 静态二进制 |
| `komari-ds-extension-linux-arm64` | aarch64 静态二进制 |
| `SHA256SUMS`（建议） | `sha256sum komari-ds-extension-linux-* > SHA256SUMS` |

下载路径：

```
https://github.com/yu0o/komari-next-pro-extension-go/releases/download/<tag>/komari-ds-extension-linux-<arch>
```

已有 `SHA256SUMS` 时脚本逐个校验，缺失则跳过校验并提示。版本号默认取 `releases/latest`，取不到会提示手工输入 tag；仓库还没有 Release 时脚本会直接告诉你"未找到版本"，不会装出半个服务。

## 安装后的布局

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/komari-ds-extension` | 静态二进制 |
| `/var/lib/komari-ds` | `komari-ds.db` + `media/`，属主 `komari-ds`，权限 0750 |
| `/etc/conf.d/komari-ds` | OpenRC 环境变量配置 |
| `/etc/default/komari-ds` | systemd 环境变量配置 |
| `/var/log/komari-ds.log` | OpenRC 下的服务日志 |
| `/etc/komari-ds-installer.conf` | 脚本记住的加速前缀 |

服务名统一为 `komari-ds`，以 `komari-ds` 用户、`/var/lib/komari-ds` 为工作目录运行。

## 配置项

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DS_KOMARI_ORIGIN` | `http://127.0.0.1:25774` | Komari 后端地址，仅允许 http/https |
| `DS_PUBLIC_ORIGIN` | `http://127.0.0.1:5173` | 用户实际访问的站点 origin，写接口的 Origin 必须精确匹配 |
| `DS_DATA_DIR` | `.local/extension` | 数据目录，脚本安装时固定为 `/var/lib/komari-ds` |
| `DS_BIND` / `DS_PORT` | `127.0.0.1` / `5175` | 监听地址与端口，建议保持回环 + Nginx 反代 |
| `DS_ENABLE_JOBS` | `false` | 设为 `true` 才启用手动节点任务 |
| `DS_KOMARI_API_KEY` | 空 | 服务端密钥，仅用于执行任务，不下发浏览器 |
| `DS_IPAPI_KEY` | 空 | ipapi.is 质量查询密钥，仅服务端使用 |
| `DS_FFMPEG` | 空 | FFmpeg 路径，配置后开启转码接口，如 `/usr/bin/ffmpeg` |
| `DS_MAX_UPLOAD_MIB` | `100` | 单文件上传 / 导入上限（MiB） |

改完配置重启服务生效。

## 服务管理

Alpine / OpenRC：

```sh
rc-service komari-ds start|stop|restart|status
rc-update add komari-ds default
tail -f /var/log/komari-ds.log
```

systemd：

```sh
systemctl start|stop|restart|status komari-ds
journalctl -u komari-ds -f
```

## Nginx 反向代理

```nginx
location /komari-ds-api/ {
    proxy_pass http://127.0.0.1:5175;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 120m;
    proxy_request_buffering off;
    proxy_read_timeout 300s;
}
```

`DS_PUBLIC_ORIGIN` 必须与浏览器地址栏里的 origin 一字不差（含 `https`、含非默认端口），否则写接口返回"来源校验失败"。上传走流式转发，别让 Nginx 把请求体先缓存到磁盘。

## Caddy 反向代理

Caddy 自动签发证书，站点块里加一段转发即可。**用 `handle`，不要用 `handle_path`**：服务端路由本身带 `/komari-ds-api/v1` 前缀，剥掉前缀会全变 404。

与主题同域时：

```caddyfile
komari.example.com {
	encode zstd gzip

	handle /komari-ds-api/* {
		reverse_proxy 127.0.0.1:5175 {
			flush_interval -1
			transport http {
				dial_timeout 5s
				read_timeout 300s
			}
		}
	}

	handle {
		root * /var/www/komari
		file_server
	}
}
```

已有站点只需追加转发片段，放在兜底 `handle` 之前（Caddy 的 `handle` 按书写顺序匹配，先命中先赢）：

```caddyfile
	handle /komari-ds-api/* {
		reverse_proxy 127.0.0.1:5175 {
			flush_interval -1
			transport http {
				read_timeout 300s
			}
		}
	}
```

要点：

- `flush_interval -1` 关掉响应缓冲，媒体 Range 和任务轮询不会被攒包后才吐。
- Caddy 默认不限制请求体大小，相当于 Nginx 的 `client_max_body_size` 不限；要收紧就在站点块顶层加 `request_body { max_size 120MB }`。
- `X-Forwarded-For`、`X-Forwarded-Proto` 由 Caddy 自动添加，`Host` 默认透传，不用手写 `proxy_set_header` 那一串。
- 改完先校验再热加载：`caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`。

如果给扩展单独开子域：

```caddyfile
komari-ds.example.com {
	reverse_proxy 127.0.0.1:5175
}
```

此时 `DS_PUBLIC_ORIGIN` 仍要填**主题站点**的 origin，因为写接口校验的是浏览器页面的来源，不是这条转发域名。

## 从 Node 版迁移

1. 停掉旧的 Node 服务。
2. 备份数据目录里的 `komari-ds.db`（`cp komari-ds.db komari-ds.db.bak`）。
3. 用本脚本安装，把 `DS_DATA_DIR` 指到原数据目录，或把 `komari-ds.db` 和 `media/` 拷进 `/var/lib/komari-ds`。
4. 其余环境变量照旧，启动即接管；表结构一致，遗留的 `running` 任务在启动时会被标记为失败。

## 常见问题

**下载 404 / 一直失败**：该 tag 的 Release 里没有对应资产，或文件名带了版本号。按上面的资产约定重新上传，或在菜单里换一个加速前缀。

**`releases/latest` 取不到版本**：GitHub API 在该出口被限流时会自动回退到重定向解析；仍失败就 `--version v0.1.0` 手动指定。

**服务起不来**：先看 `/var/log/komari-ds.log` 或 `journalctl -u komari-ds`；多数是端口被占或数据目录权限不对（应属 `komari-ds:komari-ds`、0750）。

**日志里出现 `group 'komari-ds' not found`**：Alpine 的 busybox `adduser` 不会自动创建同名组。旧版脚本会踩到，重跑一次安装脚本即可自动重建账户；手动修复则是 `addgroup -S komari-ds && deluser komari-ds && adduser -S -D -H -s /sbin/nologin -G komari-ds komari-ds`，再 `chown komari-ds:komari-ds /var/lib/komari-ds`。

**前端报来源校验失败**：`DS_PUBLIC_ORIGIN` 写成了内网地址或漏了端口，改成用户实际访问的 origin。

**内存/磁盘**：空载 RSS 约 9 MB；任务输出上限 512 KB，任务记录保留 90 天自动清理。
