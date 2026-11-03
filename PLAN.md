# ltcode — 实现规格（v1）

> 本文件是实现的**契约**。实现必须逐条满足，测试必须逐条锁定。

## 0. 范围与命名

```
src/
  gf256.mbt         GF(256) 域运算（AES 多项式 0x11B）
  rng.mbt           确定性 PRNG（xorshift128+，显式种子，跨平台一致）
  distribution.mbt  Luby Transform 度数分布：理想孤波、鲁棒孤波、固定度
  symbol.mbt        源符号与编码符号的表示
  encoder.mbt       确定性编码
  decoder.mbt       剥皮解码 + inactivated 回退
  metrics.mbt       开销、失败率、解码复杂度统计
  error.mbt         错误类型
```

**范围内**：Luby Transform（LT）码作为 rateless erasure code 的完整实现：
编码、剥皮解码、度数分布、开销度量。
**不在范围内**：Raptor/RaptorQ（那是 LT + 预编码的分层构造，是另一个项目的量级）。

## 1. 硬约束

1. **确定性**：同一种子 + 同一输入，输出逐字节、逐符号相同。禁止依赖任何
   非种子熵源（哈希随机化、时间、地址）。
2. **可证伪的失败**：解码失败必须返回「还缺哪些源符号」，而不是返回一个
   看起来完整的错误结果。**绝不用填充值掩盖缺符号**。
3. **无隐藏的魔法常数**：每个常数（分布参数、域多项式、种子）都要在文档里
   说明来源，并且有测试锁定它的值。
4. **只用 core**：不引第三方数值/随机库。

## 2. GF(256)

多项式 `x^8 + x^4 + x^3 + x + 1`（`0x11B`，AES 用的那个）。

要求：
- `mul(a, b)` / `inv(a)` / `pow(a, n)`，`add` 就是 XOR。
- 用**对数/反对数表**实现乘法，表由生成元 3 的幂构造——不许硬编码 256 项表，
  因为手抄 256 项极可能错且无法审计。
- **测试锚点**：`mul(0x57, 0x83) == 0xC1`（FIPS-197 §4.2 的例子）、
  `mul(a, inv(a)) == 1` 对全部 255 个非零 a、`mul(0, x) == 0`。
- 对比度：与一个**独立实现的俄罗斯农民乘法**（不用表）逐项核对全部 65536 对。

## 3. PRNG

`xorshift128+`，状态 2×UInt64，种子经 splitmix64 扩展。

要求：
- `next_u64()`、`next_below(n)`（无偏，用拒绝采样而不是取模——取模有偏）。
- 同一 seed 序列固定，测试锁定前 16 个输出（防实现漂移）。
- 跨目标一致：wasm / native 输出相同（不用宿主随机源）。

## 4. 度数分布

### 4.1 理想孤波（Ideal Soliton）

`ρ(1) = 1/K`，`ρ(d) = 1/(d(d-1))` for `d = 2..K`。

### 4.2 鲁棒孤波（Robust Soliton）

给定 `K`、参数 `c`、`δ`：

```
R = c · ln(K/δ) · sqrt(K)
τ(d) = R/(d·K)                 for d = 1 .. K/R - 1
τ(K/R) = R·ln(R/δ)/K           （该点单独定义）
τ(d) = 0                       otherwise
μ(d) = (ρ(d) + τ(d)) / β        β = Σ(ρ+τ)
```

要求：
- `sample_degree(rng, K, c, δ) -> Int`，`1 <= d <= K`。
- `μ` 必须**归一化**：`Σ μ(d) == 1`，容差 1e-12，测试断言。
- **测试锚点**：`K=1000, c=0.1` 时
  - `δ=0.5` → `R = 0.1·ln(1000/0.5)·√1000 = 24.036164`
  - `δ=1.0` → `R = 0.1·ln(1000/1.0)·√1000 = 21.844240`

  （v1 初稿在此处写成「δ=0.5 时 R ≈ 21.7」，是**算术笔误**：21.844 对应 δ=1.0。
  实现按显式参数 δ=0.5 取值，并把两个值都锁进测试。以本条为准。）
- 度数 1 的概率必须等于 `1/K + τ(1)/β`，测试用 10000 次采样的频率在 3σ 内吻合。

## 5. 编码

编码符号 = 源符号子集的 XOR，子集由 `(seed, index)` 决定：
- 用 `rng` 从 `(seed, symbol_index)` 确定性派生（`splitmix64(seed ^ index)`），
  这样**任意**编码符号可独立生成，不依赖序列。
- 子集选择：`degree = sample_degree(...)`，然后从 `0..K-1` **无放回**抽 `degree` 个。
  无放回实现必须是均匀的（部分 Fisher-Yates，只抽前 degree 个），并且
  **不分配 O(K) 内存**（K 可能上万）。

要求：
- `encode_symbol(seed, index, sources : Array[Bytes]) -> Bytes`
- 输出的长度等于源符号长度（源符号预先填充到等长）。
- **测试**：同参数两次生成完全相同；不同 index 的子集满足「无放回」。

## 6. 解码（剥皮 peeling）

经典 LT 解码：
1. 维护每个收到符号的「未解出源符号集合」与它的 XOR 累积值。
2. 反复找度为 1 的符号 → 解出该源符号 → 从所有含它的符号里消去。
3. 没有度为 1 的符号时，解码停止。

要求：
- `decode(seed, K, symbol_len, received) -> DecodeResult`
  - `DecodeResult` 是枚举：`Complete(sources)` / `Incomplete(recovered, missing_indices)`
- **不使用 inactivated 回退的 v1**：剥皮失败就如实报 `Incomplete`。
  理由：inactivation 会引入 GF(256) 高斯消元，是独立的一大块，且在 LT 上收益有限。
  这条要写进 README，并说明「这是设计选择，不是缺陷」。
- 复杂度必须是 `O(received · avg_degree)`；断言解码时间随 K 近线性（用操作计数而非
  墙钟时间，墙钟在 CI 上不稳）。

## 7. 度量（这是本项目的差异化）

LT 码的实际价值全在「需要多少冗余」。必须提供：

- `overhead_ratio`：收到符号数 / K
- `decode_success_rate(trials)`：给定 overhead、种子区间，统计每次成功/失败
- **失败率曲线**：`evaluate(K, overheads, trials)` → 每个 overhead 的成功率
- **度数分布对成功率的影响**：同一 K 下比较 ideal soliton 与 robust soliton

要求（关键：这是可被证伪的数字）：

- 对 `K = 1000`，`overhead = 1.0` 时成功率应 **< 10%**（LT 在无冗余时通常失败）
- 对 `K = 1000`，`overhead = 1.2` 时成功率高（robust，c=0.1, δ=0.5）
- 这两个数字必须由**实测**给出并写进 README，不许从文献抄——不同实现差别很大。

## 8. 错误设计

```
pub(all) suberror LtError {
  EmptySource
  SourceTooLarge(Int, Int)          // K, 上限
  SymbolLengthMismatch(Int, Int)
  InvalidDegree(Int, Int)           // d, K
  DistributionNotNormalized(Double)
  TruncatedSymbol(Int, Int)
}
```

## 9. CLI（`cmd/ltcode`）

```
ltcode encode  --input <file> --symbols K --seed S --count N --out <file>
ltcode decode  --input <file> --symbols K --seed S --out <file>
ltcode simulate --symbols K --overhead 1.2 --trials 100 --seed S
ltcode curve    --symbols K --overheads 1.0,1.1,1.2,1.5 --trials 100 --seed S
```

- `encode` 的输出格式自定但必须自描述（含 K、seed、symbol_len、符号数），
  且**解码只需这个文件**。
- `decode` 成功时恢复原文件并逐字节校验；失败时打印缺哪些下标、退出码 1。
- `simulate` / `curve` 输出表格，成功率保留 3 位小数。

退出码：0 成功 / 1 解码失败（数据不足）/ 2 用法错误 / 3 输入错误。

## 10. 测试要求

- GF(256)：65536 对乘法与独立实现比对；255 个求逆恒等
- PRNG：前 16 输出锁定；无偏性（`next_below(7)` 在 70000 次里各值出现 10000±300）
- 分布：归一化 1e-12；采样频率 3σ；K=1/2/3 边界
- 编码：确定性；无放回；K=1 退化
- 解码：K=10、overhead=2.0 必成功；K=10、overhead=1.0 可能失败且失败时如实报缺
- 端到端：随机文件 × 多组 (K, overhead)，成功时逐字节恢复，失败时退出码与缺项正确
- 每个错误分支至少一条测试