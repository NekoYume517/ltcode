# ltcode — API 契约

> **这是实现依据，不得更改签名。** 内部实现自由，但这些公开 API 必须存在且签名一致。

模块名：`NekoYume517/ltcode`，库包：`src`，CLI 包：`cmd/ltcode`。

## 1. GF(256) `src/gf256.mbt`

```moonbit
pub let gf256_generator : Int                    // == 3
pub fn gf256_add(a : Int, b : Int) -> Int        // XOR
pub fn gf256_mul(a : Int, b : Int) -> Int
pub fn gf256_inv(a : Int) -> Int?                // 0 没有逆元
pub fn gf256_pow(a : Int, n : Int) -> Int

/// 无表对照实现（俄罗斯农民乘法）。存在意义是可审计性：
/// 任何人可以拿它独立复核 `gf256_mul`。
pub fn gf256_mul_peasant(a : Int, b : Int) -> Int
```

约化多项式 `0x11B`（`x^8 + x^4 + x^3 + x + 1`，AES 用的那个）。
exp/log 表由生成元 3 的连续幂**构造**，不硬编码 256 项。

### 输入域（LT-E，2026-11-10 审计后明确）

**四个运算的全部输入都按低 8 位解释**（`a & 0xFF`），与
`gf256_mul_peasant` 完全一致。这条不是可选的实现细节：

| 调用 | 结果 | 说明 |
|---|---|---|
| `gf256_mul(0x57, 0x83)` | `0xC1` | 域内，FIPS-197 锚点 |
| `gf256_mul(256, 1)` | `0` | `256 & 0xFF = 0` |
| `gf256_mul_peasant(256, 1)` | `0` | 一直如此 |
| `gf256_inv(256)` | `None` | `inv(0)` |
| `gf256_inv(257)` | `Some(1)` | `257 & 0xFF = 1` |
| `gf256_pow(0xFF, 2000000000)` | `27` | 指数先归一，见下 |
| `gf256_pow(3, -1)` | `246` | `= gf256_inv(3)`；负指数是逆元的幂 |
| `gf256_pow(a, 0)` | `1` | 对任何 `a` 成立，含 `0` 与越界值 |

`gf256_pow` 的指数先 `((n % 255) + 255) % 255` 归一到 `[0, 255)`，再算
`((log[a] % 255) * (n % 255)) % 255`。修复前写的是 `exp[la * n % 255]`：
`7 * 2000000000` 在 `Int32` 上溢出成负数，`% 255` 之后落在一个**不对应
任何代数结论**的下标上 —— `0xFF^2000000000` 返回 244 而正确值是 27。
这是**静默错值**，比 trap 危险。

**验证**：全部 65536 对 `gf256_mul(a,b) == gf256_mul_peasant(a,b)`；
**外加越界域上的一致性**（19 个值含负数与 `Int32` 端点的 361 个组合，
`src/gf256_domain_test.mbt`）；`mul(0x57, 0x83) == 0xC1`（FIPS-197 §4.2）；
`mul(a, inv(a)) == 1` 对全部 255 个非零 a；`pow(a, -1) == inv(a)` 对全部
255 个非零 a。参考值另由两套独立算法（逐次相乘 / 对数表）复算。

## 2. PRNG `src/rng.mbt`

```moonbit
pub fn splitmix64(z : UInt64) -> UInt64

pub struct Ltrng {
  priv mut s0 : UInt64
  priv mut s1 : UInt64
}

pub fn Ltrng::new(seed : UInt64) -> Ltrng
pub fn Ltrng::next_u64(self : Ltrng) -> UInt64
pub fn Ltrng::next_double(self : Ltrng) -> Double        // [0, 1)，53 位
pub fn Ltrng::next_below(self : Ltrng, n : Int) -> Int   // [0, n)，拒绝采样

/// 拒绝采样的判定逻辑，单独暴露以便**直接断言**而非统计推断。
pub fn rejection_threshold(n : Int) -> UInt64            // 2^64 mod n
pub fn map_below(v : UInt64, n : Int) -> Int?            // 落在拒绝区 → None
```

`xorshift128+`，状态 2×UInt64，种子经 splitmix64 扩展。
**同一 seed 序列固定**：前 16 个输出有测试锁定（值由独立的 Python 参考实现算出）。

`next_below` 用**拒绝采样**而不是裸取模。偏差量级是 2^-64，统计测试
根本抓不到 —— 因此验证方式是直接断言 `rejection_threshold` 的值
（例如 `n=7` 时必须是 2），而不是"跑很多次看分布"。

## 3. 度数分布 `src/distribution.mbt`

```moonbit
pub fn ideal_rho(d : Int, k : Int) -> Double
pub fn robust_r(k : Int, c : Double, delta : Double) -> Double
pub fn robust_kr_index(k : Int, c : Double, delta : Double) -> Int
pub fn robust_tau(d : Int, k : Int, c : Double, delta : Double) -> Double
pub fn robust_beta(k : Int, c : Double, delta : Double) -> Double

pub(all) struct Distribution {
  k : Int
  pmf : FixedArray[Double]     // 下标 1..k 有效
  cdf : FixedArray[Double]
}

pub fn Distribution::pdf(self : Distribution, d : Int) -> Double
pub fn Distribution::cdf_at(self : Distribution, d : Int) -> Double
pub fn Distribution::expected_degree(self : Distribution) -> Double
pub fn Distribution::sample(self : Distribution, rng : Ltrng) -> Int

pub fn distribute_from_array(k : Int, values : Array[Double]) -> Distribution
pub fn ideal_soliton(k : Int) -> Distribution
pub fn robust_distribution(k : Int, c : Double, delta : Double) -> Distribution
pub fn fixed_distribution(d0 : Int, k : Int) -> Distribution

pub fn validate_distribution(dist : Distribution) -> Result[Unit, LtError]
pub fn robust_soliton_checked(k : Int, c : Double, delta : Double) -> Result[Distribution, LtError]

/// PLAN §4 的便利入口（每次重建表，O(K)；批量请直接用 Distribution）
pub fn sample_degree(rng : Ltrng, k : Int, c : Double, delta : Double) -> Int
```

### 关于 `R` 的一个算术更正

PLAN.md 原文写「K=1000 / c=0.1 / δ=0.5 时 `R ≈ 21.7`」。**那个数字对应 δ=1.0**：

```
R = c · ln(K/δ) · sqrt(K)
δ = 1.0 :  0.1 × ln(1000)   × 31.6228 = 21.844
δ = 0.5 :  0.1 × ln(2000)   × 31.6228 = 24.036
```

PLAN 明确指定了 δ=0.5，所以实现取 **24.036**，并且测试**同时锁定两个值**
（`21.844` 与 `24.036`），避免以后有人"按 PLAN 的 21.7 去改实现"。
PLAN.md §4.2 已按此更正。

### τ 的尖峰位置

`K/R` 那一点**单独定义**：`τ(K/R) = R·ln(R/δ)/K`，值明显高于区间公式
（K=1000 时 0.0931 vs 0.0586）。少写这一条，分布就退化成近似 1/d 的尾巴，
低开销下的成功率会掉一个数量级 —— 有测试断言这两个值必须不同。

## 4. 符号与源块 `src/symbol.mbt`

```moonbit
pub fn max_source_symbols() -> Int        // 1 << 20

pub(all) struct SourceBlock {
  k : Int
  symbol_len : Int
  sources : Array[Bytes]
}

pub fn SourceBlock::new(sources : Array[Bytes]) -> Result[SourceBlock, LtError]
pub fn SourceBlock::from_bytes(data : Bytes, k : Int) -> Result[SourceBlock, LtError]
pub fn reassemble(sources : Array[Bytes], payload_len : Int) -> Bytes

pub(all) struct Symbol { index : Int, data : Bytes } derive(Eq, Debug)
pub(all) struct ReceivedSymbol { index : Int, data : Bytes } derive(Eq, Debug)
```

`from_bytes` 会把数据切成 K 段并在末尾**补零**；`reassemble` 按
`payload_len` 截回。补零发生在这里是有意的（并且 `payload_len` 记录了
真实长度），与"解码时用假数据填缺符号"是两件事。

## 5. 编码 `src/encoder.mbt`

```moonbit
pub(all) struct Encoder {
  seed : UInt64
  block : SourceBlock
  dist : Distribution
}

pub fn Encoder::new(block : SourceBlock, seed : UInt64, c : Double, delta : Double)
  -> Result[Encoder, LtError]
pub fn Encoder::symbol(self : Encoder, index : Int) -> Symbol
pub fn Encoder::symbols(self : Encoder, first_index : Int, count : Int) -> Array[Symbol]

pub fn symbol_rng(seed : UInt64, index : Int) -> Ltrng
pub fn floyd_subset(rng : Ltrng, k : Int, d : Int) -> Array[Int]
pub fn subset_for(seed : UInt64, index : Int, k : Int, dist : Distribution) -> Array[Int]

/// PLAN §5 的入口：每次重建分布，O(K)。批量请用 Encoder。
pub fn encode_symbol(seed : UInt64, index : Int, sources : Array[Bytes]) -> Bytes raise LtError

pub fn default_seed() -> UInt64           // 0x4C54434F4445
pub fn default_c() -> Double              // 0.1
pub fn default_delta() -> Double          // 0.5
```

**子集的唯一决定因素**是 `(seed, index, K, 分布参数)` —— 任意符号可独立重算。

抽样用 **Floyd 算法**，只用 O(d) 内存（不是 O(K)）。均匀性由
`encoder_test.mbt` 对 K=6/d=3 的全部 20 个子集做 200000 次穷举统计锁定。

`symbol_rng` 的混合方式见 `docs/implementation.md` 第 5 节 —— 那里记录了一个
真实缺陷：早期用 `splitmix64(seed ^ index)` 会让相邻种子的试验高度相关。

## 6. 解码 `src/decoder.mbt`

```moonbit
pub(all) enum DecodeResult {
  Complete(Array[Bytes])
  Incomplete(Array[Bytes?], Array[Int])
}

pub fn DecodeResult::is_complete(self : DecodeResult) -> Bool
pub fn DecodeResult::missing_indices(self : DecodeResult) -> Array[Int]
pub fn DecodeResult::missing_count(self : DecodeResult) -> Int

pub(all) struct DecodeStats {
  received : Int
  subset_slots : Int      // Σ degree
  resolved : Int
  xor_bytes : Int
  inconsistent : Int      // 收到的符号互相矛盾时为非 0
} derive(Eq, Debug)

/// PLAN §6 的签名：解不出是 Incomplete（正常返回值），错误才 raise。
pub fn decode(seed : UInt64, k : Int, symbol_len : Int, received : Array[ReceivedSymbol])
  -> DecodeResult raise LtError

pub fn decode_with_stats(seed : UInt64, k : Int, symbol_len : Int,
  received : Array[ReceivedSymbol], c : Double, delta : Double)
  -> (DecodeResult, DecodeStats) raise LtError

pub fn decode_full(seed : UInt64, k : Int, symbol_len : Int,
  received : Array[ReceivedSymbol], c : Double, delta : Double)
  -> DecodeResult raise LtError
```

**诚实性契约（本项目最重要的一条）**：

- `missing` 是**真实计算出来的**未解出下标，升序。
- `recovered[i] is None` **当且仅当** `i ∈ missing`。两个视图必须一致。
- 已解出的 `recovered[i]` **逐字节等于**真实源符号。
- **绝不用零字节或任何填充值补齐缺口。**

有测试跨 200 条种子断言"凡声称解出的，必须真的是对的"。

**复杂度**：每个解出的源符号会被消去进它出现过的每个符号，总 XOR 字节数
≈ `received · avg_degree · symbol_len`。用 `DecodeStats` 的操作计数验证
K=200 → K=400 时比值 ≈ 2（线性），不用墙钟。

## 7. 度量 `src/metrics.mbt`

```moonbit
pub(all) struct TrialOutcome { seed, received, success, missing, stats } derive(Debug)
pub(all) struct CurvePoint { overhead, received, successes, trials, rate } derive(Debug)

pub fn overhead_ratio(k : Int, received : Int) -> Double
pub fn received_count(k : Int, overhead : Double) -> Int
pub fn random_sources(seed : UInt64, k : Int, symbol_len : Int) -> Array[Bytes]

pub fn run_trial(k : Int, overhead : Double, seed : UInt64, symbol_len : Int,
  c : Double, delta : Double) -> TrialOutcome raise LtError

pub fn decode_success_rate(k : Int, overhead : Double, trials : Int, seed : UInt64,
  symbol_len : Int, c : Double, delta : Double) -> CurvePoint raise LtError

pub fn evaluate(k : Int, overheads : Array[Double], trials : Int, seed : UInt64,
  symbol_len : Int, c : Double, delta : Double) -> Array[CurvePoint] raise LtError

/// PLAN §7 最后一条：度数分布对成功率的影响
pub fn distribution_comparison(k : Int, overhead : Double, trials : Int, seed : UInt64,
  symbol_len : Int) -> Array[(String, CurvePoint)] raise LtError
pub fn ideal_success_rate(...) -> CurvePoint raise LtError
pub fn fixed_degree_success_rate(k, d0, overhead, trials, seed, symbol_len)
  -> CurvePoint raise LtError
pub fn run_with_distribution(dist, k, overhead, trials, seed, symbol_len)
  -> CurvePoint raise LtError

pub fn round3(x : Double) -> Double
pub fn format_curve_point(p : CurvePoint) -> String
pub fn format_fixed(x : Double, digits : Int) -> String
pub fn format_trial(o : TrialOutcome) -> String
```

`run_trial` 在判定成功时**逐字节比对**，不只是看 `DecodeResult` 的标签。

## 8. 容器格式 `src/container.mbt`

```moonbit
pub let container_magic : FixedArray[Byte]     // "LTC2"
pub let container_version : Int                // 2
pub fn header_len() -> Int                     // 43

pub fn quantize_param(x : Double) -> Int        // round(x*100) 钳到 [0,255]
pub fn dequantize_param(q : Int) -> Double

/// FNV-1a 64。抓意外损坏，不抗主动构造 —— 能力边界见 docs/implementation.md §5b。
pub fn payload_hash(data : Bytes) -> UInt64

/// 注意第二个数据参数是**原始 payload 字节**（不是 length）：
/// 长度与哈希都由它自己算，避免"长度与哈希可以对不上"。
pub fn pack_container(block : SourceBlock, seed : UInt64, payload : Bytes,
  c : Double, delta : Double, symbols : Array[Symbol]) -> Bytes

pub(all) struct Container {
  k, seed, symbol_len, payload_len, payload_hash, c, delta, symbols
} derive(Debug)

pub fn unpack_container(data : Bytes) -> Container raise LtError
```

### 头部的域校验（LT-A / LT-D / LT-G / LT3，2026-11-10 / 2026-11-13 审计）

头里的每个字段都是**外部输入**，而 `K` / `symbol_len` / `count` 在文件里
是无符号 u32、`payload_len` 是 u64，内部一律有符号 `Int32`。直接读取会
变负或截断，而那些坏值不会当场崩 —— 它们让后续逻辑给出**误导性的业务
状态**（最典型：`count = 0xFFFFFFFF` 变 −1 使符号全部被丢弃，解码于是
报 `INCOMPLETE: missing K of K`，调用方会去补发符号）。

因此 `unpack_container` 是这些校验的**唯一入口**，它按文件自身剩余字节
判断（不需要任何外部信息）：

| 字段 | 合法域 | 越界报 |
|---|---|---|
| `K` | `1 ..= 1<<20`（`max_source_symbols()`） | `InvalidHeaderField("K", …)` |
| `symbol_len` | `1 ..= Int32.MAX`（**只看字段自身**） | `InvalidHeaderField("symbol_len", …)` |
| `payload_len` | `0 ..= min(K × symbol_len, 2^31−1)` | `InvalidHeaderField("payload_len", …)` |
| `count` | `0 ..= Int32 上限`，且 `<= 剩余字节 / (4 + symbol_len)` | 超 `Int32` → `InvalidHeaderField`；**仅**超出剩余容量 → `TruncatedSymbol` |
| `c_q` | `1 ..= 255`（即 `c > 0`，量化后的像） | `InvalidHeaderField("c_q", …)` |
| `delta_q` | `1 ..= 100`（即 `0 < δ <= 1`） | `InvalidHeaderField("delta_q", …)` |
| 尾部 | 读完 `count` 个符号后必须**恰好**用完文件 | `TrailingBytes(已消费, 总长)` |

`c_q` / `delta_q` 这两个字段是 **LT3（2026-11-13）** 补上的：修复前它们是
头部里唯一没有域校验的两个，越界值被原样交给 `robust_soliton_checked`，于是
CLI 报出来的是**分布的错**：
```
$ # 合法容器的第 5 字节（c_q）改成 0
ltcode: decode error: degree distribution is not normalized: sum=0 (tolerance 1e-12)
$ # 第 6 字节（delta_q）改成 101（δ=1.01）
ltcode: decode error: degree distribution is not normalized: sum=1.01 (tolerance 1e-12)
```

文案指错了对象（用户从来没有给过「度数分布」），而且那两个 `sum=` 数字是
分布表的求和，从它们倒推不出"第 5/6 个字节坏了"。与 LT-2（魔数/版本）、
LT-G（K 变负）、LT-A（count / payload_len）、LT-D（尾部）同族：**头部字段
的问题必须按头部字段报**。修复后：

```
ltcode: not a ltcode container: invalid container header: c_q=0 is below the minimum 1
ltcode: not a ltcode container: invalid container header: delta_q=101 exceeds the maximum 100
```

副作用（好的那种）：`decode_full` 此后不会再因为**头部取值**而 raise
`DistributionNotNormalized`，那个变体恢复成它本来的含义（调用方自己构造的
分布表没归一化）。回归见 `src/header_guard_test.mbt` 的 `LT3:` 三条。

两点取舍值得说明：

- `count` 的两层判断：超过 `Int32` 上限是「头部字段离谱」（那个值转
  `Int32` 必变负），而仅超出剩余容量时更可能是**文件被截断** —— 后者对
  调用方的动作指引是「重传」，因此复用 `TruncatedSymbol` 而不是把两者
  混成一个。
- `payload_len` 的上界要**同时**钳到 `2^31−1`：`reassemble` 与
  `Container.payload_len` 都是有符号 `Int32`，不钳位就等于允许静默截断
  （`u64(2^32+5).to_int() == 5`）。
- `TrailingBytes` 与 `TruncatedSymbol` 是**两个方向**（读完还剩 / 读不到）。
  追加垃圾、`cat a.ltc b.ltc`、把 `count` 改小，三条都靠它拦住；`payload_hash`
  对第一、二种有可能通过，因此**结构自洽不能由内容哈希代劳**。

字节布局（全部大端，v2）：

```
offset  size  field
  0      4    magic = "LTC2"
  4      1    version = 2
  5      1    c_q     = round(c * 100)
  6      1    delta_q = round(delta * 100)
  7      4    K
 11      8    seed
 19      4    symbol_len
 23      8    payload_len
 31      8    payload_hash
 39      4    count
 43    ...    count × (index u32, data symbol_len bytes)
```

**自描述**：解码只需要这个文件。`c`/`delta` 量化成百分之一，且编解码
两个方向都过同一个量化函数 —— 否则两端会算出不同的子集。

**`payload_hash` 不是可选装饰**。没有它，被篡改的符号会让剥皮返回
`Complete` 但解出错误的源符号（实测 7/20 错），调用方拿到"看起来成功、
内容错误"的文件。`cmd_decode` 在写盘**之前**比对哈希，不一致就退出 3
且不写文件 —— 这是 PLAN §9 "成功时逐字节校验"的落点。

```moonbit
/// 解码 + 校验的便利入口（CLI 用它）：
/// Complete 的含义包含"哈希已核对通过"。
pub fn decode_verified(container : Container) -> DecodeResult raise LtError
```

## 9. 错误 `src/error.mbt`

```moonbit
pub(all) suberror LtError {
  EmptySource
  SourceTooLarge(Int, Int)
  SymbolLengthMismatch(Int, Int)
  InvalidDegree(Int, Int)
  DistributionNotNormalized(Double)
  TruncatedSymbol(Int, Int)
  /// 魔数不是 "LTC2" —— 不是截断，是"这根本不是 ltcode 文件"
  BadMagic
  /// 版本号本构建不支持（文件里的版本, 本构建支持的版本）
  UnsupportedVersion(Int, Int)
  /// 解码“完成”但载荷哈希不符（实际, 期望）。**不能**降级为 Incomplete：
  /// 数据不够可以再要符号；哈希不符说明数据本身坏了，再要也没用。
  CorruptionDetected(UInt64, UInt64)
  /// 容器头部字段超出可表示域（字段名, 实际值, 合法下界, 合法上界）。
  /// 四元组而非二元组：同一个变体既要报「超上限」（count / symbol_len /
  /// payload_len），也要报「低于下界」（K = 0），只说"超上限"会把后者描述错。
  InvalidHeaderField(String, UInt64, UInt64, UInt64)
  /// 尾部有多余字节（已消费字节数, 文件总长）。与 TruncatedSymbol 是
  /// **两个方向**：截断是"读不到"，尾部多余是"读完了还剩"。混成一个变体
  /// 会让调用方分不清该重传还是该丢弃。
  TrailingBytes(UInt64, UInt64)
} derive(Eq, Debug)

pub fn error_text(e : LtError) -> String
```

`error_text` 措辞固定（有测试锁定），脚本可以按文本匹配。

`BadMagic` / `UnsupportedVersion` 的存在理由：容器"这是什么东西"的两个
判据必须与"数据被截断"分开。

| 情况 | 变体 | `error_text` | CLI 实际输出 |
|---|---|---|---|
| 文件短于头部 / 符号体不全 | `TruncatedSymbol` | `truncated symbol: got N bytes, expected M` | 同左 |
| 魔数不是 `LTC2` | `BadMagic` | `bad magic` | `not a ltcode container: bad magic` |
| 版本号本构建不支持 | `UnsupportedVersion(found, supported)` | `unsupported container version F, this build supports S` | 同左 |
| 头部字段越界 | `InvalidHeaderField(name, v, lo, hi)` | `invalid container header: NAME=V exceeds the maximum HI`（下界方向是 `... is below the minimum LO`） | 同左 |
| 读完符号后仍有多余字节 | `TrailingBytes(used, total)` | `trailing bytes after the last symbol: USED bytes consumed of TOTAL; this is not the same file that was packed` | 同左 |

五者对调用方的**动作指引**不同：截断 / 尾部多余 → 重传或该丢弃这批数据；
魔数不符 → 换一个正确的文件；版本不符 → 换版本或升级本构建；头部字段
越界 → 这个文件不该被本构建读。旧实现把前三者混进了两个不相干的变体
（魔数并进 `TruncatedSymbol`，版本并进 `SourceTooLarge`，于是输出
"source too large: K=3 exceeds the limit of 2"，一个版本号被当成源符号数）。
LT-G 又修了一次同类错位：`K` 变负曾报 `empty source`（把"头部字段非法"
说成"输入为空"）。

`BadMagic` 的文本**不带** `not a ltcode container:` 前缀：`cmd_decode` 已经
加了那一段，重复会让实际输出变成两个前缀叠在一起。

退出码映射：`CorruptionDetected` / `InvalidHeaderField` / `TrailingBytes`
一律走 **3**（输入错误），不是 **1**。理由：退出码 1 的语义是“还差几个
符号，再给我一些就能解”（调用方的正常控制流），而这三者是“这批数据
不可用”（调用方应该丢弃并重新接收），两者对调用方的动作指引不同。

## 10. CLI `cmd/ltcode`

```
ltcode encode   --input <file> --symbols K [--seed S] [--count N] [--out <file>]
ltcode decode   --input <file> --out <file> [--symbols K] [--seed S]
ltcode simulate --symbols K --overhead O --trials T [--seed S] [--symbol-len N]
ltcode curve    --symbols K --overheads a,b,c --trials T [--seed S] [--symbol-len N]
ltcode distcmp  --symbols K --overhead O --trials T [--seed S] [--symbol-len N]
```

退出码：**0** 成功 / **1** 解码失败（数据不足）/ **2** 用法错误 / **3** 输入错误
（含容器损坏）。

`decode` 的 `--symbols` / `--seed` 是**可选核对项**：给了就必须与容器一致
（不一致报用法错误），不给就从文件读。这样"解码只需要这个文件"是真的。

所有命令的 `--seed` 默认 `0x4C54434F4445`（固定常数，不是时钟）。

### 只接受命名参数（LT-F）

每个参数都必须是显式命名的 `--option value` / `--option=value`。
**未知选项与位置参数一律是用法错误**（exit 2），报错回显原始 token：

```moonbit
pub fn accepted_keys(cmd : String) -> Array[String]
pub fn unknown_arg_error(args : Args, cmd : String) -> String   // 空串 = 干净
```

| 子命令 | 接受的键 |
|---|---|
| `encode` | `input symbols seed count out` |
| `decode` | `input out symbols seed` |
| `simulate` / `distcmp` | `symbols overhead trials seed symbol-len` |
| `curve` | `symbols overheads trials seed symbol-len` |
| `help` | （无） |

理由不是洁癖：`decode` 的 `--symbols` / `--seed` 是**可选核对项**，一个笔误
的键（`--seed` → `--seedx`）若被静默忽略，命令仍然打印
`decoded OK ... (checksum verified)` —— 用户以为核对过了。修复前实测
`--seedx 999999` 与尾随的 `some-junk` 都是 exit 0。

`parse_args` 因此同时记 `positional`（原位 token）与 `order`（**按 argv
顺序**的键名，报错顺序稳定）。数值形态不受影响：`--seed 0x...`、
`--trials -5`（负数是**值**）、`--overheads 1.0,1.1`、`--symbol-len 40`
全部照旧通过。

### 度量参数的量级上限（LT-B / LT2）

`simulate` / `curve` / `distcmp` 的四个参数直接决定循环次数或每次迭代的
分配量，超限一律 exit 2 并写明上限：

```moonbit
pub const LT_MAX_TRIALS      : Int32 = 10_000_000
pub const LT_MAX_RECEIVED    : Int32 = 4_000_000
pub const LT_MAX_SYMBOL_LEN  : Int32 = 1 << 20
/// LT6（2026-11-15 审计）：单点 `trials × received` 的符号操作总量上限
pub const LT_MAX_WORK        : Int64 = 2_000_000

pub fn guard_trials(trials : Int32) -> String                       // 空串 = 放行
pub fn guard_overhead(k : Int32, overhead : Double) -> String
pub fn guard_work(trials : Int32, k : Int32, overhead : Double) -> String
pub fn guard_symbol_len(symbol_len : Int32) -> String
/// LT2：`--symbols` 的域上界（与 encode 同一个上限，文案不同）
pub fn metric_symbols_bound_msg(k : Int32) -> String
```

`guard_overhead` 的守卫量是 **`K × overhead`（收到的符号数）**，不是
overhead 本身 —— 同一个 overhead 在 K=10 时无害、K=1<<20 时致命。它也显式
挡 `nan` / `inf`（`nan > 上限` 为 false，会静默放行）。

`guard_work`（LT6，2026-11-15 审计）的守卫量是 **`trials × received`
（单点的符号操作总量）**。LT-B 的三个上限是**独立**的，乘积没有守卫：
每个因子都在域内时，`simulate --symbols 1000000 --overhead 1.2
--trials 10`（1.2e7 符号操作）debug 构建 > 17 分钟不终止，
`simulate --symbols 1000 --overhead 1.2 --trials 10000000`（1.2e10）
外推 ≈ 20 小时。上限 `2e6` 的依据（release native 实测，单符号成本随
K 超线性：K=1000 → 6.1 µs、K=10000 → 19.9 µs、K=100000 → 215 µs、
K=1e6 → ≥1630 µs，单 trial 1961 s 未跑完）：

- 下界锚点是 README 承诺的复现命令 `simulate --symbols 1000 --overhead
  1.2 --trials 1000` = **1.2e6**（文档数字 793/1000，PLAN 指定的样本量
  —— 上限取 1e6 会把这条文档命令误伤成 exit 2）；
- README / DEMO 的全部既有命令每点 ≤ 1.2e6，放行不卡边界；上限内最坏
  组合（2e6 × 1630 µs）按实测外推 ≈ 55 分钟，不存在天级挂死的合法组合；
- 无守卫时的天文组合（1e7 trials × 4e6 received = 4e13 符号操作，
  数十万年）在用法层就报错，文案带上符号操作总量与上限。

修复前这四处都是挂死（实测 40~60 秒不终止，非报错、非退出）：`--overhead
2500000`、`--overhead 1e300`、`--trials 2147483647`、`--symbol-len
2000000000`。根因是 `received_count` 的 `.to_int()` 对 2.5e9 与 1e300 都
**饱和**到 `2147483647`，随后进入 21 亿次的逐符号编码循环。

`--symbols` 本身（LT2，2026-11-13 审计）也是这条路径上的一环，且它的越界
**不是**量级问题而是**域**问题：上界由库的 `max_source_symbols()`（`1 << 20`）
定，`encode` 早在 LT-K 就按 exit 2 拒绝了同一个值，度量侧却漏掉，于是
`simulate --symbols 1048577` 一路走到 `random_sources(k)` 的 k 次分配
（**在** `SourceBlock::new` 的 K 检查之前），最后报
`simulate failed: source too large: K=...`、exit 3 —— 一个「输入文件非法」
的措辞，而度量命令根本没有输入文件，文案也没点名 `--symbols`。
现在三个度量命令都先查这一条（`check_metric_magnitudes` 的第一个判断），
文案由 `metric_symbols_bound_msg` 给出：

```
ltcode: --symbols must be <= 1048576 (got 1048577); the degree distribution
        table and the decoding CSR index are O(K), so measure at a smaller K
        and raise --overhead instead
```

不复用 `symbols_bound_msg`（encode 那条）是因为**下一步建议不同**：那句写
「把文件切分成几段分别编码」，而度量命令不读文件。同一个上界、两种建议，
比一句话两头都不对要清楚。

`encode --count` 的默认值 `ceil(1.5K)+1` 也会触顶（K=700000 → 1050001
> `LT_MAX_COUNT`）。那处用独立文案说明「**这是默认值**，你没传 --count」：

```moonbit
pub fn default_count(k : Int32) -> Int32
pub fn default_count_overflow_msg(k : Int32) -> String   // 空串 = 没触顶
pub fn explicit_count_overflow_msg(count : Int32) -> String
pub fn symbols_bound_msg(k : Int32) -> String            // 空串 = 放行
```

`default_count` 是 `(3K+1)/2 + 1`（即 `ceil(1.5K)+1`，整数算式，K 为奇数时
不靠浮点截断）。`--symbols` 与 `--count` 同域：两者越界都是**用法错误**
（exit 2），`symbols_bound_msg` 的文案点名 `--symbols` 与上界
`max_source_symbols()`（1<<20），不再把话推到「切不开输入」上
（2026-11-11 审计，LT-K）。

`encode` **末尾的可解性验算**（2026-11-12 followup，LT1）：

```moonbit
pub const LT_VERIFY_MAX_COUNT : Int32 = 4096
pub fn should_verify_solvability(count : Int32) -> Bool
pub fn solvability_note(k : Int32, count : Int32, missing : Int32) -> String  // 空串 = 不用说话
```

`encode` 写完容器后用**同一个解码器**试解一次（内部 `verify_solvability`，
私有；它只调 `@lib.decode_full`，不另写剥皮 —— 判据只能有一个来源）。
`solvability_note` 的文本被 README 逐字引用，`missing <= 0` 时返回空串：

- 解得出 → stdout 与修复前**逐字相同**（一个字节都不多）；
- 解不出 → 多一行
  `note: these N symbols cannot recover all K source symbols (M missing); decode will report INCOMPLETE - raise --count (the default is ceil(1.5K)+1)`；
- **退出码不变（仍 0）**：容器字段自洽，只是符号不够；这一行是提示不是错误。

`should_verify_solvability` 是成本闸门：只在 `1 <= count <= 4096` 时验算。
理由是验算 = 再解一遍（同一个 `count × 平均度数 × symbol_len` XOR 量），
无条件下跑等于让每次编码慢一倍；4096 覆盖默认 count 在 `K <= 2730` 时的全部
取值（`default_count(2730) = 4096`）。**超阈值时验算完全不跑**，因此「没有打印
提示」**不等于**「已验证可解」—— 这是 best-effort，`help` 与 README 都写明。
`--count 0` 不验算（零符号必然解不出），两条 `note:` 互斥，零符号那条优先。
回归见 `cmd/ltcode/solvability_note_wbtest.mbt`。

`encode --count 0` 是**合法但无意义**的组合：产出只有 43 字节头部、0 个编码
符号的容器（`entropy=0` 的合法容器），`decode` 对它如实报
`INCOMPLETE: missing K of K`、退出码 1。不拒绝是因为它本身结构完好
（可再补符号后解码），拒绝它会让"先建容器、后按需补符号"的用法无处落脚；
但别把它当"空文件编码" —— 空输入早在 `SourceBlock::from_bytes` 就被
`EmptySource` 拒掉了。

`unpack_container` 对 `symbol_len` 的域校验只看字段自身
（`1 <= symbol_len <= Int32.MAX`），**不再**用「文件总长度」当上界：零符号
容器没有符号体，43 字节的头部长度会把 `symbol_len > 43` 的合法头部判死
（对 4000 字节 payload 即 K <= 93），于是编码端写得出、解码端读不回。
「不许为符号体做超长分配」由 `count` 一侧的剩余字节检查负责：每个符号占
`4 + symbol_len` 字节，`count >= 1` 时必然被卡住，`count == 0` 时不读任何
符号体。回归见 `count_zero_symbol_len_test.mbt`（2026-11-11 审计，LT-I）。

### 数值参数的三态与报错

数值参数**不再用 `T?`** 表示（`None` 无法区分"没给"和"给了垃圾"）。
`Args::int` / `uint64` / `double` 返回 `ArgNum[T]`：

```moonbit
pub(all) enum ArgNum[T] {
  Absent          // 这个参数没出现 → 用默认值，合法
  Present(T)      // 拿到了一个真值
  Invalid(String) // 出现了，但不是数 → 用法错误，exit 2；带原始 token 回显
}
```

规则（每一条都由 `cmd/ltcode/cli_test.mbt` 锁定）：

- **整数**：严格十进制，可有一个前导 `-`，必须在 `Int32` 范围内。
  `abc`、`1.5`、`2147483648`、`0x10` 全部是 `Invalid`。
- **种子**：十进制，或**显式 `0x` / `0X` 前缀**的十六进制（`0xabc` = 2748）。
  裸字母串 `abc` 是 `Invalid` —— 它**不是** `0xABC`。负号也是 `Invalid`，
  不会被悄悄归零。
- **浮点**：`@strconv` 负责词法，非有限值（`nan` / `inf` / `-inf`）判 `Invalid`。
- 报错文本统一由 `num_error(key, kind, raw)` 生成：
  `--symbols needs an integer, got 'abc'`（**带上用户写的原文**）。

> 为什么不用 `@strconv.parse_int` / `parse_int64(base=16)`：
> 前者会替调用方推断进制（`parse_int("0x10")` = 16），后者的
> `parse_int64("abc", base=16)` 合法返回 2748。参数层不能猜 ——
> 一个 token 的进制只能由它自己用 `0x` 前缀声明。

### `--overheads` 的列表语义

`parse_overheads_strict(spec) -> Result[Array[Double], String]` 是 `curve`
的入口，**任何一项非法都让整条命令失败**（exit 2，报错回显原始片段）：

```
ltcode: --overheads 'abc' is not a positive number
```

旧实现（`parse_overheads`，仍然保留）会静默丢弃非法项，于是
`--overheads 1.0,abc,1.5` 只跑两行、exit 0 —— 用户以为曲线覆盖三个点，
实际只有两个。度量工具悄悄缩小自己的工作范围比报错更糟，所以子命令
一律走严格入口。空段（`1.0,,1.5`）、非正数（`0` / `-1`）、`nan` / `inf`
同样被拒绝。