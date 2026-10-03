# FastGuard 云端账户后端

独立部署的 Flask 账户服务，为 FastGuard 桌面端提供登录与注册校验。
桌面端 [auth/cloud.py](../auth/cloud.py) 通过 `data/cloud_auth.json` 中配置的路径访问本服务。

## 快速开始

```bash
cd cloud_backend
pip install -r requirements.txt
copy .env.example .env      # 按需修改端口与管理员账号
python app.py               # 或双击 run_backend.bat
```

默认监听 `http://127.0.0.1:1444`。首次启动会自动建库并创建预置管理员
（默认 `admin` / `Admin123`，可用 `.env` 覆盖；密码以 Werkzeug 加盐哈希存储）。

## 接口

| 方法 | 路径 | 请求体 | 响应 |
|------|------|--------|------|
| GET | `/` | — | `{"service": "FastGuard Cloud Auth", "status": "ok"}`（客户端连通性探测） |
| GET | `/api/fastguard/health` | — | `{"success": true, "status": "ok", "users": 3}` |
| POST | `/api/fastguard/auth/login` | `{"username": "...", "password": "..."}` | `{"success": true, "role": "admin"}` 或 `{"success": false, "message": "..."}` |
| POST | `/api/fastguard/auth/register` | `{"username": "...", "password": "..."}` | `{"success": true}` / 400 参数不合法 / 409 用户名已存在 |

登录与注册的状态码约定（与客户端一致）：

- 登录**始终返回 200**，用 `success` 字段表达结果，避免客户端把 HTTP 错误误判为“后端不可用”而跳过登录。
- 注册用 400 / 409 表达参数错误与重名；客户端将其视为“注册被拒绝”。
- 服务端保持 JSON 响应，5xx 仅在内部异常时出现。

## 账号规则

- 用户名：3-32 位字母、数字、下划线或中文，不可重复
- 密码：至少 6 位，使用 `werkzeug.security` 加盐哈希存储，不落明文
- 新注册账号角色固定为 `user`；仅预置管理员为 `admin`
- 登录失败限流：同一 IP + 用户名连续失败 5 次后锁定 300 秒（可配置）

## 部署到云端

1. 复制 `cloud_backend/` 到服务器，安装依赖
2. `.env` 中设置 `FASTGUARD_HOST=0.0.0.0`、`FASTGUARD_PORT=1444`，并务必修改 `FASTGUARD_ADMIN_PASSWORD`
3. 用 systemd / supervisor / nssm 托管 `python app.py`；生产环境建议置于 Nginx 反向代理之后并启用 HTTPS
4. 桌面端 `data/cloud_auth.json` 的 `base_url` 改为服务器地址（本机自测填 `http://127.0.0.1:1444`，云端填 `https://your-host`），`login_path` / `register_path` 保持默认即可

## 说明

- 端口冲突：同一端口同一时刻只能有一个进程监听；FastGuard 桌面端不监听任何端口，因此可独占 1444。若与其他服务冲突，改 `FASTGUARD_PORT` 并同步桌面端 `cloud_auth.json` 的 `base_url`
- 调试模式 `FASTGUARD_DEBUG=true` 会启用重载器并额外占用进程，绑定固定端口时请保持关闭
- 后端不可访问时，桌面端会按设计跳过登录并直接进入本地系统
