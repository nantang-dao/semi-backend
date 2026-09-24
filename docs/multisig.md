# 多签钱包：owner 可见性与多链

## 新 owner 如何看到钱包

`get_wallets`（`app/controllers/multisig_controller.rb`）按地址匹配：
`LOWER(wallet_owners.owner_address) = current_user.evm_chain_active_key`，不依赖 `user_id`。
因此新 owner 无论在被加入之前还是之后注册，登录后都能看到钱包——前提是 `wallet_owners` 已更新。

`wallet_owners` 的更新路径：

1. 前端执行 owner 变更交易后调用 `confirm_multisig_tx`；
2. 后端 `verify_userop_receipt!` 在链上校验回执；
3. `apply_wallet_config_from_executed_tx!` 按 `call_detail` 增删 owner、改 threshold。

另有 `sync_multisig_wallet` 从链上读 `getOwners`/`getThreshold` 全量覆盖，由 `pages/multisig/[id]`、`owners`、`queue` 页面触发。

### 已知看不到的情况（有意不做兜底）

- **在 Semi 之外执行**（Safe 官方界面、直接调合约）：后端镜像不变，需已有 owner 打开上述页面触发 sync。新 owner 自己无法触发，因为钱包不在他的列表里。
- **执行后没有 confirm**（关页面、断网）：交易停在 `executing`，需其他 owner 进 queue 页面处理。
- **owner 更换了 `evm_chain_active_key`**：地址不再匹配。

决定：`get_wallets` **不**增加链上 `isOwner` 兜底查询。遇到上述情况由已有 owner 触发 sync 解决。

## 多链（Ethereum 主网 / Optimism / Arbitrum）

### 约定

- 交互：前端保持**全局切换网络**，所有页面只展示当前链。
- Gas：OP、Arbitrum 由 ZeroDev self-funded paymaster 代付；主网不代付，Safe 自付（执行前检查余额）。
- Gas 额度：`remaining_gas_credits` 全局一个数，三条链都以 ETH 计价。

### 数据模型：一链一行

- 同一 Safe 地址在每条链上是一行 `wallets`，唯一索引 `(evm_chain_address, chain_id) WHERE wallet_type = 'multisig'`。
- 链组见 `Wallet::MULTISIG_CHAIN_GROUPS`（前端 `utils/multisig_chains.ts` 同步）：`[10, 42161, 1]` 与测试网 `[11155111]`，组间不关联。
- owner、threshold、`queue_position`、nonce 都挂在行上，天然按链隔离。
- **每一行的 owner 就是 Safe 在那条链上的有效 owner。** 已部署的链是链上状态；未部署的链是初始配置，第一笔 UserOp 用它生成 initCode。所以建快照、签名、执行只看这一行，semi-core 不需要感知多链。
- `wallets.initial_owners` / `initial_threshold`：部署用的初始配置（owner 已排序）。新钱包创建时写入；老钱包由迁移还原（最早一笔已执行配置交易的 `owner_snapshot` + `threshold_at_creation`，没有则取当前值）。

### 创建与启用链

- 钱包**默认只在创建时的那条链上**。Arbitrum、主网都不是默认开启的，由成员按需手动启用：不是每个钱包都要用主网（自付 gas），也不该为不用的链生成 owner 变更提案。
- `create_multisig_wallet` 支持 `chain_ids`，前端只传当前链。
- 启用：钱包主页的链状态里点「启用」→ 前端 `enableMultisigChain` 先用初始配置**预测地址**，与 Safe 地址一致才调 `add_multisig_wallet_chains` 按初始配置建行。任一 owner 都可以启用，不需要多签审批（启用只建后端记录，不上链、不花钱）。
- **成员或门槛变更过后不能再启用新链**：未部署的链上 Safe 的有效成员只能是初始成员（地址由它算出），变更过的钱包在新链上生效的会是旧成员（包括已被移除的人）。后端检查所有已启用链的行 owner/threshold 都等于初始配置，否则返回 `config_changed`；有进行中（非终态）的配置类交易时返回 `config_change_pending`（否则那笔变更不会发到新链，执行后同样分叉）。
- 地址本身无法「关闭」：没启用的链上，这个地址照样能收款，初始成员随时可以部署并动用。
- 切换网络时 `alignActiveWalletToChain` 把当前多签钱包换成同地址在新链上的行；没在那条链启用（或当前用户在那条链上不是 owner）时退回个人钱包并提示。钱包列表按 Safe 地址去重，没在当前链启用的钱包也列出，点击时切到它已启用的链（优先已激活的）。
- 历史数据：本规则上线前曾自动为所有钱包建三条链的行，见下文「设计变更记录」。

### owner 变更：一次对所有链发起

- `propose_multisig_tx_group`：每条链一笔，共享 `group_id`。calldata 由前端按链编码——`removeOwner` / `swapOwner` 的 prevOwner 取决于该链 owner 链表：已部署读链上，未部署按排序后的初始 owner（Safe 按 initializer 顺序建链表）。fork 测试「未部署的链上：部署与 removeOwner 在同一笔 UserOp 里完成」验证了这一点。
- 只发到**已启用**的链（有行的链）。必须覆盖所有「当前用户是 owner、变更仍适用、且没有同一变更在进行」的链（`required_group_wallets`），否则返回 `group_required` 和缺的 `chain_ids`。`propose_multisig_tx` 对配置类交易同样检查，因此单链只能在其他链都已生效时发起（例如重提某条链上失败的交易）。
- 同一变更已在某链进行中时拒绝重复发起（`change_already_pending`）。
- 各链独立签名（SafeOp 哈希含 chainId）、独立执行与确认，失败单链重试不回滚。详情页「所有链」卡片提供「为所有链签名」「执行所有就绪的链」，输入一次支付码后逐链处理并汇总结果。
- 撤回（`withdraw_multisig_tx`）会一并撤回同组其他链上尚无人签名的交易。
- 可见性按链：某条链确认后，新 owner 在该链上即可见；其他链未执行前在那些链上仍不可见，与链上状态一致。

## 执行与失败

执行逻辑只有一份：`semi-app/utils/multisig_execute.ts`，详情页和队列页都调用它（以前两页各写一套，队列页漏了余额检查）。

- 锁定前先查余额：自付 gas 的链按 gas 上限 × `maxFeePerGas` 预付，转账再加上转出金额；不够就直接提示，不锁定。
- `execute_multisig_tx` 把交易锁成 `executing`，同时记 `executor_id` 和 `updated_at`。
- bundler 当场拒收、交易没上链，并且换个时机可能成功（出价低于 bundler 最低价、AA21 预付不足）：锁定者调用 `reset_executing_multisig_tx` 立即退回 `ready`（其他人仍需等 5 分钟），提示原因。
- 同一份快照永远不可能成功（AA24 签名、AA25 nonce、快照过期、上链后调用回滚）：`fail_multisig_tx`，需要重新发起。
- 已提交但等回执超时：保持 `executing`，不能当失败（可能仍会上链，当失败会诱导重复发起）。
- gas 价格在第一个签名者建快照时冻结（进 SafeOp 哈希），所以快照里的 `maxFeePerGas` 在 bundler 报价上留了余量（L1 1.5 倍、L2 3 倍）；详情页显示的是「最高手续费」，实际按链上价格扣。

2026-09-24 的事故：`0xab7b…` 的「门槛 2→3」分组提案，Arbitrum 那笔在提案 15 小时后执行，bundler 最低价比冻结的出价高 0.5% 被拒；主网那笔从队列页执行，余额 0.0001 ETH 不够预付约 0.000265 ETH，但队列页没做余额检查。两笔都被标成了 failed。以上规则就是为此修的。

## 设计变更记录

### 2026-09：多链从「自动全开」改为「按钱包启用」

**原设计**（2026-09-15 上线，semi-app `4db0764`、semi-backend `70ba07e`，由 Claude 在开发会话中设计实现）：

- 新建多签钱包时，一次在 OP、Arbitrum、主网各建一行 `wallets`。
- 老钱包在前端 `fetchWallets` 时由 `addMissingChainRows` 自动补齐同组其他链的行（按初始配置，先预测地址对得上才补）。
- 只建后端记录，**不在链上部署**：各链的 Safe 仍在该链第一笔多签交易执行时由 initCode 部署。

产品要求只有「全局切换网络」和「owner 变更一次发到所有链」，并没有要求每个钱包默认在所有链上可用；这是实现时的推断，未与产品确认。

**问题**：

1. 不是每个钱包都会用主网（主网自付 gas）或 Arbitrum，但每次 owner 变更都会给这些链生成提案——主网那笔没有 ETH 就永远停在「待执行」，有人充值执行就是为不用的链花钱部署。
2. 未部署的链上 Safe 的有效成员只能是**初始成员**（地址由它算出）。成员变更过的钱包被补链后，新链上生效的是旧成员，可能包括已被移除的人。生产上 `0x7ea2…`（`3mnvjcz423wzl`）就属于这种情况。

**影响**：生产上自动建了 5 条 Arbitrum 行、5 条主网行。没有任何一条因此在链上部署或发生资金往来；`0x7ea2…` 的两条行链上均未部署、余额为 0，没有造成实际影响。

**修正**（2026-09-23，semi-app `958d98e`、semi-backend `b28e925`）：

- 钱包默认只在创建时的那条链上，Arbitrum、主网由任一 owner 手动启用（`add_multisig_wallet_chains`），不需要多签审批。
- 成员或门槛变更过、或有进行中的成员变更时，不能启用新链（`config_changed` / `config_change_pending`）。
- 删除 `addMissingChainRows`。

**数据清理**（2026-09-24）：逐条核对「多签行、链为 1 或 42161、无多签交易、无按钱包或按地址记录的交易、链上无代码、余额为 0」后，在一个事务里删除了 6 行（连同 `wallet_owners`）：

| id | 链 | 地址 |
|---|---|---|
| `3mw6hng6xwp5k` | 主网 | `0x65d7…` |
| `3mw6hnf6afdyt` | Arbitrum | `0x65d7…` |
| `3mvzjnfzqkotd` | 主网 | `0x7ea2…` |
| `3mvzjnf3d55gw` | Arbitrum | `0x7ea2…` |
| `3mvk5f4mzytba` | 主网 | `0xd03b…` |
| `3mvk5f3qb4b4x` | Arbitrum | `0xd03b…` |

保留：`0xab7b…` 的 Arbitrum 行（核对时已有 2 笔多签交易）和主网行（地址上有 0.0001 ETH，有人在测试）；`0xc0cf…` 的 Arbitrum、主网行（都有交易，主网已部署）。被删行的钱包之后仍可手动启用；`0x7ea2…` 成员变更过，按新规则不能再启用新链。
