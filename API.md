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

**验证**：全部 65536 对 `gf256_mul(a,b) == gf256_mul_peasant(a,b)`；
`mul(0x57, 0x83) == 0xC1`（FIPS-197 §4.2）；
`mul(a, inv(a)) == 1` 对全部 255 个非零 a。

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
  /// 解码“完成”但载荷哈希不符（实际, 期望）。**不能**降级为 Incomplete：
  /// 数据不够可以再要符号；哈希不符说明数据本身坏了，再要也没用。
  CorruptionDetected(UInt64, UInt64)
} derive(Eq, Debug)

pub fn error_text(e : LtError) -> String
```

`error_text` 措辞固定（有测试锁定），脚本可以按文本匹配。

退出码映射：`CorruptionDetected` 走 **3**（输入错误），不是 **1**。
理由：退出码 1 的语义是“还差几个符号，再给我一些就能解”（调用方的正常
控制流），而 `CorruptionDetected` 是“这批数据不可用”（调用方应该丢弃并
重新接收），两者对调用方的动作指引不同。

## 10. CLI `cmd/ltcode`

```
ltcode encode   --input <file> --symbols K [--seed S] [--count N] [--out <file>]
ltcode decode   --input <file> --out <file> [--symbols K] [--seed S]
ltcode simulate --symbols K --overhead O --trials T [--seed S]
ltcode curve    --symbols K --overheads a,b,c --trials T [--seed S]
ltcode distcmp  --symbols K --overhead O --trials T [--seed S]
```

退出码：**0** 成功 / **1** 解码失败（数据不足）/ **2** 用法错误 / **3** 输入错误
（含容器损坏）。

`decode` 的 `--symbols` / `--seed` 是**可选核对项**：给了就必须与容器一致
（不一致报用法错误），不给就从文件读。这样"解码只需要这个文件"是真的。

所有命令的 `--seed` 默认 `0x4C54434F4445`（固定常数，不是时钟）。

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