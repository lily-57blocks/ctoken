# CToken-FSB: Canton Network Token 实现

## 概述

CToken-FSB 是一个基于 Canton Network 的 token 实现，发行名为 **FSB** 的固定供应量 token。项目遵循 **CIP-56 (Canton Network Token Standard)** 标准，使 FSB token 可以被标准钱包和应用识别和操作。

- **包名**: `ctoken-fsb`
- **版本**: `0.0.2`
- **SDK**: Daml 3.4.11
- **Token 名称**: FSB
- **总供应量**: 1,000,000（固定，不可追加铸造）
- **发行方**: AppProvider（作为 `admin`）

---

## 目录结构

```
ctoken/
├── daml.yaml                         # Daml 包配置
├── mint-fsb.sh                       # 部署 + 铸造脚本
├── query-fsb-holdings.sh             # 持仓查询脚本
├── ctoken.md                         # 本文档
└── daml/CToken/
    ├── FSBHolding.daml               # Token 持仓合约
    ├── FSBTransfer.daml              # FOP 转账工厂
    ├── FSBAllocation.daml            # DVP 资产分配
    └── FSBIssuer.daml                # Token 发行合约
```

---

## 合约功能详解

### 1. FSBHolding — Token 持仓

**文件**: `daml/CToken/FSBHolding.daml`

表示某个 Party 持有的 FSB token 数量。这是整个 token 系统的核心数据结构。

| 字段 | 类型 | 说明 |
|------|------|------|
| `admin` | Party | Token 注册中心管理员 (AppProvider) |
| `owner` | Party | 持有者 |
| `amount` | Decimal | 持有数量 (必须 > 0) |
| `lock` | Optional Lock | 锁定状态（用于 DVP 分配） |
| `meta` | Metadata | CIP-56 通用元数据 |

**权限模型**:
- `signatory admin` — admin 全权管理（中心化注册中心模式）
- `observer owner` — 持有者可以看到合约

**提供的 Choice**:

| Choice | 控制方 | 功能 |
|--------|--------|------|
| `FSBHolding_Transfer` | admin | 将指定数量转给接收方，自动创建找零 |

**CIP-56 接口**: 实现 `Holding` 接口

```
InstrumentId = { admin: <AppProvider Party>, id: "FSB" }
```

### 2. FSBTransferFactory — FOP 转账工厂

**文件**: `daml/CToken/FSBTransfer.daml`

实现 CIP-56 的 FOP (Free of Payment) 点对点转账。工厂合约由 admin 创建一次，长期存在于 ledger 上。

| 字段 | 类型 | 说明 |
|------|------|------|
| `admin` | Party | Token 注册中心管理员 |

**CIP-56 接口**: 实现 `TransferFactory` 接口

| 接口方法 | 功能 |
|---------|------|
| `transferFactory_publicFetchImpl` | 公开查询工厂信息（验证 admin） |
| `transferFactory_transferImpl` | 执行 FOP 转账 |

**转账流程** (`transferFactory_transferImpl`):

```
输入: sender 的一个或多个 FSBHolding (inputHoldingCids)
  │
  ├── 1. 验证 instrumentId (admin + "FSB")
  ├── 2. 消耗所有输入 Holding，累计总额
  ├── 3. 检查总额 >= 转账金额
  ├── 4. 创建 receiver 的新 FSBHolding (amount = 转账金额)
  └── 5. 创建 sender 的找零 FSBHolding (amount = 总额 - 转账金额)

输出: TransferInstructionResult_Completed
  ├── receiverHoldingCids: 接收方的 Holding
  └── senderChangeCids: 发送方的找零 Holding
```

**特点**: 转账在单笔交易中立即完成（不需要接收方预先批准）。

### 3. FSBAllocation — DVP 资产分配

**文件**: `daml/CToken/FSBAllocation.daml`

实现 CIP-56 的 DVP (Delivery vs Payment) 原子化结算。允许将 FSB token 锁定到一个结算请求中，支持多资产原子化交割。

| 字段 | 类型 | 说明 |
|------|------|------|
| `admin` | Party | Token 注册中心管理员 |
| `sender` | Party | 资产发送方 |
| `receiver` | Party | 资产接收方 |
| `amount` | Decimal | 分配的金额 |
| `transferLegId` | Text | 结算中的转账腿标识 |
| `settlement` | SettlementInfo | 结算信息（执行者、截止时间、引用） |
| `lockedHoldingCids` | [ContractId Holding] | 被锁定的 Holding 合约 |
| `meta` | Metadata | CIP-56 通用元数据 |

**权限模型**:
- `signatory admin, sender` — admin 和发送方共同签名

**CIP-56 接口**: 实现 `Allocation` 接口

| 接口方法 | 功能 |
|---------|------|
| `allocation_executeTransferImpl` | 执行转账：消耗锁定 Holding，创建接收方 Holding |
| `allocation_cancelImpl` | 取消分配：解锁 Holding 归还给发送方 |
| `allocation_withdrawImpl` | 撤回分配：解锁 Holding 归还给发送方 |

**DVP 流程**:

```
1. 创建 FSBAllocation (锁定 sender 的 Holding)
       │
       ├── 等待结算条件满足...
       │
       ├── 成功路径: allocation_executeTransferImpl
       │   ├── 消耗锁定的 Holding
       │   └── 创建 receiver 的新 Holding
       │
       ├── 取消路径: allocation_cancelImpl
       │   └── 解锁 Holding 归还 sender
       │
       └── 撤回路径: allocation_withdrawImpl
           └── 解锁 Holding 归还 sender
```

### 4. FSBIssuer — Token 发行

**文件**: `daml/CToken/FSBIssuer.daml`

用于初始铸造 FSB token。设计为一次性使用，铸造后合约被消耗以保证固定供应量。

| 字段 | 类型 | 说明 |
|------|------|------|
| `admin` | Party | 发行方 (AppProvider) |
| `totalSupply` | Decimal | 总供应量 (必须 > 0) |
| `minted` | Bool | 是否已铸造 |

**提供的 Choice**:

| Choice | 类型 | 控制方 | 功能 |
|--------|------|--------|------|
| `FSBIssuer_Mint` | 消耗型 | admin | 铸造全部供应量到指定接收方 |
| `FSBIssuer_Split` | 非消耗型 | admin | 将一个 Holding 拆分为两个 |

**CIP-56 接口**: 无（这是自定义的发行逻辑，CIP-56 不定义铸造接口）

**铸造流程**:

```
1. 创建 FSBIssuer (totalSupply = 1000000)
       │
2. 执行 FSBIssuer_Mint (recipient = AppProvider)
       │  ← 合约被消耗，不能再次铸造
       │
3. 得到 FSBHolding (owner = AppProvider, amount = 1000000)
       │
4. 可选: FSBIssuer_Split 拆分 Holding 用于分发
```

---

## CIP-56 合规性分析

CIP-56 定义了 6 个标准 API，以下是 ctoken-fsb 的实现情况：

### 已实现的接口

| CIP-56 API | Daml 接口 | ctoken-fsb 实现 | 合约 |
|------------|-----------|:---------------:|------|
| **Holdings API** | `Holding` | ✅ 完整实现 | FSBHolding |
| **Transfer Instruction API** | `TransferFactory` | ✅ 完整实现 | FSBTransferFactory |
| **Allocation API** | `Allocation` | ✅ 完整实现 | FSBAllocation |

### 未实现的接口

| CIP-56 API | Daml 接口 | 状态 | 原因 |
|------------|-----------|:----:|------|
| **Token Metadata API** | (off-ledger HTTP) | ❌ 未实现 | 需要 off-ledger HTTP 服务提供 symbol、total supply、logo 等元数据 |
| **Allocation Request API** | `AllocationRequest` | ❌ 未实现 | 供应用请求钱包分配资产，当前无应用层集成 |
| **Allocation Instruction API** | `AllocationInstruction` | ❌ 未实现 | 供钱包创建分配指令，当前无钱包集成 |

### 未实现的标准功能

| 功能 | 说明 |
|------|------|
| **TransferInstruction 多步骤流程** | 当前 TransferFactory 直接完成转账。CIP-56 允许注册中心使用多步骤流程（如需要接收方接受、内部审批等），FSBTransferFactory 未实现 `TransferInstruction` 接口的 Accept/Reject/Withdraw/Update 方法 |
| **Off-ledger Registry HTTP API** | CIP-56 要求注册中心提供 HTTP 端点用于发现工厂合约、获取 choice context 等。ctoken-fsb 没有 off-ledger 服务 |
| **CNS 元数据集成** | CIP-56 建议在 Canton Name Service 条目中存储注册中心的 URL 和元数据 |
| **Holding Lock 机制** | FSBHolding 包含 `lock` 字段但未实现锁定/解锁逻辑 |

### 自定义扩展（非 CIP-56 标准）

| 功能 | 合约 | 说明 |
|------|------|------|
| `FSBHolding_Transfer` | FSBHolding | 直接在 Holding 上的转账 choice，绕过 TransferFactory（便于通过 JSON API 调用） |
| `FSBIssuer` | FSBIssuer | Token 铸造逻辑，CIP-56 不定义铸造标准 |
| `FSBIssuer_Split` | FSBIssuer | Holding 拆分功能，用于初始分发 |

---

## 合规性总结

```
CIP-56 六大 API 覆盖情况:

  ✅ Holdings API          — FSBHolding 实现 Holding 接口
  ✅ Transfer Instruction  — FSBTransferFactory 实现 TransferFactory 接口 (即时完成模式)
  ✅ Allocation API        — FSBAllocation 实现 Allocation 接口
  ❌ Token Metadata API    — 需要 off-ledger HTTP 服务
  ❌ Allocation Request    — 需要应用层集成
  ❌ Allocation Instruction— 需要钱包集成

  On-ledger 合规度: 3/4 (75%)    ← Daml 接口
  Overall 合规度:   3/6 (50%)    ← 含 off-ledger API
```

**当前状态**: ctoken-fsb 实现了 CIP-56 的核心 on-ledger 接口（Holding + TransferFactory + Allocation），足以支持基本的 token 持仓查看、FOP 转账和 DVP 结算。要实现完整的 CIP-56 合规需要补充 off-ledger HTTP 服务和钱包/应用集成层。

---

## 依赖的 Splice 标准包

| DAR | 提供的接口 |
|-----|----------|
| `splice-api-token-metadata-v1-1.0.0.dar` | `Metadata`, `ExtraArgs`, `ChoiceContext` 等通用类型 |
| `splice-api-token-holding-v1-1.0.0.dar` | `Holding` 接口, `InstrumentId`, `HoldingView`, `Lock` |
| `splice-api-token-allocation-v1-1.0.0.dar` | `Allocation` 接口, `AllocationView`, `TransferLeg`, `SettlementInfo` |
| `splice-api-token-transfer-instruction-v1-1.0.0.dar` | `TransferFactory`, `TransferInstruction` 接口 |

---

## 配套工具脚本

| 脚本 | 用途 |
|------|------|
| `mint-fsb.sh` | 上传 DAR + 创建 Issuer + 铸造 FSB（一键部署） |
| `query-fsb-holdings.sh` | 按用户名查询 FSB 持仓余额 |

外部配套项目:

| 项目 | 路径 | 用途 |
|------|------|------|
| `ctoken-transfer` | `../ctoken-transfer/` | TypeScript 转账脚本，通过 JSON Ledger API v2 执行 FSBHolding_Transfer |
