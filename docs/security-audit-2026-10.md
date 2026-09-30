# 安全审计（2026-10）

2026-10-01 对 semi-app 和 semi-backend 做的只读安全审计（Claude 在审计会话中，四个方向并行：后端认证授权、后端 OAuth 与多签、前端 Nitro 服务端、前端密钥处理）。这份文档是**跟踪清单**：修了一项就改它的状态、写上 commit，细节放进对应的设计文档（`auth.md`、`multisig.md`）。

标记说明：**已核实** 表示对照代码亲自确认过；**代理报告** 表示审计代理报告、尚未逐条复核，修之前先确认。行号是审计当时的，可能已经漂移。

## 已修复

| 严重 | 问题 | 修复 | 细节 |
|---|---|---|---|
| 严重 | `send_sms` 把验证码写在响应里（任意手机号可登录） | backend `dfab4f0` | `auth.md` |
| 严重 | `signin_with_password` 给没密码的账户直接设密码、给未注册号码建号（账户接管 / 抢注） | backend `dfab4f0`，app `1027261` | `auth.md` |
| 严重 | 前端把 6 位支付码当登录密码，发送不加盐的 `sha256(支付码)`（可还原支付码 → 解开 keystore）；`encrypted_password` 存的是它的 bcrypt | app `1027261`，backend `dfab4f0`（删列） | `auth.md` |
| 严重 | 多签盲签：后面的签名人不核对快照与展示内容；配置类交易后端只查选择器；`remark_to` 附加调用页面不可见 | backend `2549a8e`，app `e257a43` | `multisig.md` 2026-10 |
| 严重 | OAuth `redirect_uris` 可登记 `javascript:`，同意页跳转即在 semi.im 执行脚本 | backend `e228979`，app `3b2470c` | `auth.md` |
| 严重 | `evm_chain_active_key` / `evm_chain_address` 可随意自报、无唯一约束（读别人交易记录、多签冒充成员） | backend `95502b2`，app `4228ffe`；生产重复数据已清理 | `auth.md` |
| 高 | 验证码没有尝试次数和频率限制（邮箱码可在线爆破、短信可被刷） | backend `4b03966`，app `b5e4231` | `auth.md` |
| 高 | `sync_wallet` 链上校验失效（`0x0x` 选择器 + `rescue` 吞掉不一致），降级信任前端的 owners / 门限 | backend `57ad4d7`，app `559e143`；生产 15 个钱包行核对一致 | `multisig.md` |
| 高 | `confirm_tx` 可用同一 Safe 的旧回执确认 | backend `f17f2c3`；生产 22 笔已执行交易核对一致 | `multisig.md` |
| 中 | 后端不验证多签签名（顺带查出 2 笔因签名竞态失败的交易） | backend `f17f2c3`，app `8a1927f` | `multisig.md` |
| 高 | 私钥和支付码打到浏览器控制台；生产构建去掉 `console.log` / `console.debug` | app `64c96cb` | — |

以上均已核实，生产数据做过只读核查（见各设计文档）。截至 2026-10-01 **尚未部署**。

## 决定不修

- **多签快照的 gas / paymaster 字段不核对**（2026-10-01 决定）。自付 gas 的链上，第一个签名人理论上可以抬高 `maxFeePerGas` 再自己打包，从 Safe 多收手续费。理由见 `multisig.md`。

## 未修

### 严重

- **6 位支付码撑不住 keystore**（代理报告，`semi-core/src/keys/keystore.ts`）。PBKDF2-SHA256 10 万次，10⁶ 种组合，数据库或备份泄露后单个用户约 10 秒可穷举。salt 和 IV 存在服务器上是正常的，问题在口令熵。修法：引入服务器没有的熵（WebAuthn PRF / 设备密钥），或强制高熵口令 + Argon2id；至少不能只靠 6 位数字。

### 高

- **Badge 接口可匿名耗光管理员钱包的 gas**（已核实，`semi-app/server/utils/badge_auth.ts`）。`verifyBadgeAuth` 只查签名与请求里自报的地址一致，不查是不是 Semi 用户。随手生成私钥即可反复让管理员钱包发 `createProfile` / `registerClass` / `mint`，也能给任意地址发冒充官方的徽章。签名 5 分钟内可重放（无 nonce）。修法：要求 Semi 登录态并校验签名地址是该用户的 `evm_chain_active_key`；按用户和 IP 限流、限额；管理员钱包少放钱并告警。
- **Paymaster 押金可能被外人消耗**（待确认 ZeroDev 后台配置）。`VITE_ZERODEV_PROJECT_ID` 在客户端 bundle 里（已核实），paymaster 是 `selfFunded`。若 ZeroDev 后台没配 sponsor 策略（sender / 合约白名单、限额），任何人都能拿它为自己的 UserOp 付 gas。`gas_credits` 只是事后记账，不拦截。修法：先去控制台确认策略；更彻底是把 sponsor 放到服务端鉴权之后。

### 中

- **公开接口泄露 PII / 越权读取**（代理报告）：`get_user` 不需登录即返回 email、phone、gas 额度；`get_by_handle` 可按手机号反查；`get_contacts` 不需登录即读任意用户通讯录；`get_multisig_wallet_owners` 缺 `ensure_is_owner!`，返回成员手机号；`lookup_tx_memos` 不限归属。
- **`GET /oauth/admin/applications` 无鉴权**（代理报告）：后端与 Nitro 代理都不检查，列出全部应用的 client_id、回调地址、owner。修法：管理员鉴权。
- **登录 token 与安全头**（代理报告）：`semi_auth_token` 由 JS 写入 cookie，365 天，无 HttpOnly / Secure / SameSite；站点无 CSP、`frame-ancestors`、HSTS（Traefik 是否补了待确认），OAuth 同意页可被嵌进 iframe 点击劫持。修法：安全头；后端下发 `HttpOnly; Secure; SameSite=Lax` 的 cookie。
- **令牌明文存库**（代理报告）：`AuthToken`、OAuth 访问令牌 / 刷新令牌 / 授权码都是明文；OAuth 访问令牌有效期 10 年。修法：只存 SHA-256；访问令牌约 1 小时。
- **用户自报数据被采信**（代理报告，`home_controller.rb`）：`add_transaction` 的 `gas_used` 可为负、sender / receiver / memo 全由客户端填（可给别人塞钓鱼记录）；任何登录用户都能往全局代币列表加币（假 USDC）；`set_encrypted_keys` 覆盖已有 keystore 不需再次验证。
- **多签数据可伪造**（代理报告）：创建钱包不校验 CREATE2 地址与 owners 是否匹配，可抢注别人 Safe 地址的其他链行，使对方无法启用该链；成员 `user_ids` 和 `*_name` 由客户端传入，可显示成可信的人名。
- **OAuth `profile` scope 同时返回手机号和邮箱**（代理报告）。修法：拆出 `phone`、`email` scope。
- **`.env.build` 曾提交进 git**（代理报告，semi-app `af3bc40` 加入、`25d2f36` 删除，remote `nantang-dao/semi-app`）：含 `VITE_SOLA_AUTH_TOKEN`，且该 token 曾打进客户端 bundle。修法：轮换；仓库若公开过，改写历史。

### 低

- OIDC discovery 声明支持，但从不签发 `id_token`、不处理 `nonce`。
- OAuth refresh token 轮换无锁（并发可换出两套令牌）；`userinfo` 不查应用是否被禁用。
- 多签 `queue_position` 的 advisory lock 在 INSERT 前释放；不支持的 chain_id 能通过创建校验。
- `set_transaction_note` 未登录时可改 `user_id` 为空的交易的备注，其余情况 500。
- CORS 生产白名单含 localhost 和旧域名（fly.dev、ntdao.xyz、nanaland.xyz）。
- `lib/send_sms.rb` 有多处 `puts`；`phone` 未加入日志过滤。
- Docker 构建阶段 `COPY .env.production`，管理员私钥等进了构建层缓存（最终镜像不含）；`.dockerignore` 应排除 `.env.*`。
- `ginger.yml` 给应用容器注入了用不到的 `YATCH_TOKEN`（registry 推送令牌）、`ADMIN_KEY`；semi-app 注入了不再使用的 `INSTANT_APP_ADMIN_TOKEN`、`SOLA_BADGE_ADMIN_WALLET_PRIVATE_KEY`。
- InstantDB 权限只给 `profiles` 写了规则（代码已不再使用 InstantDB）。
- `server/api/actions.get.ts` 是不鉴权的 Safe API 代理，参数未编码。
- OAuth 同意页不展示回调域名，应用名可仿冒「Semi 官方」。
- permissionless 在 app 里是 `^0.4.0`，semi-core 固定 `0.4.0`；升级必须跑 fork 测试，建议 app 也固定。

## 检查过、没发现问题

- SQL 注入（均为参数化查询）、`send` / `constantize`、`chain_rpc.rb` 与图片上传的 SSRF。
- 前端没有 `v-html` / `innerHTML` / postMessage 监听器；NFT 元数据只从 arweave / ipfs 取且禁止重定向。
- OAuth：`redirect_uri` 精确匹配；所有客户端强制 PKCE S256；授权码 60 秒、原子核销、绑定 client 与 redirect_uri；client_secret 用 bcrypt；revoke 限定所属 client；refresh 重放作废整族令牌；每次都显示同意页。
- 助记词、salt、IV 用 CSPRNG；解密后的私钥只在函数内使用，不落地。
- SafeOp EIP-712 domain 含 chainId 与 module 地址；多签 execute / confirm 的状态推进是原子的；`withdraw` 只允许提案人撤回无签名的交易。
- `.env`、`.env.production`、`config/master.key` 从未进过 git。
