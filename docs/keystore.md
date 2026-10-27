# Keystore 与 key_share

状态：2026-10-01 实现并部署（backend `287e0e5`、`a0fd13c`，app `f39c2b3`、`3b2045d`）。对应 `security-audit-2026-10.md` 的「6 位支付码撑不住 keystore」，也是外部报告第 3 条。背景分析见工作区根目录的 `passcode-and-keystore.md`（2026-08-31）。

代码：后端 `app/services/keystore_vault.rb`、`home_controller.rb`（`get_keystore` / `unlock_keystore` / `update_keystore` / `set_encrypted_keys`）；前端 `semi-core/src/keys/keystore.ts`（v2 加解密）、`utils/keystore_session.ts`（解锁、缓存、v1 升级，页面都只调它的 `unlockPrivateKey`）、`utils/keystore_message.ts`（升级签名的消息）。

## 问题

- keystore（加密后的助记词或私钥）存在 `users.encrypted_keys`，加密口令只有 6 位数字支付码：PBKDF2-SHA256 10 万次 + AES-256-GCM。
- 10⁶ 种组合。8 核 CPU 约 25 分钟穷举（M1 Max 实测：原生 PBKDF2 单次 11.8 ms），GPU 更快。
- 拿到 keystore 很容易：拖库或备份；任何登录态（`/get_me` 随用户信息返回 `encrypted_keys`，前端 9 处直接从这里取）。
- 一个账户的 keystore 只能写一次，没有改支付码、换加密方式的路径。

换更慢的 KDF 不解决问题：scrypt N=2¹³ 在攻击者的原生实现上只比 PBKDF2 10 万次慢约 1.2 倍（实测 14.0 ms 对 11.8 ms），只在 GPU 上有优势。口令熵只有约 20 bit，必须给攻击者一样他没有的东西。

## 方案

每个用户在服务端有一份随机的 `key_share`（32 字节）。keystore 的加密密钥由支付码派生的一半和 `key_share` 合成，缺一不可；服务端核对支付码之后才下发 `key_share`，并限制失败次数。离线爆破变成在线猜测。

### 推导

```
pin_key   = PBKDF2-SHA256(支付码, salt, 100_000)          // 同 v1
verifier  = HKDF-SHA256(pin_key, info="semi-keystore-v2/verify")   → 发给服务端
enc_part  = HKDF-SHA256(pin_key, info="semi-keystore-v2/encrypt")  → 只在客户端
aes_key   = HKDF-SHA256(enc_part ‖ key_share, salt, info="semi-keystore-v2/aes")
keystore  = AES-256-GCM(aes_key, iv, 助记词或私钥)
```

- `verifier` 和 `enc_part` 用不同 info 派生，服务端拿到 `verifier` 推不出 `enc_part`。
- `key_share` 是随机数（客户端生成，见下），和支付码没有数学关系。
- 私钥不变，钱包地址不变。
- 派生步骤有固定向量（`semi-core/test/keystore-v2.test.ts`，由 `node:crypto` 独立算出）。**改 info 字符串或参数会让已有 v2 keystore 全部解不开。**

### 服务端存什么（`users` 表，migration `20261002000001`）

| 字段 | 内容 |
|---|---|
| `encrypted_keys` | v2 keystore（jsonb 字符串，和 v1 一样） |
| `keystore_verifier_mac` | `k1:` + `HMAC-SHA256(mac_key, "#{user_id}:#{verifier}")`；有值即为 v2 |
| `key_share_ciphertext` | `k1:` + `AES-256-GCM(share_key, key_share)`，附加数据 `user:#{user_id}`，挪到别的用户行解不开 |
| `keystore_failed_attempts`、`keystore_locked_until` | 失败计数和锁定期限 |
| `keystore_updated_at` | 最近一次写 v2 keystore 的时间，防止重放旧的升级签名 |

`mac_key`、`share_key` 由环境变量 `KEYSTORE_SERVER_SECRET`（32 字节 hex，`openssl rand -hex 32`）HKDF 派生，**不进数据库、不进备份**。只拖到数据库：既不能离线验证支付码，也解不出 `key_share`。

**`KEYSTORE_SERVER_SECRET` 丢失 = 所有 v2 用户解不开 keystore**，只能用助记词重新导入（导入的是裸私钥的用户如果没有备份，资产就没了）。必须在 `.env.production` 之外另存一份（密码管理器等）。生产缺这个变量时应用拒绝启动（`config/initializers/keystore_vault.rb`），ginger 部署也会因 `secrets.inject` 缺值而失败。

`k1:` 是密钥版本。要换 `KEYSTORE_SERVER_SECRET`：`key_share_ciphertext` 可以在服务端整列重新加密；`keystore_verifier_mac` 只能在用户下次解锁、提交 verifier 时重算，需要新旧两把并存一段时间。目前没实现轮换。

### keystore v2 格式

```json
{ "version": 2,
  "crypto": { "ciphertext": "…", "iv": "…", "salt": "…",
              "kdf": "pbkdf2", "iterations": 100000, "hash": "SHA-256",
              "cipher": "aes-gcm", "keyShare": true } }
```

`decryptKeystore` 遇到 v2 会报错，v2 只能用 `decryptKeystoreV2*` 解。

## 接口

都需要登录。

- `GET /get_keystore`：
  - v1 → `{version: 1, encrypted_keys}`（前端本地解开后升级）
  - v2 → `{version: 2, params: {salt, iterations, hash}, locked_until}`（只有算 verifier 要的公开参数）
  - 没有 → `{version: null}`
- `POST /unlock_keystore {verifier}` → `{encrypted_keys, key_share}`。常数时间比较。错误：`bad_passcode`（附 `attempts_left`）、`keystore_locked`（附 `locked_until`）。
- `POST /update_keystore {encrypted_keys, verifier, key_share, issued_at, public_key, signature}`：写入新的 v2 keystore（v1 升级，以后改支付码也用它）。要求：
  - `signature` 是已绑定的 `evm_chain_active_key` 对 `Semi: update keystore of account <id> at <issued_at> sha256:<sha256(encrypted_keys \n verifier \n key_share)>` 的 personal_sign，证明还是同一把私钥（服务端解不开 keystore，没法自己核对）。有 viem 签的向量（`test/services/keystore_vault_test.rb`）。
  - `issued_at` 在 ±10 分钟内，且晚于 `keystore_updated_at`：旧签名不能重放回旧 keystore。
  - 失败计数、锁定清零。
- `POST /set_encrypted_keys`（首次绑定）：新前端带 `verifier`、`key_share` 直接建 v2；不带的仍按 v1 存（部署前加载的旧页面）。
- `GET /get_me`：新增 `keystore_version`。`encrypted_keys` **只对 v1 返回**，为了部署时已打开的旧页面还能签名（v1 keystore 用 `get_keystore` 照样拿得到，不多暴露什么）；v2 从不返回。全部升级完可以删掉。
- `GET /get_encrypted_keys`：旧接口，v2 返回 `keystore_v2` 错误。

和最初的设计稿相比，去掉了 `prepare` 步骤：`key_share` 由客户端随机生成、随 `update_keystore` 一起上传。持有私钥的人本来就能任意设置自己的 keystore，让客户端选 `key_share` 不增加风险，还免掉了服务端暂存和并发问题。

### 失败次数

- 连续错 50 次锁 24 小时，期满自动解锁并重新计数；锁定期间正确的支付码也不放行。一天最多猜 50 次，一年约 1.8% 机会猜中 6 位数字（最初定的 10 次、约 0.4%，2026-10-01 放宽给记不清支付码的用户留余地）。
- 行锁（`with_lock`）防止并发请求绕过计数；计数在事务提交后才抛错，不会被回滚。
- 不提供「短信验证后立即解锁」：那等于短信 + 再猜 50 次，而且现在没有改支付码的界面。忘了支付码的情况和以前一样，要用助记词重新导入。

## 客户端（`utils/keystore_session.ts`）

- **打开或刷新页面后第一次输支付码**：`get_keystore` → 算 verifier → `unlock_keystore` → 拿到 keystore 和 key_share，放进**模块变量**（不进 Pinia、localStorage、sessionStorage、IndexedDB）。这是唯一的额外请求。
- **之后每次签名**：本地 PBKDF2 + HKDF + AES-GCM 解开，不联网。
- **本地连续输错 3 次**清缓存，下次回到服务端核对、计入失败次数；否则缓存期间的猜测不受服务端限制。
- **闲置 15 分钟**、**退出登录**（`stores/user.ts` 的 `signout`）、**换了账户**时清缓存。`key_share` 是 `Uint8Array`，清空时 `fill(0)`；keystore 只是丢掉引用。JS 字符串没法覆写，私钥（viem 的 hex 字符串）只能靠尽快丢掉引用，和以前一样。
- 缓存的是 `keystore + key_share`，不缓存私钥，不缓存支付码。
- 报错：支付码错仍是 `KeystoreError`（`KEYSTORE_BAD_PASSCODE`，消息里保留 "decrypt"，多签页面靠这个词判断）；锁定是 `KeystoreLockedError`，消息里有解锁时间。各页面原有的提示不用改。

## 迁移（v1 → v2）

- v1 用户下次输支付码时（任何要私钥的页面）：照旧本地解开 → 用同一个支付码、新 salt、新 key_share 重新加密成 v2 → 本地再解一遍确认 → 用私钥签名 → `update_keystore`。用户无感，这次签名不受影响。
- 升级失败（网络、手机时间偏差超过 10 分钟等）只记 warning，这次签名照常；同一页面会话不再重试，刷新后再试。
- keystore 里的私钥与账户绑定的 `evm_chain_active_key` 对不上时不升级（服务端也会拒绝）。
- 升级后 v2 覆盖 `encrypted_keys`，v1 不再保存在库里。**旧备份里的 v1 keystore 保护不了**：如果认为 2026-10 之前的备份可能外泄，补救只能是换私钥（多签换成员）。
- 迁移前生产数据（2026-10-01 只读）：267 个 keystore 全是 v1、PBKDF2 10 万次，存成 jsonb 字符串；`wallets.encrypted_keys` 没有数据。
- 没有强制迁移：不常用的用户会一直是 v1，暴露面和以前一样。以后可以规定剩余 v1 必须升级才能签名。

## 部署

1. `openssl rand -hex 32` 生成 `KEYSTORE_SERVER_SECRET`，写进 semi-backend `.env.production`，**并另存一份**。`ginger.yml` 已加进 `secrets.inject`。
2. 先部署后端（migration 只加列，旧前端照常工作：v1 照旧从 `get_me` 取）。
3. 再部署前端。之后用户第一次输支付码时自动升级。
4. 部署时已打开的旧页面：用的是打开时从 `get_me` 拿到的 v1 keystore，私钥没变，照常能签名；只有之后重新拉取 `get_me`（而这个用户已在新页面里升级成 v2），旧页面才拿不到 keystore 而报错，刷新即可。

### 上线前验证（2026-10-01）

用真实的 `utils/keystore_session.ts` + `utils/semi_api.ts` + semi-core，对本地 Rails 跑了端到端测试（临时测试，未提交）。用户通过部署前旧前端的 `set_encrypted_keys` v1 写法创建，存储形态与生产一致（jsonb 字符串）。全部通过：

- 旧页面从 `get_me` 拿到 v1、本地能解；v1 输错照旧报错、不升级。
- 助记词用户输对：私钥不变、升级成 v2，解出来仍是原助记词；`get_me` 不再返回 keystore。导入裸私钥的用户升级后仍是同一私钥串。
- 缓存期间签名不联网；本地连错 3 次后回到服务端并计数（剩余 49 次）；刷新或退出后走服务端，输对计数清零。
- 升级前旧页面手里的 v1 副本升级后仍能解出同一私钥。
- 升级失败（手机时间快 1 小时）：这次签名照常、仍是 v1，本次会话不重试，刷新后升级成功。
- keystore 私钥与绑定的不一致：照常解、不升级。
- 新绑定（paymentcode 页的写法）直接是 v2。
- 第 50 次输错锁定，锁定期间正确支付码也被拒。

另外：migration 本地 `db:migrate:redo` 通过；生产部署前在 `20261001000005`、无新列、317 行。

### 上线记录

- 2026-10-01 部署前 `pg_dump` 全库备份（只读），存在 `~/backups/semi/`（不进仓库）。备份里的 v1 keystore 仍只受支付码保护，**备份要按私钥同级对待**。
- `KEYSTORE_SERVER_SECRET` 2026-10-01 生成，只在 `.env.production` 和生产容器环境里；**需另存到密码管理器**，并且不要和数据库备份放在一起（放在一起等于 v2 白做）。

## 防护范围

| 攻击场景 | v1 | v2 |
|---|---|---|
| 拖库或拿到备份 | 25 分钟内爆破出私钥（8 核） | 爆破不了：缺服务端密钥和 `key_share` |
| 偷到登录 token | 下载 keystore，离线爆破 | 只能在线猜，50 次锁 24 小时 |
| 设备磁盘、浏览器存储 | 不落盘 | 不落盘 |
| 页面里的恶意脚本（XSS） | 读到 keystore，离线爆破 | 缓存期间能读到 `key_share`，可离线爆破；但它本来就能偷看支付码输入。要靠 CSP 和 HttpOnly 去防 |
| 服务器整体被攻破（应用 + 数据库 + 环境变量） | 分钟级 | **仍是分钟级**：服务端能拿到 `verifier` 和 `key_share`。只有服务器没有的熵能防（WebAuthn PRF、高熵口令、大额多签用外部签名人），另行立项 |

## 性能

M1 Max 实测（2026-10-01，Node 24；PBKDF2 用 WebCrypto / `node:crypto`，scrypt、argon2id 用 `@noble/hashes` 1.8.0 和 `node:crypto`，各跑 3–200 次取平均）：

| 步骤 | 耗时 |
|---|---|
| PBKDF2 10 万次（WebCrypto，浏览器原生） | 12 ms |
| 新增的 HKDF ×3 + AES-GCM | 0.1 ms |
| 每个页面会话第一次解锁 | 多一次 `get_keystore` + `unlock_keystore` |
| v1 升级（一次性） | 多一次 PBKDF2、一次签名、一次 `update_keystore` |
| 服务端每次解锁 | 一次 HMAC 和一次 AES 解密，可忽略 |

## KDF

保持 PBKDF2 10 万次：安全提升几乎全部来自 `key_share`；PBKDF2 在浏览器里是原生实现，异步、不卡界面。scrypt 只在服务器整体被攻破时对 GPU 有用，那时也只是把穷举从几十秒拖到几分钟：

| | PBKDF2 10 万次 | scrypt N=2¹³ | scrypt N=2¹⁵ |
|---|---|---|---|
| 浏览器（noble 纯 JS / WebCrypto） | 12 ms | 25 ms | 93 ms |
| 攻击者单核（Node 原生） | 11.8 ms | 14.0 ms | — |
| 内存 | ≈ 0 | 8 MiB | 32 MiB |

以后要换，keystore 里有 `kdf` / `iterations` 字段，可以加 v3。argon2id 在 noble 里是纯 JS，19 MiB / 2 轮要 423 ms，不合适。GPU 数字没有实测。

## 没做的

- 改支付码的界面（`update_keystore` 已经支持）。
- 剩余 v1 用户的强制迁移。
- `KEYSTORE_SERVER_SECRET` 轮换。
- 服务器整体被攻破（T3）：外部签名人 / WebAuthn PRF，另行立项。
