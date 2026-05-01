# Hi-Terms v0.2 三任务手动验证指南

**日期：** 2026-04-30
**适用版本：** main 分支 commit `5a9ef89` 之后
**配套脚本：** `Tools/smoke-aicli.sh`
**预计耗时：** 10-15 分钟

本指南把 `Tools/smoke-aicli.sh` 展开为完整的操作员手册，逐步验证 v0.2 完成的三个任务在真实场景下都生效：

1. True Color + 256 色渲染
2. 窗口 resize → SIGWINCH 链路
3. Bracketed Paste 模式
4. （可选）codex 端到端冒烟
5. 鼠标上报门控（`refs/22.png` 修复回归）
6. CJK 宽字符在反相背景里不出色块（`refs/11.png` 修复回归）

---

## 准备阶段

### A. 构建并启动 Hi-Terms

在你日常的终端里（macOS Terminal / iTerm 都行）：

```bash
cd /Users/amma/Desktop/projects/Hi-Terms
make build
open build/DerivedData/Build/Products/Debug/HiTerms.app
```

**预期：** 弹出一个 Hi-Terms 窗口，显示 zsh/bash 提示符，光标闪烁。

**失败排查：**

- 窗口闪退 → 看 `~/Library/Logs/DiagnosticReports/` 里 HiTerms 的 .ips 文件
- 没提示符但有空白窗口 → 在原终端跑 `log stream --predicate 'subsystem CONTAINS "com.hiterms"' --level info`

### B. 准备一个"参考终端"做对比

打开一个 macOS Terminal 或 iTerm 窗口（与 Hi-Terms 并排），后面有几项需要看两边渲染差异。

---

## 验证 1 — True Color + 256 色

**目的：** 确认 codex / Claude Code 输出的语法高亮（红/橙/紫等非 8 色）能正确显示。

### 步骤

1. **激活 Hi-Terms 窗口**（点一下让它在最前）
2. 在 Hi-Terms 里**逐行手动输入**（或用粘贴 — 一会再做粘贴测试）下面这段：

```bash
# 24-bit RGB 渐变带（红→蓝）
for i in $(seq 0 79); do r=$((i*255/79)); printf '\033[48;2;%d;0;%dm ' "$r" "$((255-r))"; done; printf '\033[0m\n'

# 256 色立方体（16-231，6 行）
for i in $(seq 16 231); do printf '\033[48;5;%dm  \033[0m' "$i"; [ $(((i-15)%36)) -eq 0 ] && printf '\n'; done

# 24 级灰阶（232-255）
for i in $(seq 232 255); do printf '\033[48;5;%dm  \033[0m' "$i"; done; printf '\n'
```

### 通过判定

- **渐变带**：从纯红平滑过渡到纯蓝，**80 列每一格颜色都不同**，没有大块同色阶梯
- **256 色立方体**：6 行 × 36 列彩色块，色相按 R→G→B 平滑变化
- **灰阶条**：24 块从近黑到近白的灰，明显的阶梯但没有跳变

### 失败信号

| 现象 | 可能原因 |
|------|---------|
| 渐变只见红/紫两块色 | True Color 没生效，回退到 ANSI 8 色 |
| 256 色块出现"豆腐块"或全部同色 | 256 色 cube 映射没生效 |
| 灰阶全部纯黑或纯白 | 灰阶分支错误 |

### 与参考终端对比

把同样的命令在 macOS Terminal 里跑一遍，**两边视觉应该几乎一致**（Terminal.app 的 ANSI 16 色配色可能稍有差异，但 256 色 cube 和灰阶必须对齐）。

---

## 验证 2 — 窗口 Resize → SIGWINCH

**目的：** 确认拖窗口时 PTY 收到 SIGWINCH，TUI 程序（vim、top、codex）能跟着重排。

### 步骤 2.1 — 基础信号验证

在 Hi-Terms 里输入：

```bash
trap 'echo ">>> SIGWINCH at $(stty size)"' WINCH
echo "current size: $(stty size)"
while sleep 1; do printf '\rsize=%s    ' "$(stty size)"; done
```

会看到形如 `size=24 80` 的字符串在底部不断刷新。

**现在用鼠标拖 Hi-Terms 窗口的右下角**，先放大到屏幕一半，再缩小回原大小，再拉成很扁很长。

### 通过判定

- 每次拖到一个新尺寸停手，**`size=` 后的数字应该立刻更新**
- 应该能看到几行 `>>> SIGWINCH at 35 120` 这种输出（trap 触发时打印）
- **整个过程进程不死**，循环还在跑

按 `Ctrl+C` 终止循环。

### 失败信号

| 现象 | 可能原因 |
|------|---------|
| 拖窗口后 `size=` 数字不变 | TerminalView.setFrameSize → pipeline.resize 链路没接 |
| 窗口拖动后崩溃或卡住 | resize 触发了重入或线程问题 |
| `size=` 变了但没 `>>> SIGWINCH` 日志 | TIOCSWINSZ 发了但没补 SIGWINCH 信号（注意 PTYProcess.resize 已经显式 `kill(pid, SIGWINCH)`）|

### 步骤 2.2 — TUI 重排验证

```bash
top -o cpu
```

进入 top 之后**立刻拖窗口缩小一半**，再拉大。

### 通过判定

- top 的列宽随窗口宽度调整
- 行数随窗口高度变化（看到的进程条目数量增减）
- 顶部统计面板宽度跟着变
- **没有"残留旧字符"或"光标跑飞"**

按 `q` 退出 top。

---

## 验证 3 — Bracketed Paste（粘贴大段不会被立即执行）

**目的：** 确认从 codex / Claude 复制多行 prompt 粘贴进 Hi-Terms 时，**整段进入编辑缓冲区**，需要你按回车才执行；而不是粘贴瞬间逐行执行。

### 步骤 3.1 — 启用 bracketed paste

在 Hi-Terms 里输入：

```bash
printf '\033[?2004h'
```

> 注：现代 zsh / bash 5+ 默认会自动开启这个模式；这一行是显式确保。

### 步骤 3.2 — 准备一段多行 payload

在你日常的终端（不是 Hi-Terms）里跑：

```bash
pbcopy <<'EOF'
echo first
echo second
echo third
EOF
```

剪贴板现在有 3 行内容。

### 步骤 3.3 — 在 Hi-Terms 里粘贴

激活 Hi-Terms 窗口 → 按 `Cmd+V`。

### 通过判定（重要）

- **三行作为一个整体显示在当前 prompt 右侧**（多行 prompt 编辑），形如：

  ```
  $ echo first
  > echo second
  > echo third
  ```

- **没有任何一行被立即执行**（你不应该看到 `first` `second` `third` 输出）
- 此时按 `Enter`，三个 `echo` 才依次执行

### 失败信号

| 现象 | 可能原因 |
|------|---------|
| 粘贴瞬间就看到 `first` `second` `third` 输出 | bracketed paste 包裹没生效；shell 把每个 `\n` 当回车 |
| 粘贴后只看到第一行 `echo first`，后两行丢失 | paste handler 截断了 |
| 粘贴出现 `^[[200~` 这种字面字符 | shell 没启用 bracketed paste，Hi-Terms 包裹了但 shell 不认 |

### 步骤 3.4 — 关闭模式后对比

```bash
printf '\033[?2004l'
```

再次 `Cmd+V` 粘贴同一段。**这次应该立刻按行执行**（看到 first/second/third 输出）。这反向证明 Hi-Terms 是按 mode 分支处理的，不是无脑包裹。

---

## 验证 4 — codex 端到端（可选，需要密钥）

**目的：** 把上面三件事放到真实 AI CLI 场景里跑一遍。

### 前置

```bash
export OPENAI_API_KEY=sk-...   # 在你启动 Hi-Terms 之前的 shell 里设
codex --version                # 应输出 codex-cli 0.128.0
```

> 环境变量必须在**启动 Hi-Terms 之前**就在父 shell 里设好；如果你已经开了 Hi-Terms，关掉重开。

### 步骤

在 Hi-Terms 里：

```bash
codex
```

进入 codex 交互界面后：

1. **输入一个会让 codex 输出彩色代码的 prompt**，例如：

   ```
   write a python function that prints fibonacci numbers, with comments
   ```

2. **观察输出**：
   - 代码块的语法高亮（关键字、字符串、注释）颜色清晰区分
   - 流式 token 平滑流入，没有卡顿/丢字
3. **等响应中途**，**拖动窗口**改变大小：
   - codex UI 跟着重排，没有错位
4. **按 `Ctrl+C`** 中断当前响应：
   - codex 退回到等待输入状态，终端没乱
5. **粘贴一段多行 prompt**（先用 `pbcopy` 准备一段较长的 prompt）：
   - 整段进入 codex 输入区，需要你确认才发送

### 常见失败

- codex 中途崩溃 / Hi-Terms 窗口冻结 → 收集 `log stream --predicate 'process == "HiTerms"'` 一段
- 颜色塌缩为单色 → 验证 1 的回归
- resize 后 codex 输入框宽度没变 → 验证 2 的回归
- 粘贴瞬间被发送 → 验证 3 的回归

---

## 验证 5 — 鼠标上报门控（refs/22.png 回归）

**目的：** 确认在没有开启鼠标模式的 shell 提示符下点击鼠标，**不会**在屏幕上回显出 `0;50;12M0;50;12m` 这样的 SGR 参数残骸。

### 步骤 5.1 — 默认提示符（mouseMode 应为 .off）

刚启动 Hi-Terms，进入 zsh 提示符，**不**做任何事先准备。

1. 用鼠标左键在窗口里**点击多次**（不同位置）
2. 用鼠标左键**按住拖动**（不抬起），然后抬起
3. 在窗口里**滑动光标**（不按下任何键）

### 通过判定

- 提示符**完全无任何额外字符**输出
- 命令行光标位置不变
- 提示符仍然停在等待输入的状态

### 失败信号

| 现象 | 可能原因 |
|------|---------|
| 点击后行尾出现 `0;50;12M0;50;12m` 这种串 | 鼠标门控失效，重现了 refs/22.png |
| 拖动后出现一长串 `32;...M` | drag 上报没被 `.off` 模式拦截 |
| 移动鼠标也产生输出 | move 路径门控失效或 anyEvent 未生效保护 |

### 步骤 5.2 — vim 启用鼠标后正向验证

```bash
vim /tmp/test.txt
```

进入 vim 后：

```
:set mouse=a
```

然后：

1. 在文件不同位置**单击左键** → 光标应该跳到点击位置
2. **按住左键拖动** → 应该选中区域（visible selection）
3. **滚轮滚动** → vim 应该滚屏

### 通过判定

- 点击能精确定位光标到所点单元格
- 拖动能选区
- 退出 vim 后（`:q!`）回到 shell 提示符，**继续点击不再产生回显**（mouseMode 已自动复位）

### 失败信号

| 现象 | 可能原因 |
|------|---------|
| vim 里点击不能定位光标 | 鼠标上报通路被新门控误杀 |
| 退出 vim 后点击仍产生 `;M;m` 串 | mouseMode 没在 `?1000l` 时复位 |

---

## 验证 6 — CJK 宽字符在反相背景里不出色块

**目的：** 确认 codex / Claude Code 等用反相背景画输入框的 AI CLI，在输入中文时不再出现「字 + 白块」交替的色块（`refs/11.png` 现象）。

### 前置

- 已完成「准备阶段 A」，Hi-Terms 启动并停在 shell 提示符。
- 终端宽度 ≥ 80 列。
- 一个能开 codex 的环境（`codex --version` 正常；`OPENAI_API_KEY` 已在父 shell 里设好）。

### 步骤

1. 在 Hi-Terms 里启动 codex：
   ```bash
   codex
   ```
2. 进入 codex 输入框（光标在反相/高亮的输入区里闪烁）。
3. 用系统输入法**逐字输入**下面这段中文，然后**先不要回车**，停在输入框里观察：
   ```
   我要编写报志愿应用，给我一些建议。
   ```
4. 截图当前画面，与修复前的 `refs/11.png` 对照。
5. 在同一行**继续混入英文**：
   ```
   please use Python 3.12.
   ```
   观察中英文混排的连续性。
6. 按 `Backspace` 一次次删除最后的中文字符（一次删一个全角字），观察行尾是否有残影或白块漏出。
7. 全删后重新输入一次，重复 step 3-6 验证稳定性。
8. 按 `Ctrl+C` 取消 prompt，按 `Ctrl+D` 退出 codex 回到 shell。

### 通过判定

- **整行底色完全均匀**——反相输入区从行首到行尾就是一块连续的反相底色，每个汉字的右半边没有任何「白色／默认背景」露出。
- 切英文继续输入，英文区域颜色与中文区域一致，**没有跳变**。
- `Backspace` 删除一个汉字时，整行**整体重排无残影**：被删字符所在的两列同时复位为空；不会出现「左半边消失、右半边白块还在」的撕裂。
- 光标停在汉字上时，光标块**横跨两个 cell**（覆盖整个汉字），不再只压住左半边。

### 失败信号

| 现象 | 可能回归点 |
|------|-----------|
| 每个汉字右侧出现白色／浅色块（与 `refs/11.png` 一致） | `drawRowBackground` 又开始把 `width == 0` 的副格按默认 attr 单独填，参见 `CoreTextRenderer.swift:172-223` |
| 整行底色对，但光标只覆盖汉字左半边 | `updateCursor` 没有再按 `cellWidthMultiplier=2` 拓宽，参见 `CoreTextRenderer.swift:420-433` |
| 删除一个汉字后行尾残留半截色块 | dirty region 没把宽字符两列都纳入重绘；或 SwiftTermAdapter 的 width 透传断了 |
| 中文 + 英文混排在交界处闪烁／错位一格 | 副格被某条 run 误吃进了文本绘制（`drawRowText` 里跳过 width==0 的逻辑回退） |

### 与参考终端对比

打开一个 macOS Terminal 或 iTerm 窗口并行做同样的事（启 codex → 输同样中文 → 切英文 → 删字）：

- Hi-Terms 的输入区底色应**与参考终端一致连贯**，无附加白块。
- 如果参考终端也出现色块，先确认参考终端字号/字体是否会触发它自己的 wide-char bug；然后才能判断 Hi-Terms 是否回归。

### 截图引用

- 修复前：`refs/11.png`（codex 输入区每字旁有白色块）
- 修复后：`refs/11-fixed.png`（待 lead 在本次验证后截屏并放入）

---

## 整体通过门槛

如果验证 1-3 全部通过，**v0.2 这三个任务就算交付**。

验证 4 是质量加分项，失败时不一定阻塞（codex 自身可能也有兼容性问题），但要记录现象。

---

## 出现问题时收集什么

任意失败请保存：

```bash
log show --predicate 'subsystem BEGINSWITH "com.hiterms"' --info --last 10m > /tmp/hiterms-debug.log
```

把这个 log 贴回来，便于定位是 PTY / SwiftTerm / 渲染 / UI 哪一层。

---

## 验证完成后的记录模板

| 验证项 | 通过/失败 | 备注 |
|-------|----------|------|
| 1. True Color 渐变 | | |
| 1. 256 色立方体 | | |
| 1. 灰阶 | | |
| 2. SIGWINCH 信号 | | |
| 2. TUI (top) 重排 | | |
| 3. bracketed paste 包裹 | | |
| 3. mode 关闭后回退 | | |
| 4. codex 流式输出 | | |
| 4. codex 中途 resize | | |
| 4. codex 多行粘贴 | | |
| 5. 默认提示符鼠标点击无回显 | | |
| 5. vim `:set mouse=a` 点击/拖动 | | |
| 6. codex 中文输入无白色色块 | | |
| 6. CJK + 英文混排正常 | | |
| 6. backspace 删除汉字无残影 | | |
