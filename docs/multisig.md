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

## 多链（Ethereum 主网 / Optimism / Arbitrum）约定

- 交互方式：前端保持**全局切换网络**，所有页面只展示当前链。
- Gas 代付：OP、Arbitrum 代付；主网不代付（主网 Safe 需自备 ETH）。
- Gas 额度：`remaining_gas_credits` 保持全局一个数，三条链都以 ETH 计价，直接累加。
- 钱包记录：**一链一行**，唯一键 `(evm_chain_address, chain_id)`。owner、threshold、`queue_position`、nonce 都挂在该行上，天然按链隔离。
- owner 变更：一次对该 Safe 当前所有链发起，每条链一笔交易，用分组 id 关联，各链独立签名（SafeOp 哈希含 chainId，签名不可复用）、独立执行与确认，失败单链重试不回滚。
  - 未部署的链：initCode（原 owner）与改 owner 调用放进同一个 userOp。
  - 主网不代付：发起前检查 Safe ETH 余额。
- 可见性按链：某条链确认后，新 owner 在该链上即可见；其他链未执行前在那些链上仍不可见，与链上状态一致。
