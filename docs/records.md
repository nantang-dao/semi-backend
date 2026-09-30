# 交易记录与代币列表

用户上传给后端、会被别人看到的数据：交易记录（`transactions`）和全局代币列表（`token_classes`）。

## 交易记录

前端在链上执行成功后调用 `add_transaction` / `add_transaction_with_gas_credits` 上传记录（转账页、部署页、多签执行后）。记录会出现在发送方和收款方双方的交易历史里（`get_transactions` 按 `sender_address` / `receiver_address` 匹配），备注也一起显示。

**规则**（`app/services/transaction_proof.rb`）：

- 按 `tx_hash` 读链上回执（`chain` 是 viem 链名小写或 chain id），回执里必须有 `sender_address` 这个 Safe 的 `UserOperationEvent`。
- `sender_address` 必须是上传者自己的 Safe，或上传者当前是成员的多签 Safe。
- `receiver_address`（有的话）必须出现在这笔交易的调用数据或日志里。转账目标、ERC20 收款人、部署时的工厂合约都在 `handleOps` 的调用数据里。
- `gas_used` 和 `status` 取自该事件（`actualGasCost`、`success`），前端传的值忽略。`add_transaction_with_gas_credits` 用它累加 `total_used_gas_credits`；多签的 `confirm_multisig_tx` 同样取自回执。
- 节点可能还没同步到刚上链的交易：请求内短暂重试，仍读不到返回 `chain_unavailable`。前端 `recordTransaction` 会再重试，失败只提示「记录同步失败」，不提示转账失败。
- 挡不住的：真实发一笔小额转账给某人，再附上钓鱼备注。这和链上 memo 是同一类问题，但发送方是真实可查的。

**历史**：曾经原样保存前端传来的一切 —— 任何人都能以任意发送方、给任意收款方写一条从没发生过的记录（出现在对方的收款记录里，附带备注）；`gas_used` 可以是负数，直接累加进 gas 额度。2026-10 审计发现，2026-10-01 修复（backend `aa8fa31`，app `f9f8709`）。历史记录不重新校验。

用新规则核对了生产最近 150 条记录（2026-06-24 至 09-30，只读）：全部通过。其中 9 条多签记录前端当时上传的 gas 是 0（多签的 gas 在 `confirm_multisig_tx` 记账），现在记录里存真实值、不重复记账；另有 2 条（2026-08-23、08-24 的多签交易）库里记的是成功，链上 UserOp 其实回滚了，是 `UserOpReceipt` 修复之前的旧问题。

**未决**：转账页上传时带了 `receiver_note`，后端从来不保存它（收款人备注只能由收款人自己用 `set_transaction_note` 写）。`home_controller_test` 里有 2 个 2025-12 写的测试期望保存它，一直失败。要不要由发送方写收款人备注是产品问题，没动。

## 代币列表

`get_token_classes` 是所有人共用的代币列表（资产页、转账页、多签队列）。

- `token_classes.listed`：已上架的对所有人可见；没上架的只有添加者（`publisher`）自己看得到。
- `add_token_class` 加的币默认不上架。部署代币页会自动添加，部署者自己马上能看到。
- 管理员（`ADMIN_USER_IDS`）调用 `set_token_class_listed` 上架或下架。目前没有管理界面。
- 迁移 `20261001000005` 把现有代币全部设为已上架（生产 7 个，2025-06 至 07 由团队添加）。

**历史**：曾经任何登录用户加的币都会出现在所有人的列表里，比如一个假的 USDC。2026-10-01 修复（backend `53408c8`）。
