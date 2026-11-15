# dsh-web

在 GitHub Actions 上运行 DeepSeek Harness 的 `dsh web`，通过 Cloudflare Named Tunnel 暴露一个**私有 HTTPS 地址**。

公共仓库（本仓库）只放代码和工作流；会话、附件、工作区等运行状态放在**私有状态仓库** `dsh-web-state` 的 release 资源和一条很小的 `state` 控制分支里。这样公开仓库里不会出现任何状态、URL 或令牌。

> 适合个人临时使用，不是多租户服务。不要在其中保存生产密钥或不可替代的数据。

## 目录

- [1. 架构](#1-架构)
- [2. 关键限制](#2-关键限制)
- [3. 一次性配置](#3-一次性配置)
- [4. 首次启动](#4-首次启动)
- [5. 日常使用](#5-日常使用)
- [6. 持久化边界](#6-持久化边界)
- [7. 临时文件与磁盘](#7-临时文件与磁盘)
- [8. 安全](#8-安全)
- [9. 故障排查](#9-故障排查)
- [10. 可选：本机临时目录清理](#10-可选本机临时目录清理)
- [11. 文件结构](#11-文件结构)

## 1. 架构

```text
GitHub Actions (ubuntu-24.04)
├─ 检出本仓库（公开，仅代码）
├─ state.sh init
│    ├─ 克隆私有仓库的 state 分支（控制文件，很小）
│    ├─ 从私有 release dsh-state 下载快照（home/work 分卷）
│    └─ 校验 sha256 后恢复到 /mnt 上的 DSH_HOME / DSH_WORKSPACE
├─ cloudflared（出站连接，使用 Named Tunnel Token）
│    └─ Cloudflare 边缘 ──> https://<DSH_PUBLIC_HOST>
└─ dsh web 监听 127.0.0.1:3080
     ├─ 每 10/20 分钟 checkpoint：打包、上传、更新 state 分支
     └─ 结束前 final save，然后释放锁
```

- **公共仓库**：`2061969365/dsh-web`，只保存 `README.md`、工作流和 `dsh-actions/*.sh`。
- **私有状态仓库**：`2061969365/dsh-web-state`，必须保持 private。
- **`state` 分支**：单条滚动提交，保存 `runtime/url.txt`、`runtime/meta.json`、`runtime/state.json`、`runtime/state.prev.json`、`runtime/lock.json` 等小文件。
- **`dsh-state` release**：保存 `home-<run_id>-<ts>.tar.zst.part-NN` 和 `work-<run_id>-<ts>.tar.zst.part-NN` 快照分卷，默认只保留最近 **2** 份（`STATE_KEEP_SNAPSHOTS` 可增大）。
- **Named Tunnel**：Cloudflare 控制台里把 Public Hostname 指向 `http://127.0.0.1:3080`；runner 不需要开放入站端口。
- **Runner**：`ubuntu-24.04`，工作流 job 超时 355 分钟，其中初始化 10 分钟、主程序最多 345 分钟。

## 2. 关键限制

| 项目 | 值 | 说明 |
| --- | --- | --- |
| 状态硬预算 | **5GB**（`STATE_BUDGET_MB=5120`） | 原始状态超过后保存失败（exit 2）并停止本次运行，必须清理 |
| 状态软告警 | 3GB（`STATE_WARN_MB=3072`） | 达到后日志告警，仍可继续 |
| 快照保留 | **2 份**（当前 + 上一份） | 最坏约 10GB release 占用 |
| 单资源分卷 | **1.9GB**（`STATE_ASSET_PART_MB=1900`） | GitHub 单个 release asset 上限 2GiB |
| checkpoint | **10 分钟**；原始状态 >2GB 时 **20 分钟** | 结束前一定执行 final save |
| 运行时长 | 默认 **330 分钟**，job 上限 355 分钟 | 约 5.5 小时；自动重启可续上，但有短暂中断 |
| Runner | `ubuntu-24.04` | 公共仓库的标准 runner 分钟数免费，仍受合理使用约束 |

## 3. 一次性配置

### 3.1 前置条件

- 一个 GitHub 账号（下面的示例 owner 为 `2061969365`）。
- 本机安装并登录 `gh` CLI：`gh auth login`。
- 一个 Cloudflare 账号，以及一个已托管在 Cloudflare 的域名（Named Tunnel 必需）。
- 本仓库已推送到 GitHub。

### 3.2 创建私有状态仓库和 `state` 孤儿分支

```bash
OWNER=2061969365
REPO=$OWNER/dsh-web
STATE=$OWNER/dsh-web-state

# 1) 创建私有状态仓库
gh repo create "$STATE" --private --description "dsh-web private state (do not make public)"

# 2) 初始化 state 孤儿分支
git clone "https://github.com/$STATE.git"
cd dsh-web-state
git checkout --orphan state
git rm -rf . 2>/dev/null || true
mkdir -p runtime
printf '# dsh-web-state\n\nPrivate control branch. Never make this repository public.\n' > README.md
printf '* -text\n*.zst binary\n' > .gitattributes
git add README.md .gitattributes
git commit -m "init state branch"
git push -u origin state
```

`state` 分支初始化后只有 `README.md`；`runtime/` 下的文件由工作流在运行时创建。

### 3.3 创建 `dsh-state` release

快照通过 `dsh-state` release 上传。先创建空 release（后续由 `state.sh` 管理 assets）：

```bash
gh release create dsh-state --repo "$STATE" \
  --target state \
  --title "dsh-state" \
  --notes "Private state snapshots managed by dsh-web. Do not delete."
```

### 3.4 创建 fine-grained PAT

GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token：

| 项目 | 值 |
| --- | --- |
| Resource owner | 你的账号（如 `2061969365`） |
| Repository access | **Only select repositories** → `dsh-web-state` |
| Permissions | **Contents: Read and write**；**Variables: Read and write** |
| Expiration | **90 days**（到期前轮换） |

Metadata 权限会自动包含。不要给这个 PAT 访问公共仓库或其他仓库的权限。

> `DSH_STOP` 变量位于私有状态仓库，由停止工作流通过这个 PAT 设置；`Contents` 用于快照资源和控制分支，`Variables` 用于 STOP 信号。

### 3.5 配置 Secrets

在**公共仓库** `2061969365/dsh-web` 的 Settings → Secrets and variables → Actions 中创建：

```bash
gh secret set STATE_REPO_TOKEN --repo "$REPO"   # 3.4 创建的 PAT
gh secret set CF_TUNNEL_TOKEN --repo "$REPO"    # 3.7 的 Named Tunnel Token
gh secret set DEEPSEEK_API_KEY --repo "$REPO"   # 可选，建议设置
gh secret set DSH_NOTIFY_WEBHOOK --repo "$REPO" # 可选，预留通知 webhook
```

| Secret | 必需 | 用途 |
| --- | --- | --- |
| `STATE_REPO_TOKEN` | 是 | 读写私有状态仓库（控制分支 + release assets） |
| `CF_TUNNEL_TOKEN` | 是 | cloudflared 连接 Named Tunnel |
| `DEEPSEEK_API_KEY` | 否 | 注入 dsh 进程的模型 key；不写盘、不打印 |
| `DSH_NOTIFY_WEBHOOK` | 否 | 预留通知 webhook（当前 workflow 只做掩码，未实际发送） |

`gh secret set` 会交互式读取值，不要把 token 直接写在命令行参数里。

### 3.6 配置 Variables

在同一页面的 Variables 中设置（沿用 3.2 的 `$REPO` / `$STATE`，并把 `dsh.example.com` 换成你的域名）：

```bash
gh variable set STATE_REPO --repo "$REPO" --body "$STATE"
gh variable set DSH_PUBLIC_HOST --repo "$REPO" --body "dsh.example.com"
gh variable set DSH_VERSION --repo "$REPO" --body "0.2.2-rc.1"

# 必填：固定版本 + 64 位 SHA-256（替换为实际值）
gh variable set CLOUDFLARED_VERSION --repo "$REPO" --body "<cloudflared-version>"
gh variable set CLOUDFLARED_SHA256 --repo "$REPO" --body "<cloudflared-sha256>"
gh variable set GITLEAKS_VERSION --repo "$REPO" --body "<gitleaks-version>"
gh variable set GITLEAKS_SHA256 --repo "$REPO" --body "<gitleaks-sha256>"

gh variable set STATE_BUDGET_MB --repo "$REPO" --body "5120"
gh variable set STATE_WARN_MB --repo "$REPO" --body "3072"
gh variable set STATE_ASSET_PART_MB --repo "$REPO" --body "1900"
gh variable set STATE_KEEP_SNAPSHOTS --repo "$REPO" --body "2"
gh variable set DSH_MIN_FREE_MB --repo "$REPO" --body "5120"
gh variable set DSH_TEMP_WARN_MB --repo "$REPO" --body "8192"

# 可选：允许 <20GB 的 scratch（不推荐，5GB 状态容易写满根盘）
# gh variable set DSH_ALLOW_SMALL_SCRATCH --repo "$REPO" --body "true"
```

`CLOUDFLARED_*` 和 `GITLEAKS_*` 是**必填**的固定版本与校验值，从对应 release 的校验文件或下载后 `sha256sum` 获取；preflight 会检查格式，安装时校验 SHA-256。例如：

```bash
curl -fsSLO "https://github.com/cloudflare/cloudflared/releases/download/<cloudflared-version>/cloudflared-linux-amd64"
sha256sum cloudflared-linux-amd64
```

| Variable | 默认 | 说明 |
| --- | --- | --- |
| `STATE_REPO` | 无（必填） | 私有状态仓库 `owner/name` |
| `DSH_PUBLIC_HOST` | 无（必填） | 只写主机名，如 `dsh.example.com`，**不要带 `https://`、路径或结尾斜杠** |
| `DSH_VERSION` | 无（必填，常用 `0.2.2-rc.1`） | 安装的 dsh 版本 |
| `CLOUDFLARED_VERSION` | 无（必填） | cloudflared 版本 |
| `CLOUDFLARED_SHA256` | 无（必填） | cloudflared 二进制 SHA-256 |
| `GITLEAKS_VERSION` | 无（必填） | 状态扫描工具版本 |
| `GITLEAKS_SHA256` | 无（必填） | gitleaks 压缩包 SHA-256 |
| `STATE_BUDGET_MB` | `5120` | 原始状态硬上限 |
| `STATE_WARN_MB` | `3072` | 软告警阈值 |
| `STATE_ASSET_PART_MB` | `1900` | 分卷大小 |
| `STATE_KEEP_SNAPSHOTS` | `2` | 保留快照数；大于 2 时额外保留更早的快照 |
| `STATE_MIN_FREE_MB` | `5120` | 状态恢复/保存前的最小剩余空间 |
| `DSH_MIN_FREE_MB` | `5120` | 磁盘保护停止阈值 |
| `DSH_TEMP_WARN_MB` | `8192` | 临时目录清理阈值 |
| `DSH_ALLOW_SMALL_SCRATCH` | `false` | 是否允许小于 20GB 的 scratch |

单次运行上限和 checkpoint 间隔不是仓库变量，而是启动时的 `workflow_dispatch` 输入，见下一节。

### 3.7 Cloudflare Named Tunnel

1. 登录 Cloudflare Zero Trust → **Networks → Tunnels → Create a tunnel**。
2. 选择 **Cloudflared**，命名（如 `dsh-web`），创建后复制 **tunnel token**（只显示一次）。
3. 在隧道里添加 **Public Hostname**：
   - Subdomain：`dsh`（或你喜欢的子域）
   - Domain：你的域名
   - Path：留空
   - Service：**HTTP** → `127.0.0.1:3080`
4. 把 token 放进 `CF_TUNNEL_TOKEN` secret（见 3.5）。
5. 可选但推荐：Zero Trust → **Access → Applications → Add an application → Self-hosted**，保护同一个 hostname，策略用邮箱一次性验证码或 allow list。Access 会在 dsh 前面多一层登录，URL 即使泄露也进不来。

不需要在 runner 上放 `config.yml`，也不需要本地运行 `cloudflared`；路由由控制台的 Public Hostname 决定。

### 3.8 允许 Actions 写权限

公共仓库 → Settings → Actions → General → **Workflow permissions** → 选择 **Read and write permissions**。

自动重启和停止兜底都要用 `GITHUB_TOKEN` 调 `gh workflow run` / `gh run cancel`（`actions: write`）；如果仓库策略只允许只读，这两个动作会 403。

## 4. 首次启动

```bash
gh workflow run dsh-web.yml --repo "$REPO" \
  -f auto_restart=true \
  -f restarts_left=0 \
  -f max_runtime_minutes=330 \
  -f checkpoint_minutes=10

gh run list --repo "$REPO" --workflow dsh-web.yml --limit 1
gh run watch --repo "$REPO" <run-id>
```

也可以在 GitHub 页面：Actions → **dsh-web** → Run workflow。

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `auto_restart` | `false` | 是否在正常 deadline 后自动重启 |
| `restarts_left` | `0` | 允许的连续重启次数；每次重启减一 |
| `max_runtime_minutes` | `330` | 单次运行上限，范围 1–330 |
| `checkpoint_minutes` | `10` | checkpoint 间隔，范围 1–60；状态 >2GB 时内部改用 20 |

这四个输入会覆盖同名 `DSH_*` 环境值；不要另外创建 `DSH_MAX_RUNTIME_MIN` / `DSH_CHECKPOINT_MIN` 仓库变量，它们不会生效。

首次运行会：

1. 选择 scratch 挂载点（优先 `/mnt`，不可写时尝试 `/mnt/dsh-scratch`，需 ≥20GB 且 inode ≥5%），设置 `TMPDIR` 等路径。
2. 安装固定版本的 dsh、cloudflared、gitleaks，并校验后两者的 SHA-256。
3. `state.sh init`：没有快照时从空状态开始；有快照时校验并恢复。
4. 启动 cloudflared 和 `dsh web`，解析出带令牌的访问 URL。
5. URL 的持久位置只有私有状态仓库的 `runtime/url.txt`（由私有仓库保护；git 只记录 0644，`publish-url` 在本地 clone 中重写为 0600）；runner 本地的 `RUN_DIR/url.txt` 是临时文件。
6. 之后每 10/20 分钟 checkpoint。

**取 URL**（私有仓库，需已登录且有权限）：

- 打开 <https://github.com/2061969365/dsh-web-state/blob/state/runtime/url.txt>
- 或：私人状态仓库 → 分支 `state` → `runtime/url.txt`

启动通常需要 2–5 分钟。URL 是**访问凭据**，不要粘贴到 issue、聊天或日志里。

## 5. 日常使用

### 模型 key

- 推荐把 `DEEPSEEK_API_KEY` 配成 secret；工作流注入 dsh 进程，不落盘、不打印。
- 其他 provider 的 key 可以在页面里临时填写，但**默认不持久化**，重启后需要重填。

### 打开与重开

- 直接打开 `runtime/url.txt` 里的完整 URL。
- 每次运行（包括自动重启）都会生成新的 URL 和新的 cookie 签名 secret：**重启后必须重新打开新 URL**，旧 URL/旧会话会失效。
- 默认不同步 `.credentials.yaml`，所以不要指望登录态跨运行保留。

### 停止

Actions → **dsh-stop** → Run workflow，或：

```bash
gh workflow run dsh-stop.yml --repo "$REPO"
```

停止工作流会把私有状态仓库的 `DSH_STOP` 变量设为当前 run id。supervisor 每 10 秒检查一次，收到后：

1. 向 dsh 发送 SIGTERM，最多等待 120 秒，必要时 SIGKILL。
2. 停止 cloudflared，清理临时文件（不碰 `DSH_HOME/spill`）。
3. 执行 `state.sh save --final`，然后释放 `runtime/lock.json`。
4. 如果 540 秒内没退出，dsh-stop 兜底调用 `gh run cancel`。

从点下停止到最终保存完成，通常需要 1–3 分钟。不要用 `cancel` 代替正常停止，否则可能丢掉最后一次保存。

### 自动重启与 6 小时行为

- `auto_restart=true` 且 `restarts_left > 0` 时，只有在**正常到达 330 分钟 deadline**、且 final save 和锁释放都成功后，才自动触发下一次运行，并让 `restarts_left` 减一。
- 因 STOP、磁盘不足、崩溃或手动取消退出的，**不会**自动重启。
- 单次 job 上限 355 分钟；自动重启会排队等当前 job 结束，期间有短暂中断，URL 也会变。
- 不重启时，330 分钟后会话结束，原 URL 不可用（通常表现为 Cloudflare 1033/502）。

## 6. 持久化边界

快照只保存“值得保存”的部分，避免把 5GB 预算耗尽。

| 会随快照恢复 | 不会恢复（重启后丢失） |
| --- | --- |
| 会话、附件对象/文件/文件对象 | `$DSH_HOME/.credentials.yaml`（默认排除） |
| `storages` 中的权威 JSON | `$DSH_HOME/spill/`（临时文件，旧 locator 会 404） |
| profile 的 patch / `package.json` / `pnpm-lock` | `profiles/*/node_modules`、`.plugin-manager`、`.dsh-market` |
| skills、`AGENTS.md`、`.anonymous-user-id` | `$DSH_HOME/cache/`、`logs/`、`storages/session_projcache*`、`storages/dsh-context/`、`attachments/v1/tmp/` |
| 工作区中的普通源码文件 | `.env`、`.env.*`、`.npmrc`、`.netrc`、`.git-credentials` 等本地凭据文件 |
| 工作区源码和 lockfile | 工作区的 `.git`、`node_modules`、`.venv`、`__pycache__`、`target/dist/build/.next` 等 |

需要注意：

- **凭据默认不持久化**：cookie secret 每次重建，重启后重新打开私有 URL；需要重新登录/重新填 key。
- **spill 不持久化**：它是临时中转，不是文件存储；重启后旧引用失效。
- **workspace-changes 是临时目录**：按会话创建，会话释放时删除，不跨运行保留。
- **工作区的 `.git` 不保存**：工作区里的 git 历史、remote 和未推送提交不会保留；重要代码请推到远端。
- **快照只有 2 份**：当前和上一份，更早的 release assets 会被删除。
- **5GB 是硬预算**：仓库、数据集、模型权重、大量附件都可能触发 `exit 2`；checkpoint 遇到 exit 2 会停止本次运行，需要清理后再启动。

## 7. 临时文件与磁盘

| 路径/变量 | 值 | 说明 |
| --- | --- | --- |
| `DSH_HOME` | `/home/runner/dsh-home` | dsh 配置、会话、附件、skills |
| `DSH_WORKSPACE` | `/home/runner/work1` | 工作区源码（DSH 默认工作区） |
| `DSH_SCRATCH` | 自动选择 | 优先 `/mnt`（必要时 `/mnt/dsh-scratch`），需 ≥20GB 且 inode ≥5%；否则 `/home/runner` |
| `TMPDIR` / `TMP` / `TEMP` | `$DSH_SCRATCH/dsh-tmp` | 所有临时文件 |
| `STATE_CLONE` | `$DSH_SCRATCH/dsh-state` | 私有状态仓库的临时克隆 |
| `RUN_DIR` | `$DSH_SCRATCH/run` | 日志、`url.txt`、`meta.json`、打包 staging |

scratch 选择会实测候选挂载点的可用空间和 inode。若 `/mnt` 不满足条件而 `/home/runner` 也不够 20GB，工作流默认失败；只有设置仓库变量 `DSH_ALLOW_SMALL_SCRATCH=true` 才会在小于 20GB 的磁盘上继续（不推荐，5GB 状态很容易把根盘写满）。

DSH 的文件工作区只有 `/home/runner/work1` 会被快照保存。新增工作区时请把路径选在 `/home/runner/work1` 或它的子目录下；选择 `/home/runner` 下的其他路径（例如另一个 `work2`）在重启后不会恢复。

### 磁盘保护

- 每 30 秒采样 `/` 和 `$DSH_SCRATCH` 的可用空间与 inode。
- 任一挂载点可用空间低于 **5GB** 或 inode 低于 **3%**：触发停止，保存后退出。
- checkpoint 时统计 `$TMPDIR`；超过 8GB 或剩余空间低于 6GB 时，清理 60 分钟前的 `$TMPDIR/dsh-subprocess-*`。
- DSH 自身没有剩余空间保护，且沙箱还会写 `/tmp`（在根盘上），所以这个外部保护是必要的。

### 临时目录明细

- `$TMPDIR/dsh-workspace-changes-*`：每个会话一个，会话 dispose 时移除；启动/结束时清理陈旧目录，**不会**清理活跃会话。
- `$TMPDIR/dsh-subprocess-*`：每个流最多 64MiB，默认保留；只在磁盘压力下按 60 分钟年龄清理。
- spill：默认根目录在 `$TMPDIR` 下，**不持久化**。
- office-to-pdf、HMR 等临时文件自行清理；SSH 的 `/tmp/dsh-ssh-*` 在启动时清理。
- 启动时清理超过 60 分钟的 `.tmp`、`.tmpdir`、`.staging-*`；保留 `.bak`。

## 8. 安全

- **公共仓库零秘密**：不提交 token、URL、状态、日志或截图；公开 summary 只说明 URL 位于私有 `runtime/url.txt`，绝不打印 URL。
- **状态仓库必须 private**：`state.sh init` 会检查仓库可见性，公开则拒绝启动。`runtime/url.txt` 里的 URL 本身就是访问凭据。
- **PAT 最小权限**：fine-grained、只对 `dsh-web-state` 开放 Contents + Variables，90 天过期并定期轮换。过期是初始化失败最常见的原因之一。
- **Cloudflare Access**：建议开启，给 hostname 套一层邮箱验证码/allow list；URL 泄露时仍有第二道门。
- **令牌不进入 dsh / cloudflared 进程**：启动命令用 `env -u` 剥离 `STATE_REPO_TOKEN`、`CF_TUNNEL_TOKEN`、`DEEPSEEK_API_KEY`、`DSH_NOTIFY_WEBHOOK`、`GH_TOKEN`、`GITHUB_TOKEN`；cloudflared 额外通过 `TUNNEL_TOKEN` 单独传隧道 token。
- **不打印、不进 argv、不进公开 summary**：git 认证走 `GIT_ASKPASS`，token 不拼进 git remote URL；访问 URL 由 supervisor 写入 `$RUN_DIR/url.txt`（0600），`state.sh publish-url` 从文件读取，不作为命令行参数；脚本使用 `umask 077`，日志 0600，禁用 `set -x`。注意：dsh 自身会把带令牌的 URL 打印到 `$DSH_LOG`，该文件仅存在于 runner 本地 scratch（0600），不会上传，也不写入 job summary。
- **无 artifacts**：工作流不上传任何 artifact，避免 URL/令牌随构建产物泄露。
- **上传前扫描**：快照在保存前用 gitleaks 扫描；命中会阻止保存并停止本次运行（exit 5），请先清理状态中的密钥。
- **轮换/应急**：怀疑泄露时，先运行 dsh-stop；随后吊销 PAT、刷新 Cloudflare tunnel token、必要时删除私有 release assets 和 `state` 分支中的 URL 文件。

## 9. 故障排查

### 403 / Invalid Host header / trusted-host

- `DSH_PUBLIC_HOST` 必须与浏览器地址栏的主机名完全一致：只写 `dsh.example.com`，不要 `https://`、路径、端口或结尾斜杠。
- Cloudflare Public Hostname 必须指向同一个主机名，Service 必须是 `http://127.0.0.1:3080`。
- 改完变量后重新运行工作流；运行中的进程不会热更新该值。
- 使用 Access 时确认请求已通过 Access 登录，服务令牌配置正确。

### Cloudflare 1033 / 502 / 530

- **1033**：隧道没有连上。检查 `CF_TUNNEL_TOKEN` 是否有效、是否被刷新过、cloudflared 是否在启动日志里报错；必要时在控制台重新生成 token。
- **502**：cloudflared 已连上，但本地 3080 没有服务。通常是 dsh 还在启动或已崩溃；等待 2–5 分钟，仍失败则看 dsh 日志和 trusted-host 配置。
- **530**：Public Hostname 路由缺失或 DNS 未生效；确认 hostname 绑定在正确的隧道上。
- URL 刚重启后短暂 502/1033 是正常的，等新的 `runtime/url.txt` 出现后再打开。

### 磁盘不足 / job 被终止

- 看运行日志里的磁盘采样；确认 scratch 是否落在 `/mnt`。
- 清理工作区大文件、删除不用的会话/附件、避免克隆大仓库或下载数据集。
- 可用空间低于 5GB 或 inode 低于 3% 时 supervisor 会主动停止并保存；根盘写满会导致 runner 直接失败、来不及 final save。
- 若只有小磁盘，仓库变量 `DSH_ALLOW_SMALL_SCRATCH=true` 可以强行启动，但 5GB 状态预算下风险很高。

### 状态预算超限（save exit 2）

- 原始状态硬上限 5GB，软告警 3GB；超限时 `save` 返回 exit 2，supervisor 会停止本次运行，不会等到下一次 checkpoint。
- 清理工作区大文件、会话/附件后重新启动；连续 3 次普通保存失败也会触发停止。
- 不要通过无限提高 `STATE_BUDGET_MB` 解决：release 单资源仍受 2GiB 限制，2 份快照会成倍占用空间。
- 恢复失败时 `init` 会自动退回 `state.prev.json`；两份都不可用时不会用空状态覆盖，需要按 [dsh-actions/README.md](dsh-actions/README.md) 检查快照指针和 assets。

### profile 插件 / pnpm

- `profiles/*/node_modules`、`.plugin-manager`、`.dsh-market` 不进入快照，恢复后首次加载插件可能变慢或需要重装。
- profile 的 `package.json` 和 `pnpm-lock` 会保留；在 profile 目录执行 `pnpm install` 可重建依赖。
- 如果 runner 上没有 pnpm，先启用：`corepack enable pnpm`（或使用 profile 自带的包管理器）。依赖需要联网下载，首次会明显变慢。
- 插件问题优先看 profile 日志和 dsh 日志；不要通过长期保存 `node_modules` 规避（会迅速吃满 5GB）。

### 自动重启没有发生

- 只有“正常到达 deadline”才会重启；STOP、磁盘不足、崩溃、手动取消都不会。
- 检查 `auto_restart` 和 `restarts_left` 输入；`restarts_left=0` 时不会重启。
- 仓库 Settings → Actions → General 必须是 **Read and write permissions**，否则 `gh workflow run` 会 403。
- `concurrency: dsh-web` 且 `cancel-in-progress: false`，新 run 会排队而不是并行。

### 找不到 URL / 初始化失败

- 确认 `state` 分支和 `dsh-state` release 存在（3.2、3.3）。
- 确认 PAT 未过期、仍有 Contents + Variables 权限，且只授权了 `dsh-web-state`。
- 确认私有仓库没有被误设为 public；`init` 会直接拒绝。
- `runtime/url.txt` 只在 dsh 成功启动并解析出 URL 后写入，dsh 启动失败时不会出现。

### 状态锁 / 并发

- `runtime/lock.json` 记录当前 run id、host、启动时间和心跳；心跳在 45 分钟内且属于其他 run 时，新 run 会拒绝启动，避免两个 job 同时写快照。
- 保存时检测到锁冲突会以 exit 3 停止本次运行；不要强行删除活动锁。
- 正常停止会释放锁；job 被硬取消留下的锁，在心跳超过 45 分钟后会被下一次 `init` 视为陈旧并自动接管。不要盲目并发启动。

## 10. 可选：本机临时目录清理

这一节只针对**本机 Windows 测试**留下的临时目录，与 GitHub Actions 运行无关，完全可以跳过。

先确认路径确实是你不再需要的旧 scratch：

```powershell
if (Test-Path F:\dsh-temp) {
  Get-ChildItem F:\dsh-temp -Force | Select-Object Name,Length,LastWriteTime
}
```

确认后才会删除（不可恢复）：

```powershell
Remove-Item -Recurse -Force F:\dsh-temp
```

不要删除 `F:\dsh-home`、`F:\dsh-work` 或其他仍在使用的目录。

## 11. 文件结构

```text
.
├── .github/workflows/dsh-web.yml   # 启动/监督/自动重启
├── .github/workflows/dsh-stop.yml  # 优雅停止
├── dsh-actions/
│   ├── state.sh                    # 状态初始化、发布 URL、保存/恢复、锁
│   ├── sync-excludes.txt           # home/work 的共同排除规则
│   ├── run.sh                      # cloudflared + dsh supervisor
│   └── README.md                   # 维护者接口与运维细节
├── PLAN.md                         # 设计/实现计划
└── README.md
```

实现细节、`state.sh` 子命令、退出码和恢复流程见 [dsh-actions/README.md](dsh-actions/README.md)。
