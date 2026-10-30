# PiggyPal 协作约定

## 发布：必须显式同意

任何形式的「发出去」动作，都必须先拿到用户**明确说出口的同意**，一次授权只覆盖那一次动作。

需要事先同意的动作包括：

- 服务端部署：`ssh` 上去换二进制、`systemctl restart/stop piggy-pal`、改线上 `config/`、跑数据库迁移
- 客户端发布：改版本号、`./release_apk.sh`、更新 `latest.json`（会让所有设备弹更新提示）
- 推送 / 打 tag / 改远端分支
- 启停线上 timer、改告警配置、动备份任务

**禁止推测意图**，尤其是这些推断：

- 「客户端晚点发」≠「服务端可以先发」
- 「这个改动很小」≠「可以先上」
- 「用户之前同意过类似的事」≠「这次也同意」
- 「先发再回滚也行」≠「可以发」

不确定的时候就问，问一句的成本远低于一次误发。

## 可以自己做的事

- 读代码、读日志、读线上只读状态（`systemctl status`、`sqlite3` 查询、`/healthz`）
- 本地改代码、跑测试、写文档
- 生成待确认的方案，等用户点头再执行

## 线上环境

**真实地址不入库。** 服务器 IP、域名、ssh 用户只写在仓库根目录的 `deploy.env`（已 gitignore），
模板见 `deploy.env.example`。仓库里所有文档一律用占位符 `203.0.113.10` / `piggy.example.com`。

需要连服务器时先读 `deploy.env`：

```sh
set -a; . ./deploy.env; set +a
ssh "$PIGGYPAL_USER@$PIGGYPAL_SERVER"
```

- 安装目录 `/opt/piggy-pal`，数据库 `data/app.db`，日志 `/var/log/piggy-pal/server.log`
- 运维巡检说明见 `docs/运维巡检.md`

## 开源约定

这个仓库计划开源，**任何个人信息都不能进代码**（本机路径、真实 IP、域名、邮箱、账号名、孩子姓名等）。

- 需要配置的值一律走环境变量 + `*.example` 模板，真实文件 gitignore
- 脚本里禁止写死绝对路径（用 `command -v` / `$HOME` / 环境变量）
- 构建加 `-trimpath`，别把开发机目录写进二进制和日志
- 提交前自查：`git grep -nE "/Users/|@[a-z0-9.-]+\.(com|cn)|([0-9]{1,3}\.){3}[0-9]{1,3}"`
