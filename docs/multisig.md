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
- 历史数据：本规则上线前，前端曾自动为老钱包补齐三条链（`addMissingChainRows`，已删除），生产上因此存在一些没用过的 Arbitrum / 主网行。

### owner 变更：一次对所有链发起

- `propose_multisig_tx_group`：每条链一笔，共享 `group_id`。calldata 由前端按链编码——`removeOwner` / `swapOwner` 的 prevOwner 取决于该链 owner 链表：已部署读链上，未部署按排序后的初始 owner（Safe 按 initializer 顺序建链表）。fork 测试「未部署的链上：部署与 removeOwner 在同一笔 UserOp 里完成」验证了这一点。
- 只发到**已启用**的链（有行的链）。必须覆盖所有「当前用户是 owner、变更仍适用、且没有同一变更在进行」的链（`required_group_wallets`），否则返回 `group_required` 和缺的 `chain_ids`。`propose_multisig_tx` 对配置类交易同样检查，因此单链只能在其他链都已生效时发起（例如重提某条链上失败的交易）。
- 同一变更已在某链进行中时拒绝重复发起（`change_already_pending`）。
- 各链独立签名（SafeOp 哈希含 chainId）、独立执行与确认，失败单链重试不回滚。详情页「所有链」卡片提供「为所有链签名」「执行所有就绪的链」，输入一次支付码后逐链处理并汇总结果。
- 撤回（`withdraw_multisig_tx`）会一并撤回同组其他链上尚无人签名的交易。
- 可见性按链：某条链确认后，新 owner 在该链上即可见；其他链未执行前在那些链上仍不可见，与链上状态一致。
