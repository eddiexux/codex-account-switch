# Codex Account Switch

macOS 菜单栏小工具：展示多个 ChatGPT 账号在 Codex 里的额度与重置时间，一键切换当前使用的账号。

切换动作**只原子替换 `~/.codex/auth.json`**，不碰 `config.toml` 或任何其他配置。

## 功能

- 右上角菜单栏显示当前账号的周额度已用百分比
- 菜单面板（精简版）：每个账号一行，含邮箱、套餐、周额度条与重置时间、重置卡张数角标；「切换到此账号」把目标账号的登录态写入 `auth.json`
- 详情窗口（菜单右上角的窗口图标、双击账号行或点重置卡角标打开）：左侧账号列表，右侧完整信息——全部额度窗口、每周节奏与速度预测、按模型单独计量的额度（如 GPT-5.3-Codex-Spark）、重置卡明细与兑换、最近 7 天用量曲线
- 重置卡（rate limit reset credit）：OpenAI 不定期赠送，兑换后把已达上限的额度窗口清零。窗口里显示每张卡的过期时间，「使用一张重置卡」二次确认后优先消耗最早过期的那张（与 codex-lb 一致）；当前没有窗口达上限时服务端会返回「无需重置」并保留卡片
- 「添加账号…」/「重新登录…」：运行 `codex login --device-auth`，面板里直接显示登录链接和一次性代码，复制到任意浏览器（换账号可用隐私窗口）完成授权后自动入库；不自动弹浏览器，不占本机回调端口
- 每 5 分钟自动刷新额度；打开面板时若超过 1 分钟未刷新也会刷新
- 可选开机自启（需以 `.app` 形式运行）

## 安装

要求 macOS 14+ 与 Xcode Command Line Tools（`xcode-select --install`），不需要完整 Xcode。

```bash
git clone git@github.com:eddiexux/codex-account-switch.git
cd codex-account-switch
scripts/build-app.sh --install   # 构建、打包、安装到 ~/Applications 并启动
```

首次启动会把当前 `~/.codex/auth.json` 登记为第一个账号；再点「添加账号…」，把面板里的链接和代码粘到隐私窗口用另一个 ChatGPT 账号登录即可。

## 工作原理与安全边界

数据来源：

- 账号身份来自 `auth.json` 里 `id_token` 的 `email` / `chatgpt_plan_type` 声明（仅解码，不校验签名，不用于鉴权）
- 额度来自 `GET https://chatgpt.com/backend-api/wham/usage`，与 Codex CLI `/status` 同源；其中 `rate_limit_reset_credits.available_count` 是重置卡张数，`applicable_available_count` 表示此刻是否有窗口可被清零
- 重置卡明细与兑换走 `GET/POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits[/consume]`，与 Codex TUI 的「Redeem usage limit reset」和 codex-lb 同一接口；兑换请求带随机 `redeem_request_id`，不幂等、失败不重试

账号快照存放在 `~/Library/Application Support/CodexAccountSwitch/accounts/<account_id>.json`，目录 0700、文件 0600，内容就是对应账号完整的 `auth.json` 原始字节。

四条不变量：

1. **live 优先回写。** Codex 每次续期都会轮换 refresh token，旧副本一旦复用会被 OpenAI 永久拒绝。因此任何切换或登录前，工具都先把当前 `auth.json` 回写到它所属账号的槽位，再写入目标账号。
2. **活跃账号的令牌只由 Codex 维护。** 工具只为待机账号续期（访问令牌距过期不足 24 小时或收到 401 时），续期结果写回槽位；绝不替活跃账号刷新，避免与 Codex 进程竞争同一条 refresh token 链。
3. **登录前先清空 live。** `codex login` 开始时会对现有 `auth.json` 执行 `logout_with_revoke`，在服务端作废当前账号的令牌（返回 `refresh_token_invalidated`）。工具在运行它之前先把当前账号回写到槽位、再删除 `auth.json`，登录流程就无东西可撤销；登录失败或被中断时自动从槽位恢复上一账号。**不要在工具之外手动运行 `codex login`**，否则当前账号会被作废。
4. **原子写入。** 写 `auth.json` 与槽位文件都走同目录临时文件 + `rename`，Codex 任何时刻读到的都是完整文件。

已在运行的 Codex 进程（ChatGPT 桌面端内置 app-server、Paseo、终端 TUI）在内存里持有旧账号令牌。Codex 自身在刷新前会重读 `auth.json` 并比对 account_id，不一致就跳过刷新，所以旧进程不会把新账号覆盖回去；但它们也不会自动换到新账号，**切换只对新会话生效**。面板底部会显示当前运行的 Codex 进程数作为提示。

## 与 codex-lb 的关系

本工具是单机、单活账号的轻量方案，不做负载均衡。若之前使用 codex-lb，需要自行把 `config.toml` 的 `model_provider` 改回默认并停掉 codex-lb 服务；本工具不会替你修改这些配置。

## 排障

- 日志：`~/Library/Logs/CodexAccountSwitch.log`（只有动作与错误摘要，不含令牌）
- 登录进程优先使用 ChatGPT.app 内置的原生 `codex` 二进制，而不是 `~/.local/bin/codex` 这类 codex-hud / npm 包装器：包装器被终止时子进程会残留（曾出现残留的浏览器登录进程长期占着 1457 端口，导致后续登录报 `Port … already in use`，用 `lsof -nP -iTCP:1457 -sTCP:LISTEN` 可查）
- 某账号显示「需重新登录」：其 refresh token 已在服务端作废（过期、被复用或被 `codex login`/`codex logout` 撤销），点卡片上的「重新登录…」

## 开发

```bash
swift build            # 调试构建
swift run selftest     # 契约自测（Command Line Tools 没有 XCTest）
.build/debug/CodexAccountSwitch   # 直接运行（无 .app 包时"开机自启"不可用）
CAS_OPEN=window .build/debug/CodexAccountSwitch   # 启动即打开详情窗口，便于截图核对
CAS_OPEN=menu .build/debug/CodexAccountSwitch     # 用普通窗口预览菜单面板（菜单栏弹窗无法脚本化打开）
scripts/build-app.sh   # 打包到 build/
scripts/make-icon.sh   # 改过 Resources/AppIcon.svg 后重新生成 AppIcon.icns（需 brew install librsvg）
```

## License

MIT
