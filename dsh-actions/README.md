# dsh-actions 维护者手册

这里的脚本由 `.github/workflows/dsh-web.yml` 和 `dsh-stop.yml` 调用，负责两件事：

1. **状态**：把 `DSH_HOME` / `DSH_WORKSPACE` 保存为私有 release 快照，并在下次运行时恢复。
2. **进程**：启动 Caddy basic auth 代理和 `dsh web`，发布固定访问 URL，监控磁盘/停止信号，结束时 final save。

面向使用者的安装步骤见 [../README.md](../README.md)。本文是实现契约和运维手册；接口以最终脚本为准。

> 本文按 `PLAN.md` 编写。脚本仍在实现中时，若参数名、默认值或调用方式有调整，以脚本和 workflow 为准，合并前由 Lead 统一校对。

## 1. 文件与职责

| 文件 | 职责 |
| --- | --- |
| `state.sh` | `state` 分支、`dsh-state` release 快照、冷会话归档、锁、URL 发布、STOP 检查 |
| `sync-excludes.txt` | home/work 共用的 rsync 排除规则，`state.sh` 唯一排除来源 |
| `run.sh` | cloudflared + Caddy basic auth + dsh + session archive agent supervisor、checkpoint、磁盘保护、优雅停止 |
| `session-archive-agent.mjs` | 冷会话归档的下载、sha256 校验、解压和替换 stub |
| `tests/session-archive-test.sh` | `archive_cold_sessions` 的热/冷、stub、索引、复用逻辑测试 |
| `tests/session-archive-agent-test.mjs` | agent 下载/校验/恢复的端到端测试（fake `gh`） |
| `../dsh-session-archive/` | host 插件 `@dsh-web/session-archive` |
| `../dsh-session-archive.overlay.yml` | 将插件插入 web profile 的 overlay |
| `../.github/workflows/dsh-web.yml` | 启动、安装固定版本、scratch 选择、init/run 超时、汇总 |
| `../.github/workflows/dsh-stop.yml` | 写 `DSH_STOP`、等待、兜底 cancel、清理变量 |
| `../.github/workflows/session-archive-test.yml` | 手动运行归档和 agent 测试 |

## 2. 运行时契约

### 2.1 路径

| 变量 | 值 | 用途 |
| --- | --- | --- |
| `DSH_HOME` | `/home/runner/dsh-home` | dsh 配置、会话、附件、skills |
| `DSH_WORKSPACE` | `/home/runner/work1` | 工作区 |
| `DSH_SCRATCH` | 自动选择 | 最大可写挂载点，优先 `/mnt`（必要时 `/mnt/dsh-scratch`） |
| `TMPDIR`/`TMP`/`TEMP` | `$DSH_SCRATCH/dsh-tmp` | 临时文件 |
| `STATE_CLONE` | `$DSH_SCRATCH/dsh-state` | 私有状态仓库临时克隆 |
| `RUN_DIR` | `$DSH_SCRATCH/run` | 日志、`Caddyfile`、`url.txt`、打包 staging |

scratch 选择规则：候选挂载点必须同时满足 **≥20GB 可用空间**和 **≥5% 可用 inode**；优先 `/mnt`，`/mnt` 不可写时尝试 `/mnt/dsh-scratch`，否则 `/home/runner`。都不满足时工作流失败，除非设置仓库变量 `DSH_ALLOW_SMALL_SCRATCH=true`（仅用于调试，5GB 状态可能写满根盘）。

`RUN_DIR` 内主要有：

- `dsh-web.log`（0600）：dsh 的 stdout/stderr；dsh 会打印带 process token 的 URL，文件只在 runner 本地。
- `cloudflared.log`（0600）：隧道日志。
- `caddy.log`（0600）：Caddy 启动/校验/错误日志。
- `Caddyfile`（0600）：Caddy basic auth 配置，含 bcrypt hash 和本次 dsh token；不进状态快照。
- `state.log`（0600）：所有 `state.sh` 调用的输出。
- `auto-restart.log`（0600）：自动重启 dispatch 的输出。
- `session-archive.log`（0600）：归档 agent 的下载/恢复日志。
- `session-archive.sock`（0600）：插件调用 agent 的本地 Unix socket。
- `url.txt`（0600）：固定公开 URL，不含 token。
- `meta.json`：若存在，`publish-url` 会同步到控制分支；常规情况下由 `save` 更新控制分支的 meta。
- `state/`：`rsync` staging、冷归档临时文件和打包临时目录。

### 2.2 环境变量

workflow 和脚本之间共享的变量：

| 变量 | 默认 | 消费方 | 说明 |
| --- | --- | --- | --- |
| `DSH_HOME` | `/home/runner/dsh-home` | 两者 | 快照源/恢复目标 |
| `DSH_WORKSPACE` | `/home/runner/work1` | 两者 | 快照源/恢复目标 |
| `DSH_SCRATCH` | 自动选择 | 两者 | 临时/状态/日志的根挂载点 |
| `STATE_REPO` | 无（必填 variable） | `state.sh`、`dsh-stop` | 私有状态仓库 |
| `STATE_REPO_TOKEN` | 无（secret） | `state.sh`、`dsh-stop` | 状态仓库 PAT，不得打印 |
| `STATE_CLONE` | `$DSH_SCRATCH/dsh-state` | `state.sh` | 控制分支克隆 |
| `RUN_DIR` | `$DSH_SCRATCH/run` | 两者 | 运行文件 |
| `GITHUB_RUN_ID` | 由 Actions 注入 | 两者 | 锁和 STOP 匹配 |
| `GITHUB_REPOSITORY` | 由 Actions 注入 | `run.sh` | 自动重启目标 |
| `GITHUB_REF_NAME` | 由 Actions 注入 | `run.sh` | 自动重启的 ref |
| `STATE_BUDGET_MB` | `5120` | `state.sh` | 原始状态硬预算 |
| `STATE_WARN_MB` | `3072` | `state.sh` | 软告警 |
| `STATE_ASSET_PART_MB` | `1900` | `state.sh` | 分卷大小 |
| `STATE_KEEP_SNAPSHOTS` | `2` | `state.sh` | 保留快照数 |
| `STATE_MIN_FREE_MB` | `5120` | `state.sh` | 恢复/保存前的最小剩余空间 |
| `DSH_PERSIST_CREDENTIALS` | `true` | `state.sh` | 是否把 `.credentials.yaml` 纳入快照；恢复后 chmod 0600 |
| `SESSION_ARCHIVE_ENABLED` | `true` | `state.sh`、`run.sh` | 冷会话归档开关；插件未就绪时本次运行强制关闭 |
| `SESSION_HOT_MAX` | `50` | `state.sh` | 保留完整日志的最近会话数 |
| `SESSION_HOT_DAYS` | `30` | `state.sh` | 保留完整日志的最近天数 |
| `SESSION_ARCHIVE_MIN_AGE_SEC` | `60` | `state.sh` | 最近修改的会话不归档 |
| `SESSION_ARCHIVE_TOKEN` | 无（可选 secret） | agent | 下载归档的只读 token；回退 `STATE_REPO_TOKEN` |
| `DSH_DEBUG_LOG_TAIL` | `false` | `run.sh` | 启动失败时输出遮蔽 URL 的 dsh 日志尾部 |
| `DSH_PUBLIC_HOST` | 无（必填 variable） | `run.sh` | `dsh --public-url/--trusted-host` |
| `DSH_WEB_USER` | `dsh`（variable） | `run.sh` | Caddy basic auth 用户名 |
| `DSH_WEB_PASSWORD` | 无（必填 secret） | `run.sh` | Caddy basic auth 密码；只用于生成 bcrypt hash，不写状态 |
| `DSH_PORT` | `3081`（内部常量） | `run.sh` | dsh 只监听 loopback 3081 |
| `CADDY_PORT` | `3080`（内部常量） | `run.sh` | Caddy 监听 loopback 3080；cloudflared origin |
| `CADDY_VERSION` | 无（必填 variable） | workflow | Caddy 版本 |
| `CADDY_SHA512` | 无（必填 variable） | workflow | Caddy tar.gz SHA-512 |
| `DSH_VERSION` | 无（必填 variable） | workflow | 安装的 dsh 版本 |
| `CLOUDFLARED_VERSION` | 无（必填 variable） | workflow | cloudflared 版本 |
| `CLOUDFLARED_SHA256` | 无（必填 variable） | workflow | cloudflared 下载校验 |
| `GITLEAKS_VERSION` | 无（必填 variable） | workflow | gitleaks 版本 |
| `GITLEAKS_SHA256` | 无（必填 variable） | workflow | gitleaks 下载校验 |
| `DSH_MAX_RUNTIME_MIN` | `330`（dispatch 输入） | `run.sh` | deadline，workflow 限制 1–330 |
| `DSH_CHECKPOINT_MIN` | `10`（dispatch 输入） | `run.sh` | 基础 checkpoint 间隔，1–60 |
| `DSH_CHECKPOINT_LONG_MIN` | `20` | `run.sh` | 状态 >2GB 时的间隔 |
| `DSH_AUTO_RESTART` | `false`（dispatch 输入） | `run.sh` | 是否自动重启 |
| `DSH_RESTARTS_LEFT` | `0`（dispatch 输入） | `run.sh` | 剩余重启次数 |
| `DSH_MIN_FREE_MB` | `5120` | `run.sh` | 磁盘保护停止阈值 |
| `DSH_MIN_INODE_PCT` | `3` | `run.sh` | 磁盘保护 inode 阈值 |
| `DSH_TEMP_WARN_MB` | `8192` | `run.sh` | 临时目录清理阈值 |
| `DSH_TEMP_CRIT_FREE_MB` | `6144` | `run.sh` | 临时目录清理的剩余空间阈值 |
| `DSH_STOP_GRACE_SEC` | `120` | `run.sh` | dsh SIGTERM 等待 |
| `DSH_CFD_STOP_GRACE_SEC` | `30` | `run.sh` | cloudflared SIGTERM 等待 |
| `DSH_URL_TIMEOUT_SEC` | `300` | `run.sh` | 等待 dsh 输出 URL |
| `DSH_SUBPROCESS_MAX_AGE_MIN` | `60` | `run.sh` | subprocess 日志清理年龄 |
| `DSH_ALLOW_SMALL_SCRATCH` | `false` | workflow | 允许小于 20GB 的 scratch |
| `CF_TUNNEL_TOKEN` | 无（secret） | `run.sh` | 只通过环境传给 cloudflared |
| `DEEPSEEK_API_KEY` | 无（可选 secret） | `run.sh` | 传给 dsh；不落盘 |
| `DSH_NOTIFY_WEBHOOK` | 无（可选 secret） | workflow | 预留通知 webhook |
| `GITHUB_TOKEN` | Actions 注入 | `run.sh`、`dsh-stop` | 自动重启/兜底 cancel，需要 `actions: write` |

## 3. state.sh

### 3.1 子命令

```text
state.sh init                 # 克隆控制分支、检查 private/lock、恢复快照、写锁
state.sh publish-url [url]    # 默认读取 $RUN_DIR/url.txt（可选 url 仅手动调试）
state.sh save [--final]       # 打包/分卷/上传/更新指针/清理旧快照
state.sh should-stop          # DSH_STOP == run id 或 "all" 时 exit 0
state.sh release-lock         # 删除 runtime/lock.json，提交推送
state.sh status               # 输出紧凑 JSON（不含 URL/token）
```

退出码：

- `0`：成功；`should-stop` 表示应当停止。
- `2`：原始状态超过硬预算（`STATE_BUDGET_MB`），保存被拒绝。
- `3`：保存时锁冲突（另一个 run 持有锁）。
- `5`：保存前 gitleaks 扫描命中。
- 其他非零：clone/校验/上传/推送等失败；调用方必须记录并且不能假装保存成功。

`init` 由 workflow 在主程序之前调用；`run.sh` 不会再次 init，只调用 `publish-url`、`save`、`should-stop`、`release-lock`，并在每次 checkpoint 后调用 `status` 读取 `raw_mb` 以决定是否把间隔切到 20 分钟。

### 3.2 `state` 分支布局

单条滚动提交，只放小文件，控制在 10MB 以内：

```text
runtime/url.txt          固定公开 URL（不含 token；Caddy 负责认证）
runtime/meta.json        最近一次 save 的 raw_bytes/raw_mb/parts/scratch_free_mb/final
runtime/lock.json        run_id、host、started、heartbeat（ISO 8601）
runtime/state.json       当前快照：run_id、created、raw_bytes/raw_mb、home/work parts、archived
runtime/state.prev.json  上一份快照指针
runtime/sessions-index.json 冷会话索引副本（来自 $DSH_HOME/.session-archive/index.json）
.gitattributes           * -text；*.zst binary
README.md
```

`url.txt` 现在只是固定公开地址，不再含 token；真正保护入口的是 `DSH_WEB_PASSWORD` 和 Caddy basic auth。状态仓库仍需 private，因为 `.credentials.yaml`、会话、附件和冷归档在里面。

### 3.3 release 与快照命名

release tag：`dsh-state`（私有仓库）。

```text
home-<run_id>-<ts>.tar.zst.part-NN
work-<run_id>-<ts>.tar.zst.part-NN
session-<session_id>-<sha16>.tar.zst
```

- `home` 对应 `DSH_HOME`，`work` 对应 `DSH_WORKSPACE`；tar.zst 打包后按分卷切分，asset 名包含 `.tar.zst.part-NN`。
- 冷会话归档是完整的 `sessions/<project>/<id>` 目录；文件名带归档 SHA-256 前 16 位，索引保存完整 sha256 和原始日志字节数。
- 每卷最大 `STATE_ASSET_PART_MB=1900`（约 1.86GiB），低于 GitHub 单 asset 2GiB 上限；超过 1.9GB 的单个会话保留完整日志而不归档。
- `state.json` / `state.prev.json` 分别记录当前和上一份快照的所有分卷、字节数和 sha256；`archived` 记录冷归档数量和原始字节数。
- 清理逻辑默认保留 **当前 + 上一份** home/work 快照；`session-*` 归档不参与该清理，会持续保留。最坏约 10GB（2 × 5GB 原始状态，zstd 压缩通常更小）。
- 快照是 release asset，不是 git 对象；控制分支只保存指针和冷会话索引。

### 3.4 `init` 流程

1. 用 `GIT_ASKPASS` 克隆 `STATE_REPO` 的 `state` 分支到 `STATE_CLONE`（token 不进 URL/argv）。
2. 通过 GitHub API 检查仓库可见性；**公开则直接失败**。
3. 检查 `runtime/lock.json`：其他 run 的心跳在 45 分钟内时以 exit 3 拒绝启动；超过 45 分钟视为陈旧并记录告警后接管。
4. 读取 `runtime/state.json`，下载精确的 asset 名称/分卷到 staging，逐卷校验 sha256。
5. `cat parts | tar --zstd -xpf - -C <target>` 恢复到 `DSH_HOME` / `DSH_WORKSPACE`。
6. 恢复目录权限 0700，拒绝绝对/逃逸符号链接，并校验 `storages/workspace.json` 是合法 JSON（文件权限沿用归档内容）。
7. 如果 `DSH_PERSIST_CREDENTIALS=true`，把恢复出的 `.credentials.yaml` 设为 0600；否则删除它。`storages/session_projcache*` 和冷会话 stub/index 随 home 一起恢复。
8. 当前快照不可读时自动回退 `runtime/state.prev.json`。
9. 有快照但两份都不可读时**中止**；绝不以空状态覆盖已有快照。
10. 首次运行（没有 `state.json`）才允许空状态启动。
11. 写入 `runtime/lock.json`（run_id/host/started/heartbeat）并用 amend 提交推送。

### 3.5 `save` 流程

1. 检查 `DSH_SCRATCH` 剩余空间，低于 `STATE_MIN_FREE_MB` 直接失败。
2. 用共享 `sync-excludes.txt` 把 live `DSH_HOME`/`DSH_WORKSPACE` rsync 到 `RUN_DIR/state/{home,work}`；`DSH_PERSIST_CREDENTIALS=true` 时用 `--include=.credentials.yaml` 覆盖 home 的排除。
3. 对 staging 执行 `gitleaks` 扫描；命中则本次保存失败（**exit 5**），需先清理状态中的密钥。`.credentials.yaml` 由路径 allowlist 放行。
4. 统计冷会话：最近 `SESSION_HOT_MAX` 个或 `SESSION_HOT_DAYS` 天内为热；其余满足 `SESSION_ARCHIVE_MIN_AGE_SEC` 的会话：
   - 若 runtime 索引中已有同字节数的归档，直接复用，不重复上传；
   - 若 session 目录已是 stub，沿用索引条目；
   - 否则打包完整目录、上传 `session-*`、校验 asset 存在，然后把 staging 中的日志替换为 header-only stub。
   - 写入 `$STAGE_DIR/home/.session-archive/index.json`；失败时本次保存以 **exit 4** 中止，不产生不可恢复的 staging。
5. 统计原始大小：达到 `STATE_WARN_MB` 记录告警；超过 `STATE_BUDGET_MB` 以 **exit 2** 退出，不上传。
6. 确保 `dsh-state` release 存在；`tar -C <dir> --zstd -cpf ... .` 打包，按 1.9GB 分卷，计算每卷 sha256，并上传**所有**分卷。
7. 成功后更新指针：仅当旧 `state.json` 通过 `pointer_valid` 校验时才复制到 `state.prev.json`；损坏的当前指针不会被提升。写入 `meta.json`（含 `archived`）并刷新锁心跳。
8. 把 staging 的冷会话索引复制到 `runtime/sessions-index.json`。
9. 用 `git commit --amend` + `--force-with-lease` 推送 `state` 分支；失败时重新 fetch 并基于新 head 重建提交、刷新 lease；assets 可能成为孤儿，但不会指向缺失文件。
10. 清理不在当前/上一份指针中的 home/work assets；`session-*` 保留。`--final` 使用同一流程；它总是执行，失败视为一次不完整关闭。

设计顺序是“先传 assets，再改指针”，因此任何中断都只会留下未引用资源，不会产生指向不存在 asset 的指针。

### 3.6 `publish-url`

- 默认**不带参数**：从 `$RUN_DIR/url.txt` 读取固定公开 URL（`run.sh` 已先以 0600 写入），再写入控制分支的 `runtime/url.txt`（0600）。
- `run.sh` 发布的是 `https://$DSH_PUBLIC_HOST/`，不含 dsh token；token 只存在于 runner 的 `Caddyfile`（0600）。
- `meta.json` 由 `init` / `save` 更新；`publish-url` 不改写它。
- 可选 `<url>` 参数只用于手动/调试；自动流程不要使用。
- 提交并推送 `state` 分支。
- 不在 stdout、job summary 或公开日志中打印 URL；dsh 自身仍会在 `$DSH_LOG` 打印带 token 的 URL，该文件只在 runner 本地 scratch（0600），不上传。

### 3.7 `should-stop`

读取私有状态仓库的 `DSH_STOP` 变量（由 `dsh-stop.yml` 设置）：

- 值等于当前 `GITHUB_RUN_ID`，或值为 `all`：exit 0，表示停止。
- 变量不存在、为空或其他 run id：非 0。
- `run.sh` 每 10 秒调用一次。

### 3.8 `release-lock`

删除 `runtime/lock.json`，提交推送。锁不存在时视为成功；锁属于其他 run 时返回 **exit 3**。正常停止路径一定在 final save 之后调用。

### 3.9 `status`

输出紧凑 JSON：`{"run_id":"...","raw_mb":N}`。`run.sh` 在每次 checkpoint 后调用它读取 `raw_mb`，决定是否切换到 20 分钟间隔；**不包含** URL 或任何 token。

### 3.10 手动检查

以下命令只读，替换 `$STATE` 后执行。需要能读私有仓库的凭据。

```bash
STATE=2061969365/dsh-web-state

# 当前快照指针
gh api "repos/$STATE/contents/runtime/state.json?ref=state" --jq .content | base64 -d

# 上一份指针
gh api "repos/$STATE/contents/runtime/state.prev.json?ref=state" --jq .content | base64 -d

# release assets
gh release view dsh-state --repo "$STATE" --json assets --jq '.assets[].name'

# 锁
gh api "repos/$STATE/contents/runtime/lock.json?ref=state" --jq .content | base64 -d

# STOP 变量（需要 Variables 读权限）
GH_TOKEN="$STATE_REPO_TOKEN" gh api "repos/$STATE/actions/variables/DSH_STOP" --jq .value
```

不要用 `cat`/日志打印 `Caddyfile`；它含 dsh token 和密码 hash。访问入口是固定公开 URL + `DSH_WEB_PASSWORD`，不需要读 `runtime/url.txt`。

### 3.11 恢复与清理场景

- **当前指针损坏，上一份正常**：`init` 自动回退，无需操作；检查日志确认已回退。
- **两份都损坏**：`init` 会失败而不是空启动。先确认没有运行中的 job，再检查 assets 是否存在、sha256 是否匹配；修复或按明确决定清理指针后重跑。
- **孤儿 assets（上传成功但指针未更新）**：对照 `state.json` / `state.prev.json`，删除未被引用的 asset；不要让无用分卷长期占用空间。
- **预算超限（exit 2）**：supervisor 会停止本次运行，不会等到下一次 checkpoint。先删工作区大文件/会话/附件再重新启动；不要把预算无限调高，release 分卷和 2 份保留会成倍放大占用。
- **锁冲突（exit 3）**：说明另一个 run 持有状态锁；确认是否有并行 job，不要强行删除锁继续跑。
- **gitleaks 命中（exit 5）**：从状态中移除密钥后重新启动；不要把命中当成可忽略告警。
- **陈旧锁**：`init` 在心跳超过 45 分钟时会记录告警并自动接管，不需要手动删除；心跳仍新鲜时以 exit 3 拒绝启动。不要在运行中手动改状态分支，避免与 supervisor 的提交竞争。
- **仓库被误设为 public**：立即停止所有运行、改回 private、轮换 PAT 和 tunnel token；把已暴露的 URL 当作已泄露。

### 3.12 冷会话归档与自动恢复

- 热/冷判定按日志 mtime 降序：前 `SESSION_HOT_MAX` 个，或 mtime 在 `SESSION_HOT_DAYS` 天内，保持完整；其余归档。刚修改不到 `SESSION_ARCHIVE_MIN_AGE_SEC` 的会话跳过。
- 索引 `$DSH_HOME/.session-archive/index.json` 只记录成功上传的归档；条目包含 `path`、`release`、`asset`、`sha256`、`full_bytes`、`updated_at`、`archived_at`。`state.sh` 同时把它复制到 `runtime/sessions-index.json`。
- `$RUNTIME_DIR/sessions-index.json`（上一次保存的控制分支副本）用于识别“完整日志已归档且字节数未变”的会话，避免每个 checkpoint 重复上传；stub 小于 `full_bytes` 时直接沿用条目。
- `session-archive-agent.mjs` 监听 `$RUN_DIR/session-archive.sock`。请求 `{"id":"<session-id>"}`，响应 `{"ok":true,"status":"present|restored"}` 或 `{"ok":false,"error":"..."}`。
- agent 用 `gh release download` 下载 asset，流式计算 sha256，`tar --zstd` 解压到临时目录，校验恢复日志不小于 `full_bytes`，然后原子替换目标目录并 touch 日志。并发同 id 请求会串行化。
- host 插件 `@dsh-web/session-archive` 读取同一索引；只在命中索引时调用 agent，然后委托原生 `sessionPersistence.open`。索引外会话不受影响。
- `run.sh` 只有在 profile 依赖安装成功、host 插件存在、overlay 复制成功后，才用 `dsh --patch <profile>/session-archive.overlay.yml --profile web` 启动，并把 `ARCHIVE_READY` 视为 true；否则强制 `SESSION_ARCHIVE_ENABLED=false`，避免生成无法恢复的 stub。
- 单个归档超过 1.9GB、上传失败、sha 校验失败或磁盘不足时保留完整日志并告警；不会删除唯一副本。
- 冷会话恢复前不能被全文搜索，也不会因置顶而保留；列表仍只依赖 header 和投影缓存。

## 4. run.sh

### 4.1 启动顺序

1. 校验 `DSH_HOME`/`DSH_WORKSPACE`/`RUN_DIR`/`STATE_*`/`DSH_WEB_PASSWORD`，设置 `umask 077`，确认 `state.sh init` 已成功。
2. 准备冷归档：
   - 如果 profile 还没有 `@dsh-web/session-archive` 依赖，执行 `dsh plugin --profile web add file:<checkout>/dsh-session-archive`；
   - `restore_profile_plugins` 执行 `dsh plugin --profile web install`，重建 `node_modules`；
   - 安装成功后把 `dsh-session-archive.overlay.yml` 复制到 `$DSH_HOME/profiles/web/`；
   - 启动 `session-archive-agent.mjs` 并等待 `$RUN_DIR/session-archive.sock`；
   - 任何一步失败都把本次运行的 `SESSION_ARCHIVE_ENABLED` 设为 `false`，并跳过 overlay。
3. 启动 cloudflared（日志 0600）：

   ```bash
   env -u STATE_REPO_TOKEN -u CF_TUNNEL_TOKEN -u DEEPSEEK_API_KEY -u DSH_NOTIFY_WEBHOOK \
     -u GH_TOKEN -u GITHUB_TOKEN TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" cloudflared tunnel \
     --no-autoupdate --protocol http2 --grace-period 5s run
   ```

   flag 必须在 `run` 之前；token 只通过环境变量传递，不写 `config.yml`。cloudflared 只拿到 `TUNNEL_TOKEN`，其余密钥全部剥离。

4. 在 `$DSH_WORKSPACE` 启动 dsh（日志 0600），显式剥离令牌：

   ```bash
   env -u STATE_REPO_TOKEN -u SESSION_ARCHIVE_TOKEN -u CF_TUNNEL_TOKEN \
     -u GH_TOKEN -u GITHUB_TOKEN -u DSH_NOTIFY_WEBHOOK -u DSH_WEB_PASSWORD \
     DSH_SESSION_ARCHIVE_SOCKET="$RUN_DIR/session-archive.sock" \
     dsh --patch "$DSH_HOME/profiles/web/session-archive.overlay.yml" \
     --profile web --host 127.0.0.1 --port 3081 --no-open \
     --public-url "https://$DSH_PUBLIC_HOST/" --trusted-host "$DSH_PUBLIC_HOST"
   ```

   `--patch` 必须放在 `--profile` 前；overlay 放在 profile 目录旁，插件按 profile 的 `node_modules` 解析。`DEEPSEEK_API_KEY` / `DEEP_API_KEY` 保留给模型 provider；workflow 会把 `DEEPSEEK_API_KEY` secret 同时映射到这两个变量。其余仓库/隧道/归档/网页密码全部剥离。

5. 从 dsh 输出解析 `dsh web:` 行，提取本次 process token；用 `caddy hash-password` 生成密码 hash，写入 0600 的 `Caddyfile`，启动 Caddy（127.0.0.1:3080，basic auth，反代 127.0.0.1:3081）。Caddy 只在请求没有 `dsh-auth-*` cookie 时用 `uri query token <token>` 注入 token；dsh 验证后会设置 cookie 并 303 到干净 `/`，后续请求靠 cookie，避免 token 每次注入导致的 303 循环。Caddy 就绪后把固定 `https://$DSH_PUBLIC_HOST/` 写入 `RUN_DIR/url.txt`，再调用**不带参数**的 `state.sh publish-url`。
6. 进入监控循环；token 只存在于 runner 的 `Caddyfile` 和 dsh 自身 0600 日志中，公开状态只保存固定 URL。

### 4.2 监控循环

| 周期 | 动作 |
| --- | --- |
| 10 秒 | `state.sh should-stop`；检查 dsh / cloudflared / Caddy 存活 |
| 30 秒 | `df` 采样 `/` 和 `$DSH_SCRATCH` 的可用 MB 与 inode |
| checkpoint（10/20 分钟） | `state.sh save`；统计 `$TMPDIR`；必要时清理旧 subprocess 日志 |
| 330 分钟 | 正常 deadline，进入停止流程 |

- 磁盘阈值：可用空间 < `DSH_MIN_FREE_MB`（默认 5120MB）或 inode < `DSH_MIN_INODE_PCT`（默认 3%）时停止，先保存再退出。
- checkpoint 时若 `$TMPDIR` > `DSH_TEMP_WARN_MB`（默认 8192MB）或剩余空间 < `DSH_TEMP_CRIT_FREE_MB`（默认 6144MB），清理超过 `DSH_SUBPROCESS_MAX_AGE_MIN`（默认 60 分钟）的 `$TMPDIR/dsh-subprocess-*`。
- `state.sh save` 返回 **exit 2**（硬预算）、**3**（锁冲突）或 **5**（gitleaks）时立即停止；其他保存失败连续 3 次也停止。
- 保存成功后 `run.sh` 调用 `state.sh status` 读取 `raw_mb`；>2GB 时 checkpoint 间隔改用 `DSH_CHECKPOINT_LONG_MIN`（默认 20 分钟），减少打包/上传开销。
- URL 等待超过 `DSH_URL_TIMEOUT_SEC`（默认 300 秒）视为启动失败。
- 不清理活跃的 `$TMPDIR/dsh-workspace-changes-*`；只在启动/结束和磁盘压力下处理陈旧目录。

### 4.3 停止顺序

收到 STOP、磁盘保护或 deadline 后：

1. 向 dsh 发送 SIGTERM，最多等待 `DSH_STOP_GRACE_SEC`（默认 120 秒），仍未退出则 SIGKILL。
2. 停止 cloudflared，最多等待 `DSH_CFD_STOP_GRACE_SEC`（默认 30 秒）。
3. 停止 Caddy，最多等待 `DSH_CFD_STOP_GRACE_SEC`。
4. 清理 `$TMPDIR` 下的 DSH 临时目录；**不清理** `$DSH_HOME/spill`。
5. `state.sh save --final`。
6. `state.sh release-lock`。
7. 停止 session archive agent 并删除 socket。
8. 输出公开 summary（不打印密码、token 或 `Caddyfile`；公开 URL 固定，不含 token）。

正常停止通常 1–3 分钟。不要在 job 还在 final save 时手动 `cancel`。

### 4.4 自动重启

仅在以下条件全部满足时触发：

- 退出原因是正常 deadline（不是 STOP、磁盘不足、崩溃或外部 cancel）；
- `DSH_AUTO_RESTART=true`；
- `DSH_RESTARTS_LEFT > 0`；
- final save 和 `release-lock` 都成功；
- `GITHUB_REPOSITORY`、`GITHUB_REF_NAME`、`GITHUB_TOKEN` 都存在，且 runner 上有 `gh`；
- `GITHUB_TOKEN` 具备 `actions: write`。

触发方式是用 `gh workflow run dsh-web.yml` 重新 dispatch（带 `--ref`），并传入 `restarts_left - 1`。`concurrency: dsh-web` + `cancel-in-progress: false` 保证新 run 排队而不是与旧 run 并行。新 run 会生成新的 dsh token，但 Caddy 会重新注入；**公开 URL 和密码不变**，不需要重新复制。dispatch 失败只记录在 `auto-restart.log`，不会让当前运行失败。

### 4.5 日志与掩码

- `$RUN_DIR/dsh-web.log`、`$RUN_DIR/cloudflared.log`、`$RUN_DIR/caddy.log`、`$RUN_DIR/Caddyfile`、`$RUN_DIR/state.log`、`$RUN_DIR/auto-restart.log`、`$RUN_DIR/session-archive.log`、`$RUN_DIR/url.txt` 都是 0600；`session-archive.sock` 是 0600。
- `Caddyfile` 含 dsh token 和密码 bcrypt hash，只在 runner 本地；`url.txt` 不含 token。
- 不使用 `set -x`；错误处理里也不 `echo` 环境变量。
- 启动失败时，可选 `DSH_DEBUG_LOG_TAIL=true` 打印 dsh 日志尾部；URL 会被正则遮蔽，默认关闭，避免把 session 内容带进公开 job log。
- 工作流不上传 artifacts，避免日志/状态泄露。

## 5. Workflow 接口

### 5.1 `dsh-web.yml`

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `auto_restart` | `false` | 是否在正常 deadline 后自动重启 |
| `restarts_left` | `1` | 剩余重启次数；每次重启减一 |
| `max_runtime_minutes` | `330` | 本次运行上限，范围 1–330 |
| `checkpoint_minutes` | `10` | checkpoint 间隔，范围 1–60；状态 >2GB 时内部改用 20 |

- `runs-on: ubuntu-24.04`；`timeout-minutes: 355`。
- `permissions: contents: read, actions: write`。
- `concurrency: {group: dsh-web, cancel-in-progress: false}`。
- Preflight 要求以下仓库变量非空：`STATE_REPO`、`DSH_PUBLIC_HOST`、`DSH_VERSION`、`CLOUDFLARED_VERSION`、`CLOUDFLARED_SHA256`、`GITLEAKS_VERSION`、`GITLEAKS_SHA256`、`CADDY_VERSION`、`CADDY_SHA512`；并要求 `STATE_REPO_TOKEN`、`CF_TUNNEL_TOKEN`、`DSH_WEB_PASSWORD` 三个 secret。`SESSION_ARCHIVE_TOKEN` 可选，存在时会掩码。
- Node 24 + npm cache；安装 dsh、pnpm，下载 cloudflared/gitleaks/Caddy；cloudflared/gitleaks 校验 SHA-256，Caddy 校验 SHA-512。
- 选择 scratch（≥20GB、inode ≥5%；`/mnt` → `/mnt/dsh-scratch` → `/home/runner`）并导出 `DSH_SCRATCH`/`DSH_HOME`/`DSH_WORKSPACE`/`TMPDIR`/`STATE_CLONE`/`RUN_DIR`；`DSH_ALLOW_SMALL_SCRATCH=true` 可覆盖 20GB 要求。
- `state.sh init` 超时 10 分钟；`run.sh` 用 `timeout --signal=TERM --kill-after=180s 20700` 包裹（345 分钟）；最后生成不含密码/token 的公开 summary。
- `run.sh` 会安装本地 host 插件和 overlay、启动 archive agent，并以 `dsh --patch ... --profile web` 启动；插件不可用时自动关闭本次归档。dsh 监听 3081，Caddy basic auth 监听 3080。

### 5.2 `dsh-stop.yml`

- `permissions: actions: write, contents: read`。
- 优先找到 status 为 in-progress 的 dsh-web run，否则找 queued；没有则直接成功退出。
- 用 `STATE_REPO_TOKEN` 把私有状态仓库的 `DSH_STOP` 变量设为该 run id。
- 每 10 秒轮询 run 状态，最多等待 540 秒让 supervisor 完成 dsh 退出、final save 和锁释放。
- 超时后兜底 `gh run cancel`（使用 `GITHUB_TOKEN`）。
- 最后删除 `DSH_STOP` 变量（404 视为已清理）。

### 5.3 Secret / Variable 消费关系

| 名称 | 类型 | 位置 | 消费方 |
| --- | --- | --- | --- |
| `STATE_REPO_TOKEN` | secret | 公共仓库 | `state.sh`、`dsh-stop` |
| `CF_TUNNEL_TOKEN` | secret | 公共仓库 | `run.sh` → cloudflared |
| `DSH_WEB_PASSWORD` | secret（必填） | 公共仓库 | `run.sh` → Caddy basic auth |
| `DEEPSEEK_API_KEY` | secret（可选） | 公共仓库 | `run.sh` → dsh |
| `SESSION_ARCHIVE_TOKEN` | secret（可选） | 公共仓库 | session archive agent |
| `DSH_NOTIFY_WEBHOOK` | secret（可选） | 公共仓库 | 预留通知 |
| `STATE_REPO` | variable（必填） | 公共仓库 | `state.sh`、`dsh-stop` |
| `DSH_PUBLIC_HOST` | variable（必填） | 公共仓库 | `run.sh` |
| `DSH_VERSION` | variable（必填） | 公共仓库 | 安装步骤 |
| `CLOUDFLARED_VERSION` / `CLOUDFLARED_SHA256` | variable（必填） | 公共仓库 | 安装/校验 |
| `GITLEAKS_VERSION` / `GITLEAKS_SHA256` | variable（必填） | 公共仓库 | 安装/校验 |
| `CADDY_VERSION` / `CADDY_SHA512` | variable（必填） | 公共仓库 | Caddy 安装/校验 |
| `DSH_WEB_USER` | variable | 公共仓库 | Caddy 用户名（默认 `dsh`） |
| `STATE_*` | variable | 公共仓库 | `state.sh` |
| `DSH_PERSIST_CREDENTIALS` | variable | 公共仓库 | `state.sh` |
| `SESSION_ARCHIVE_ENABLED` / `SESSION_HOT_MAX` / `SESSION_HOT_DAYS` / `SESSION_ARCHIVE_MIN_AGE_SEC` | variable | 公共仓库 | `state.sh`、`run.sh` |
| `DSH_MIN_FREE_MB` / `DSH_TEMP_WARN_MB` | variable | 公共仓库 | `run.sh` |
| `DSH_DEBUG_LOG_TAIL` | variable | 公共仓库 | `run.sh` 启动失败诊断 |
| `DSH_ALLOW_SMALL_SCRATCH` | variable | 公共仓库 | workflow scratch 选择 |
| `max_runtime_minutes` / `checkpoint_minutes` | dispatch input | workflow | `DSH_MAX_RUNTIME_MIN` / `DSH_CHECKPOINT_MIN` |
| `DSH_STOP` | variable | **私有状态仓库** | `state.sh should-stop` |

## 6. 安全不变量

合并前逐项确认：

- 脚本 `set -euo pipefail`，**没有** `set -x`。
- `umask 077`；敏感文件 0600。
- token/密码只通过环境变量/stdin/`GIT_ASKPASS` 传递，不进入 git remote URL、argv、stdout、日志、summary 或 artifacts。`caddy hash-password` 从 stdin 读取密码。
- 访问 URL 由 `run.sh` 写入 `$RUN_DIR/url.txt`（0600），`state.sh publish-url` **无参数**从文件读取；现在写的是固定公开 URL，不含 dsh token。
- `Caddyfile` 含 dsh token 和 bcrypt hash，写入 `$RUN_DIR` 并 chmod 0600；不进状态快照。
- `gh` 命令使用 `--repo "$STATE_REPO"` + `GH_TOKEN`，不把 token 拼进 remote URL。
- `state.sh init` 强制检查状态仓库为 private。
- 上传前 gitleaks 扫描；命中阻止保存并使本次运行以 exit 5 停止。唯一放行的是 `DSH_PERSIST_CREDENTIALS=true` 时的 `$DSH_HOME/.credentials.yaml`；冷会话日志在归档前仍会被扫描。
- dsh 进程用 `env -u` 剥离 `STATE_REPO_TOKEN`、`SESSION_ARCHIVE_TOKEN`、`CF_TUNNEL_TOKEN`、`DSH_WEB_PASSWORD`、`GH_TOKEN`、`GITHUB_TOKEN`；cloudflared 启动后立即 unset `CF_TUNNEL_TOKEN`。归档 token 只存在于 agent 进程。
- `.credentials.yaml` 在私有状态仓库中是明文；能读仓库或 token 的人就能读模型 key。该文件恢复后 chmod 0600。
- 冷会话归档 asset 也在私有状态仓库；读权限等同于读完整会话历史。
- 公共 summary 只说明固定公开地址和密码保护，不打印密码、token 或 `Caddyfile`。
- 工作流不上传 artifacts；日志、`Caddyfile` 和 `url.txt` 都是 0600。`DSH_DEBUG_LOG_TAIL` 默认关闭，开启时遮蔽 URL。

## 7. 验收与自检

```bash
# 语法
bash -n dsh-actions/state.sh
bash -n dsh-actions/run.sh

# 冷归档：热/冷、stub、索引、复用（需要 jq/zstd）
bash dsh-actions/tests/session-archive-test.sh

# agent：fake gh + 下载/校验/解压/替换
node dsh-actions/tests/session-archive-agent-test.mjs

# 如果本机有 shellcheck / actionlint
shellcheck -x dsh-actions/state.sh dsh-actions/run.sh
actionlint

# 禁止 set -x 和明显的 token 输出
grep -n 'set -x' dsh-actions/*.sh
grep -nE 'echo .*STATE_REPO_TOKEN|echo .*CF_TUNNEL_TOKEN|echo .*url' dsh-actions/*.sh

# publish-url 不应在自动流程中接收 URL 参数
grep -n 'publish-url' dsh-actions/run.sh dsh-actions/state.sh
```

功能验收（在临时仓库/测试 token 上做）：

- 首次无快照启动；save → 清空 → init 恢复的 round-trip。
- 当前快照 sha 损坏时回退 `state.prev.json`；两份都坏时拒绝空启动。
- 状态超过 5GB 时 `save` 返回 2；锁冲突返回 3；gitleaks 命中返回 5；1.9GB 分卷正确。
- 资产名符合 `home-<run_id>-<ts>.tar.zst.part-NN` / `work-<run_id>-<ts>.tar.zst.part-NN`。
- 连续 3 次 save 后只保留 2 份快照。
- 冷会话：热/冷阈值、header-only stub、`session-*` asset、`sessions-index.json`、同一字节数不重复上传、stub 沿用条目。
- 打开冷会话时 agent 下载并校验 sha256，替换 stub 后原生 `sessionPersistence.open` 读到完整日志；失败时保留 stub 且返回明确错误。
- 插件未就绪时 `run.sh` 强制关闭归档，不产生新 stub。
- `status` 返回含 `raw_mb` 的 JSON，`run.sh` 能据此切换 20 分钟 checkpoint。
- `DSH_STOP` 等于 run id / `all` 时 `should-stop` 返回 0。
- `publish-url` 无参数时从 `$RUN_DIR/url.txt` 读取固定公开 URL；密码/token 不出现在 argv、公开日志或 summary 中。
- `run.sh` 能启动/停止 dsh、cloudflared、Caddy 三个进程；Caddy 用 basic auth 保护 3080，把 token 注入 3081；无密码返回 401，密码正确返回 200。
- Caddyfile 校验通过；密码 hash 是 bcrypt；`DSH_WEB_PASSWORD` 变化后重启能生效。
- `run.sh` 执行 checkpoint、响应磁盘阈值、SIGTERM 后 final save、释放锁。
- 自动重启只在正常 deadline 且 final save/lock 成功时发生；STOP/磁盘/崩溃不重启；重启后公开 URL 和密码不变。
- 两个 workflow 使用的 secret/variable 名称与本文件、`../README.md` 一致；preflight 要求的版本/SHA 变量齐全。

## 8. 文档与脚本的一致性

`../README.md` 面向使用者，本文面向维护者；两者都以 `PLAN.md` 的接口为准。脚本落地后重点核对：

- `state.sh` 子命令名和参数（`publish-url [url]` 默认从 `$RUN_DIR/url.txt` 读取、`save [--final]` 等）。
- 环境变量默认值（`STATE_*`、`DSH_*`）与 workflow 的 `env:` 是否一一对应。
- `run.sh` 实际调用的子命令集合（不重复 init；`publish-url` 不传 URL）。
- `dsh-stop.yml` 写入的变量位置（私有状态仓库）和清除逻辑。
- 退出码（2/3/5）与 `run.sh` 的 checkpoint 停止条件一致。
- 资产命名、锁字段（`started`/`heartbeat`）与 `state.json` 字段名和恢复代码一致。

发现差异时改文档或改脚本均可，但必须让**脚本、workflow、两份 README** 在合并前保持一致。
