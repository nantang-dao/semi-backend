# 登录与认证

## 当前规则

- 只有两种登录方式：手机短信验证码（`send_sms` → `signin`）和邮箱验证码（`send_email` → `signin_with_email`）。**没有密码登录**。
- 验证码只经短信 / 邮件送达。`send_sms` 的响应固定是 `{ "result": "ok" }`，测试按整个响应断言，多出任何字段都会失败。
- 验证码不进日志：`send_sms` 不记录验证码，`filter_parameter_logging` 过滤 `code` 参数（`/signin` 的请求参数）。
- 登录成功签发 `AuthToken`（一年有效），客户端以 `Authorization: Bearer <token>` 调用。
- 支付码（keystore 口令）只在前端用，不以任何形式发给后端。

## 变更记录

### 2026-10：验证码回显与密码登录（账户接管）

2026-10 的安全审计（Claude 在审计会话中）发现两处可以直接接管任意账户的漏洞，2026-10-01 修复（semi-backend `dfab4f0`、semi-app `1027261`）。

**1. `send_sms` 把验证码写在响应里**

- 引入：semi-backend `4d16358`（2025-05-19，"add tencent sms api"）。接入短信通道时把响应从 `{ result: "ok" }` 改成了 `{ result: "ok", code: code }`，同时把手机号和验证码写进日志；与 `SMS_ENABLED` 无关，生产同样返回。次日 `e78670f` 的测试断言了响应里有 `code`，把这个行为固定了下来。
- 攻击：对受害者手机号调 `send_sms`，从响应拿到验证码，再调 `signin` 即登录受害者账户，可读取或覆盖加密 keystore（`get_me` / `set_encrypted_keys`）。
- 修复：响应改回 `{ result: "ok" }`；删除记录验证码的日志；`code` 加入参数过滤；测试改为断言整个响应。

**2. 密码登录首次调用即设置密码 / 建号**

- 引入：`e78670f`（2025-05-20）加了 `signin_with_password`；同日 `e81a1e1`（"add signin with valid password for passwordless user"）让没有密码的账户直接用请求里的密码登录并保存它。
- 攻击：只用短信注册、从未设密码的用户，任何人知道手机号即可设密码接管；未注册的手机号可被抢注，机主之后用短信登录进的是攻击者已控制的账户。
- 另一个问题：前端（`pages/verify.client.vue`）把 6 位支付码当登录密码，发送的是不加盐的 `sha256(支付码)`。这个值查表即可还原支付码，而支付码就是 keystore 的口令——后端和能看到请求日志的人都能解开这些用户的私钥。
- 修复：下线密码登录。删除 `signin_with_password` 路由和方法；前端删除 `signinWithPassword` 和 `/verify` 页面（应用内没有入口）；migration `20261001000001` 删除 `users.encrypted_password` 列（不可恢复）。

**生产核查**（2026-10-01，只读）：

- 317 个用户中 55 个设过密码，全部注册于 2025-05-20 至 06-07——正是 `/verify` 密码注册流程在线的时期，那几周新注册的 57 人中 55 人有密码；06-09 之后没有新增。若有人用漏洞 2 接管短信注册的老用户，应能看到 6 月后注册的账户有密码，实际一个都没有。其中 21 人之后又用短信登录过，形态上与「被抢注后机主再登录」相同，但注册时间都在那几周内，判断为正常用户。
- 约 1560 个短信验证码按月分布没有异常高峰；被请求最多的号码都是已注册用户且大多用掉了验证码；另有 12 条请求发往非法格式号码（8 个）。**看不出滥用，但不能排除**：用回显的验证码登录与正常登录在库里无法区分，库里也不记 IP。进一步核查需要看服务器上的 Rails 日志（有 IP，旧日志里还有手机号和验证码）。
- 55 个密码哈希是 `bcrypt(sha256(支付码))`，数据库泄露时可逐个爆破出支付码，所以随下线一起删除，而不是留着。

**部署注意**：`encrypted_password` 删列的 migration 在新容器启动时执行，而 `load_defaults 8.0` 下旧容器的 INSERT 会带上这一列，新旧容器并存期间落到旧容器的新用户注册会 500（已有用户登录不受影响）。按注册量可以接受，见 migration 注释。不要先在生产库手工清空或删列：旧代码仍在线时，清空密码会让这 55 个账户也落入漏洞 2。

### 2026-10：OAuth 回调地址可登记 `javascript:`（XSS）

- 问题：`redirect_uris` 登记时不校验协议，开发者可以自行把应用设为 `active`，同意页用 `window.location.href` 跳到回调地址。任何登录用户都能登记 `javascript:…` 回调，受害者在 semi.im 上点「授权」或「拒绝」即执行攻击者脚本，可读取 `semi_auth_token`（JS 可读的 cookie）。
- 修复（2026-10-01，semi-backend `e228979`、semi-app `3b2470c`）：`OauthApplication` 校验每个回调地址——只允许 `http(s)`，须有域名，不带 `#片段` 和账号信息，1–10 个；授权时也按这个规则再查一次，挡住之前存进去的记录。同意页跳转前再确认协议。开发者后台按行逐个校验并指出哪一行不合规。
- 应用仍由开发者自行上线，而且**新应用默认就是 `active`**：之前默认 `draft`，开发者不知道要手动上线。攻击面在于回调协议，不在于谁能上线。
- 生产核查：现有 16 个应用的回调地址都符合新规则。其中 `CCTI` 用的是公网 IP 上的 `http://`，为兼容保留了 `http`；授权码经 PKCE 保护，截获授权码也换不到 token。

### 2026-10：签名私钥与 Safe 地址可随意自报

- 问题：`set_encrypted_keys` / `set_evm_chain_address` 原样保存前端报上来的 `evm_chain_active_key` 和 `evm_chain_address`，不要求证明持有私钥，也没有唯一约束。交易记录按地址匹配，多签按 `evm_chain_active_key` 识别 owner，所以把别人的地址报成自己的，就能读别人的交易记录、在多签里冒充成员。
- 修复（2026-10-01，semi-backend `95502b2`、semi-app `4228ffe`）：
  - 绑定时必须证明持有私钥：对 `Semi: bind signing key <key> and wallet <safe> to account <id>` 的 personal_sign，连同公钥上传；后端用 OpenSSL 验签、keccak 核对公钥对应的地址（`WalletBinding`）。消息里带账户 id，签名不能挪给别的账户用。
  - Safe 地址必须由这把私钥推出（单 owner、门限 1、saltNonce 0），后端按 semi-core 生成的模板复算 CREATE2 地址。
  - 一个账户只能绑定一次，不能更换（`key_already_bound`）；一把私钥、一个 Safe 地址只能属于一个账户（`key_in_use`，模型校验 + `LOWER(...)` 唯一索引）。
  - 删除 `set_evm_chain_address`（前端从未调用）。
  - 后端新增 `keccak` gem（C 扩展，无系统依赖）。
- 生产数据（2026-10-01）：
  - 用新的推导规则核对 266 对已绑定的私钥 / 地址：264 对吻合；2 对（`3lqfjbgrkrf25`、`3lqfpr7kw5p3v`，2025-05-30 注册）不吻合，地址在三条链上都未部署、余额为 0，也不属于任何其他账户，判断是当时的推导参数不同，保持原样。
  - 有 2 组账户共用同一把私钥（同一个人把私钥导入了多个账户，账户各自发过交易、keystore 各不相同）。经确认后在一个事务里处理，操作前备份了受影响的行：
    - `TT2732`（邮箱登录）并入 `TT0527`（手机号登录）：邮箱移到 `TT0527`，删除 `TT2732` 及其 2 个登录 token（它没有其他数据）。
    - `zouzou`、`zcjtest`、`zou007` 共用一把：保留 `zouzou`，`zcjtest` 的 10 条交易记录转给 `zouzou`；`zcjtest`、`zou007` 清空私钥 / 地址 / keystore，账户保留，下次登录重新设置支付码（新私钥、新地址）。三个账户是三个手机号，一个用户只能存一个手机号，所以无法合并登录方式。
- **部署前**：唯一索引的 migration（`20261001000003`）在新容器启动时执行，旧代码上线期间仍可能写进新的重复，有重复则新容器起不来。部署前先跑（结果应为空）：

  ```sql
  SELECT lower(evm_chain_active_key), count(*) FROM users WHERE evm_chain_active_key IS NOT NULL GROUP BY 1 HAVING count(*) > 1;
  SELECT lower(evm_chain_address), count(*) FROM users WHERE evm_chain_address IS NOT NULL GROUP BY 1 HAVING count(*) > 1;
  ```

## 未修的问题

审计发现、还没修的认证相关问题（验证码限流、地址自报、令牌明文、6 位支付码等）统一记在 `security-audit-2026-10.md`，修了再挪到上面的变更记录。
