# 多签钱包：owner 可见性与多链

## 新 owner 如何看到钱包

`get_wallets`（`app/controllers/multisig_controller.rb`）按地址匹配：
`LOWER(wallet_owners.owner_address) = current_user.evm_chain_active_key`，不依赖 `user_id`。
因此新 owner 无论在被加入之前还是之后注册，登录后都能看到钱包——前提是 `wallet_owners` 已更新。

`wallet_owners` 的更新路径：

1. 前端执行 owner 变更交易后调用 `confirm_multisig_tx`；
2. 后端 `verify_userop_receipt!` 在链上校验回执；
3. `apply_wallet_config_from_executed_tx!` 按 `call_detail` 增删 owner、改 threshold。

另有 `sync_multisig_wallet` 按链上状态全量覆盖：后端自己读（已部署读 `getOwners`/`getThreshold`，未部署用 `initial_owners`/`initial_threshold`），读不到就报 `chain_unavailable`，不降级。前端传了 owners / threshold 时必须和后端读到的一致（否则 `chain_mismatch`，不写入），防止配置变更刚执行完、后端节点还落后一个块时拿旧状态覆盖镜像。执行配置变更后由 `utils/multisig_execute.ts` 自动触发（带 owners），owners 页的「从链上同步」手动触发（不带）。

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

## 待签内容必须等于展示内容

页面展示给签名人的是 `call_detail`，链上执行的是快照里的 `callData`。快照由第一个签名人上传，后面的人签的都是它；两者之间不核对，提案人或第一个签名人就能让其他 owner 看着「转 0.01」签下「转走全部」，或者看着「拒绝」签下任意操作。所以三处都核对，规则相同：

- **提案时**（后端 `MultisigIntent.validate_proposal!`）：`evm_call_data` 必须就是 `call_detail` 编码出来的调用——owner 变更逐个参数比对（不只是选择器），ERC20 比对收款人（带了 `decimals` 再比金额），ETH 转账和拒签不能带 calldata。
- **收快照时**（第一个签名人、拒签提案；`MultisigIntent.validate_snapshot!`）：`sender`、`chainId`、`nonce`、`callData` 都要对得上。拒签快照必须是对 Safe 自身的空调用、沿用目标交易的 nonce。
- **签名前**（前端 `utils/multisig_calls.ts` + semi-core `assertSnapshotMatchesCall`）：从 `call_detail` 重新编码（ERC20 的 `decimals` 读合约），和快照逐字节比对；不一致拒签。这一道不依赖后端，后端被攻破也挡得住。

每笔多签交易只执行**一个** CALL。旧版 transfer 页会附加一个 remark 上链调用（`call_detail.remark_to` / `remark_data`），签名人看不到它，现在提案和签名都拒绝。生产上从没有配置过 remark 代理，没有交易用过它。

gas / paymaster 字段不在核对范围内。ERC20 的 `symbol` 是提案人填的，详情页同时显示代币合约地址，以地址为准。

签名本身也在后端核对（`submit_multisig_signature`，`SafeOp`）：后端从快照算出 SafeOp EIP-712 哈希（domain 为 chainId + Safe4337Module），用签名恢复出地址，必须等于 `signer_address`，否则 `invalid_signature`；快照自带的 `safeOpHash` 必须等于重算值（`intent_mismatch`）。只接受 v = 27/28 的普通 ECDSA 签名。前端碰到 `invalid_signature` 且签的是自己建的快照时，取回已存的快照核对后重签一次。

## 执行与失败

执行逻辑只有一份：`semi-app/utils/multisig_execute.ts`，详情页和队列页都调用它（以前两页各写一套，队列页漏了余额检查）。

- 锁定前先查余额：自付 gas 的链按 gas 上限 × `maxFeePerGas` 预付，转账再加上转出金额；不够就直接提示，不锁定。
- `execute_multisig_tx` 把交易锁成 `executing`，同时记 `executor_id` 和 `updated_at`。
- `confirm_multisig_tx`：后端从快照算 EntryPoint v0.7 的 userOpHash（`SafeOp.user_op_hash`，字段与 `execute.ts` 提交的一致），回执里必须有这个哈希的、`success` 为真的 `UserOperationEvent`。前端传的 `user_op_hash` 不再使用。
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

### 2026-10：签名前核对快照内容（修复盲签）

**原设计**：第一个签名人按 `call_detail` 建快照（`user_op_snapshot`），和签名一起上传；后端原样保存。后面的签名人取回快照直接签，只做哈希自洽检查（`safeOpHash`），`expectedHash` 从未传入。拒签提案的快照由提案人上传，后端只核对 nonce。配置类交易（owner / 门限变更）后端只核对 calldata 的函数选择器。多签转账可以在 `call_detail.remark_to` / `remark_data` 里附带一个 remark 上链调用，签名时原样拼到调用列表里。

**问题**：页面展示的是 `call_detail`，签下去的是快照里的 `callData`，两者之间没有任何核对。哈希自洽证明不了快照签的是展示的那笔交易——上传快照的人可以同时算好哈希。

1. 任一 owner 作为第一个签名人，在「转 0.01 给 Bob」的提案上传「转走全部余额」或 `enableModule(攻击者)` 的快照；其他 owner 照着页面签名，凑够门限即可执行。拒签提案同理：展示「拒绝」，快照可以是任意操作。后端被攻破时同样能改快照。
2. 配置类交易只查选择器：展示「添加 owner Bob」，calldata 可以是 `addOwnerWithThreshold(攻击者, 1)`。
3. `remark_to` / `remark_data` 在页面上完全不显示，却会作为第二个调用执行，可以是任意合约的任意调用。

由 2026-10 的安全审计发现（Claude 在审计会话中）。

**影响**：用当前规则核对了生产上全部 53 笔多签交易（只读）：

- 没有任何一笔带 `remark_to`——生产从未配置 remark 代理地址（`VITE_OP_REMARK_PROXY` 未设），这个功能单签多签都没生效过。
- 42 笔快照与展示内容一致，3 笔没有快照。
- 8 笔 ERC20 转账（2026-06-08 至 06-10，NT 代币，OP）快照不一致，但**不是篡改**：收款人和金额都与展示一致，调用目标却是 Safe 自身而不是代币合约。这是 semi-app `b48b623`（2026-06-10）修掉的旧 bug，没有资金转出。这 8 笔都已不在签名中，新规则不影响它们。

**修正**（2026-10-01，semi-app `e257a43`、semi-backend `2549a8e`）：

- 前端签名前（`semi-app/utils/multisig_calls.ts` + semi-core `assertSnapshotMatchesCall`）：从 `call_detail` 重新编码唯一的那个调用（ERC20 的 `decimals` 读合约），和快照的 `sender`、`chainId`、`nonce`、`callData` 逐项比对，不一致拒签。自己建的快照同样核对。这一道不依赖后端。
- 后端（`MultisigIntent`）：提案时 `evm_call_data` 必须就是 `call_detail` 的编码（owner 变更逐参数比对）；收快照时（第一个签名人、拒签提案）核对 `sender`、`chainId`、`nonce`、`callData`。还没刷新到新版前端的签名人也因此受保护。
- 多签只执行一个 CALL，去掉 remark 附加调用；前后端都拒绝带 `remark_to` / `remark_data` 的提案。单签的 remark 不受影响（自己签自己的交易，没有别人塞调用的问题）。
- 详情页显示 ERC20 的代币合约地址：`symbol` 是提案人填的，以地址为准。
- 前后端的编码是两份实现，用 semi-core 生成的同一组向量锁住（`semi-core/test/snapshot-intent.test.ts`、`semi-backend/test/services/multisig_intent_test.rb`）。

**有意不做**：gas / paymaster 字段（`maxFeePerGas`、各 gas 上限、`paymasterAndData`）不核对。它们决定谁付费、付多少，不改变 Safe 执行什么。理论上，自付 gas 的链上，第一个签名人可以抬高 `maxFeePerGas`，再自己打包并把受益人设成自己，从 Safe 里多收手续费。评估后决定不防（2026-10-01）。以后如果要恢复多签 remark，只放行本链配置的代理地址 + `saveRemark`，页面显示解码后的备注，后端也要知道代理地址。

### 2026-10：`sync_multisig_wallet` 采信前端数据

**问题**：`ChainRpc.eth_call` 在已带 `0x` 的选择器前又拼了一次 `0x`，发出去的是 `0x0xa0e67e2b`，调用一直失败、返回空；空结果被当成「读不到」，降级为信任前端传来的 owners / threshold。即使 RPC 正常，`sync_wallet` 里的 `rescue => e` 也会把「与链上不一致」的 `AppError` 一并吞掉。结果：任一 owner 都能把后端镜像改成任意成员和门限——把自己的其他地址加进来看交易和成员手机号、把别人踢出列表、把门限调低让交易显示「可执行」（链上资金不受影响，签名不够 bundler 会拒）。降级逻辑是 `249ba92`（2026-06-04）加的，`0x0x` 从 `ChainRpc` 诞生起就在。由 2026-10 的安全审计发现。

**修正**（2026-10-01）：

- `ChainRpc`：去掉重复前缀；节点返回 `error`、没有响应、返回值读不懂都抛 `ChainRpc::Error`，不再返回空值；新增 `deployed?`（`eth_getCode`）。`get_transaction_receipt` 仍在失败时返回 nil，由 `confirm_tx` 重试后失败闭合。
- `sync_wallet` 由后端读链决定写入什么，规则见上面「新 owner 如何看到钱包」。owners 页的手动同步不再在前端读链。
- 测试用一个假的 JSON-RPC 节点，calldata 不对就报错，锁住 `0x0x` 这类问题。

**生产核对**（2026-10-01，只读）：用修好的 `ChainRpc` 核对全部 15 个多签钱包行，镜像与生效配置全部一致（7 行读链上合约，8 行未部署、按初始配置），没有被改写过的迹象。

### 2026-10：`confirm_tx` 可用旧回执确认；后端不验多签签名

**问题**：

1. `confirm_multisig_tx` 的 `user_op_hash` 是可选参数，缺省时回执里只要有本 Safe 的任意一个成功 `UserOperationEvent` 就放行；给了也不核对它是不是这笔交易的哈希。一笔已经签够、但故意不上链的 owner 变更，可以拿同一 Safe 以前任意一笔成功交易的回执确认：后端标成 executed、按 `call_detail` 改成员和门限、把同 nonce 的交易标成 superseded、推进队列，而链上什么也没变。
2. `submit_multisig_signature` 只检查签名非空。签名人地址已绑定到当前用户（见 `auth.md`），不能冒签，但一个 owner 可以交一段乱码占掉自己的名额，让交易显示「可执行」，执行时才被 bundler 以 AA24 拒绝，且签名删不掉，只能重新发起。

由 2026-10 的安全审计发现（Claude 在审计会话中）。

**修正**（2026-10-01）：

- 新增 `SafeOp`（`app/services/safe_op.rb`）：从快照算 SafeOp 哈希和 userOpHash，从签名恢复地址（OpenSSL 椭圆曲线点运算，不引入依赖系统 secp256k1 库的 gem）。算法由 viem 生成的向量锁住（`test/fixtures/files/safe_op_vectors.json`，一份带 factory + paymaster，一份不带）。
- `confirm_tx` 用后端算的 userOpHash，`UserOpReceipt.assert_succeeded!` 的哈希改为必填。哈希覆盖 nonce 和 callData，同一 nonce 链上只能成功一次，所以只有这笔交易自己那次执行的回执能确认它。
- `submit_signature` 验签，规则见上面「待签内容必须等于展示内容」。

**生产核对**（2026-10-01，只读，用新代码跑生产数据）：

- 22 笔已执行的多签交易，链上回执里全部有后端从快照算出的 userOpHash——算法和链上一致，新规则不会误拒正常确认。
- 18 份带 `safeOpHash` 的快照，重算值全部一致。
- 86 个已存签名中 84 个恢复出的地址正确。另 2 个（`3mtohod3xscak` 2026-08-22、`3mw6wrttrvctv` 2026-09-23，都是 OP 上的转账，最终 failed）恢复出的地址不属于任何用户，也不对应库里任何一份快照。两者都是第二个签名人、在第一个人签名后 4～6 秒提交：打开页面时交易还没有快照，前端自己建了一份（gas 价不同）来签，而后端已存了第一个人的快照，于是存下了一个签的是另一份快照的签名，执行时整笔失败。新规则会当场拒收这种签名，前端取回已存快照重签。
