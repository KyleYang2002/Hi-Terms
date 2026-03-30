# Hi-Terms 产品定位与需求关键决策

**文档类型:** 需求决策文档
**语言:** 中文
**关联文档:**
- `docs/reqs/hi-terms-vision.md` — 愿景文档
- `docs/reqs/hi-terms-requirements.md` — 需求文档
- `docs/reqs/hi-terms-roadmap.md` — Roadmap 文档
- `docs/SSOT/glossary.md` — 术语表（术语权威定义）

## 1. 背景

在前期讨论中，团队已经形成一个更明确的共识：

- Hi-Terms 不能被理解为只做 AI CLI 会话的窄工具
- Hi-Terms 也不能被理解为完全放弃终端产品本体，只做"外接控制层"
- Hi-Terms 是一个产品的[两个递进大阶段](../SSOT/glossary.md#两大阶段two-phase-model)，先做好终端产品，再构建会话差异化能力

> 两大阶段的完整定义与递进关系参见[愿景文档 §1](../reqs/hi-terms-vision.md#1-产品愿景)。

本决策文档用于统一这些关键理解，并约束后续需求和实现方向。

## 2. 决策一：终端能力是第一大阶段的核心目标

### 决策

Hi-Terms 在产品定位上，首先是一个面向 macOS 的终端产品。[终端能力](../SSOT/glossary.md#终端能力terminal-capabilities)是[第一大阶段](../SSOT/glossary.md#第一大阶段phase-1)的核心目标（阶段目标详见[愿景文档 §1](../reqs/hi-terms-vision.md#1-产品愿景)）。

终端能力不是差异化方向的附属品，而是第一大阶段的主线。只有终端产品本身站稳了，第二大阶段的会话差异化才有意义。

### 影响

- 第一大阶段的主要投入应集中在终端能力和用户体验上
- 不能把 Hi-Terms 收窄成一个只会启动 [AI CLI](../SSOT/glossary.md#ai-cli) 的薄壳
- 第一大阶段的架构设计应为第二大阶段的会话能力预留扩展空间

### 明确边界

- 这不意味着第一大阶段要立即实现 iTerm 的全部功能
- 第一大阶段在做好终端能力的同时，也应重视 AI CLI 的稳定运行和基础体验

## 3. 决策二：AI CLI 是跨阶段的重要场景，但优化边界只在体验层

### 决策

[AI CLI](../SSOT/glossary.md#ai-cli) 是 Hi-Terms 跨阶段最重要、最能体现差异化价值的优先场景（各阶段定位参见[术语表 — AI CLI](../SSOT/glossary.md#ai-cli)）。

无论哪个阶段，Hi-Terms 的优化对象都是宿主体验与交互体验，不是 Prompt 内容本身。

### 应重点优化的内容

第一大阶段的优化重点参见[需求文档 §1.1](../reqs/hi-terms-requirements.md#11-第一大阶段核心能力)，第二大阶段在此基础上进一步扩展结果回传、外部驱动和协作能力（参见[需求文档 §1.2](../reqs/hi-terms-requirements.md#12-第二大阶段核心能力)）。

### 明确边界

> 详见[术语表 — Out of Scope](../SSOT/glossary.md#out-of-scope不做)。

### 影响

- 文档和实现都应避免把"帮用户写更好的 Prompt"写成产品能力
- 高层接口可以传递用户消息，但不应主动篡改其意图

## 4. 决策三：第三方应用驱动 AI CLI 会话是第二大阶段的核心场景

### 决策

Hi-Terms 第二大阶段的开放接口目标，不是提供一个泛泛的"可自动化终端"，而是提供一个"[第三方应用](../SSOT/glossary.md#第三方应用third-party-application)可驱动的本地 AI CLI [会话化承载](../SSOT/glossary.md#会话化承载session-oriented-hosting)宿主"。

第三方应用围绕会话对象，而不是围绕匿名终端文本进行交互。

这一场景属于第二大阶段，建立在第一大阶段终端产品成熟的基础之上。

### 主场景定义

主场景详细描述参见[需求文档 §2.2](../reqs/hi-terms-requirements.md#22-第二大阶段主场景第三方应用驱动-ai-cli-会话)。

核心要点：第三方 macOS 应用（如 Telegram 机器人后端）通过 Hi-Terms 启动并驱动 AI CLI 会话，支持多轮协作，直至任务完成或用户主动停止。

### 对接口定义的要求

Hi-Terms 第二大阶段需要围绕[会话级开放接口](../SSOT/glossary.md#会话级开放接口session-level-open-apis)进行设计。

> 具体接口定义参见[术语表 — Interaction Layer](../SSOT/glossary.md#interaction-layer) 和 [Tool Bridge](../SSOT/glossary.md#tool-bridge)，详细能力需求参见[需求文档 §1.2](../reqs/hi-terms-requirements.md#12-第二大阶段核心能力)。

### 影响

- Hi-Terms 最终不只是给人使用的终端，也应是其他 macOS 应用可调用的本地执行宿主
- 第二大阶段的需求和实现必须考虑第三方应用驱动的多轮协作模型
- 第一大阶段应在架构上为这些能力预留扩展空间

## 5. 决策总结

> Hi-Terms 先要在终端体验上成为高质量的 macOS 终端产品，再在此基础上成为面向 AI CLI 和第三方应用协作场景的本地会话宿主。

完整产品愿景参见[愿景文档 §6](../reqs/hi-terms-vision.md#6-一句话总结)。
