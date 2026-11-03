///|
/// Luby Transform 的度数分布。
///
/// 两个分布都在这里：理想孤波（Ideal Soliton）与鲁棒孤波（Robust Soliton）。
/// 前者是 LT 论文的原始构造，后者是实际可用的版本 —— 差别全在尾部那一段
/// τ(d)，而**恰恰是这一段决定了 1.0 开销下会不会全军覆没**。
///
/// 所有常数都带来源说明：
/// - `ρ(d) = 1/K`, `ρ(d) = 1/(d(d-1))`：Luby 2002 定义。
/// - `τ` 与 `R = c·ln(K/δ)·sqrt(K)`：同文 §"Robust Soliton Distribution"。
/// - `c` 与 `δ` 没有普适最优值，本项目取 `c=0.1, δ=0.5`（README 里的实测
///   曲线就是这两个参数下的结果，换参数要重测）。
///
/// **重要**：`R` 的公式里有 `ln(K/δ)`，PLAN.md 里顺手写的 "R ≈ 21.7"
/// 对应 `δ = 1.0`（`0.1·ln(1000)·sqrt(1000) = 21.844`）。δ = 0.5 时
/// 正确值是 **24.036**。这里选 PLAN.md 明确指定的 δ=0.5，并在测试里
/// 同时锁定两个值，避免以后有人「按 PLAN 的 21.7 去改实现」。

///|
/// 理想孤波的 ρ(d)。`d` 超出 `[1, K]` 时返回 0。
pub fn ideal_rho(d : Int32, k : Int32) -> Double {
  if k < 1 || d < 1 || d > k {
    return 0.0
  }
  if d == 1 {
    1.0 / k.to_double()
  } else {
    1.0 / (d.to_double() * (d - 1).to_double())
  }
}

///|
/// 鲁棒孤波的尖峰期望数 `R = c·ln(K/δ)·sqrt(K)`。
///
/// 含义：期望在解码过程中出现 `R` 个「度为 1 的符号」，用来启动剥皮。
/// `c` 越大、`δ` 越小，冗余越多、失败概率越低。
pub fn robust_r(k : Int32, c : Double, delta : Double) -> Double {
  c * @math.ln(k.to_double() / delta) * k.to_double().sqrt()
}

///|
/// `τ` 的尖峰位置 `K/R`，取整数下标。
///
/// 教科书写作区间 `1 .. K/R - 1` 加上单独定义的 `K/R` 那一点。当 `K/R < 1`
/// （极端参数下 `R > K`）时取 `1`：否则尖峰会落到下标 0 上，而度数从 1 起。
pub fn robust_kr_index(k : Int32, c : Double, delta : Double) -> Int32 {
  let r = robust_r(k, c, delta)
  if r <= 0.0 {
    return 1
  }
  let kr = (k.to_double() / r).to_int()
  if kr < 1 {
    1
  } else {
    kr
  }
}

///|
/// 鲁棒孤波的 τ(d)。
///
/// ```
/// τ(d) = R/(d·K)               d = 1 .. K/R - 1
/// τ(K/R) = R·ln(R/δ)/K         （该点单独定义，值通常远大于区间公式）
/// τ(d) = 0                     其余
/// ```
///
/// `K/R` 那一点的值明显高于区间公式（K=1000/c=0.1/δ=0.5 时：0.0931 vs
/// 0.0586），这是分布能在有限 K 下工作的关键 —— 少写这一条，度数分布就退化成
/// 一个近似 1/d 的尾巴，1.2 开销下的成功率会掉一大截。
pub fn robust_tau(d : Int32, k : Int32, c : Double, delta : Double) -> Double {
  if k < 1 || d < 1 || d > k {
    return 0.0
  }
  let r = robust_r(k, c, delta)
  let kr = robust_kr_index(k, c, delta)
  if d < kr {
    r / (d.to_double() * k.to_double())
  } else if d == kr {
    r * @math.ln(r / delta) / k.to_double()
  } else {
    0.0
  }
}

///|
/// 归一化常数 `β = Σ(ρ+τ)`。
pub fn robust_beta(k : Int32, c : Double, delta : Double) -> Double {
  let mut total = 0.0
  for d = 1; d <= k; d = d + 1 {
    total = total + ideal_rho(d, k) + robust_tau(d, k, c, delta)
  }
  total
}

///|
/// 一个具体的（离散）度数分布：`pmf[1..k]` 与它的前缀和。
///
/// 存前缀和是为了采样 O(log K)（二分），而不是每次重算 O(K)。
/// 编码器会给每个符号抽一次度数，K 上万时这个差别很实在。
pub(all) struct Distribution {
  k : Int32
  /// 下标 1..k 有效，下标 0 恒为 0（未使用）。
  pmf : FixedArray[Double]
  /// `cdf[d] = Σ_{i=1..d} pmf[i]`，非降，`cdf[k] ≈ 1`。
  cdf : FixedArray[Double]
}

///|
/// `pdf(d)`：度数恰为 `d` 的概率。`d` 越界返回 0。
pub fn Distribution::pdf(self : Distribution, d : Int32) -> Double {
  if d < 1 || d > self.k {
    0.0
  } else {
    self.pmf[d]
  }
}

///|
/// `cdf(d) = P(deg <= d)`。
pub fn Distribution::cdf_at(self : Distribution, d : Int32) -> Double {
  if d < 1 {
    0.0
  } else if d > self.k {
    1.0
  } else {
    self.cdf[d]
  }
}

///|
/// 期望度数 `Σ d·μ(d)`。文档与自检用。
pub fn Distribution::expected_degree(self : Distribution) -> Double {
  let mut total = 0.0
  for d = 1; d <= self.k; d = d + 1 {
    total = total + d.to_double() * self.pmf[d]
  }
  total
}

///|
/// 逆变换采样：取 `u ~ U[0,1)`，返回最小的 `d` 使 `cdf(d) > u`。
///
/// 二分而非线性扫描。浮点边界上 `cdf[k]` 可能略小于 1（累加误差），
/// 因此 `u` 极大时会落到 `k+1` —— 钳到 `k`，而不是返回越界值。
pub fn Distribution::sample(self : Distribution, rng : Ltrng) -> Int32 {
  if self.k <= 1 {
    return 1
  }
  let u = rng.next_double()
  let mut lo = 1
  let mut hi = self.k
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.cdf[mid] <= u {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo > self.k {
    self.k
  } else {
    lo
  }
}

///|
/// 由裸 pmf 数组构造（`pmf[d-1]` 是度数 d 的概率）。不校验归一化 ——
/// 校验请用 `validate_distribution`。这条入口存在是为了让测试能构造
/// **故意不归一化**的分布，验证校验逻辑真的会拒绝它。
pub fn distribute_from_array(k : Int32, values : Array[Double]) -> Distribution {
  let pmf : FixedArray[Double] = FixedArray::make(k + 1, 0.0)
  for i = 0; i < values.length(); i = i + 1 {
    let d = i + 1
    if d <= k {
      pmf[d] = values[i]
    }
  }
  let cdf : FixedArray[Double] = FixedArray::make(k + 1, 0.0)
  let mut acc = 0.0
  for d = 1; d <= k; d = d + 1 {
    acc = acc + pmf[d]
    cdf[d] = acc
  }
  { k, pmf, cdf, }
}

///|
/// 固定度分布：度数恒为 `d0`（`1 <= d0 <= k`）。
///
/// 用途是对照实验：固定度分布**没有**「度为 1 的符号」的富集，
/// 剥皮几乎立刻卡死 —— 这正是鲁棒孤波 τ 那一段存在的理由。
pub fn fixed_distribution(d0 : Int32, k : Int32) -> Distribution {
  let values : Array[Double] = Array::make(k, 0.0)
  let idx = d0 - 1
  if idx >= 0 && idx < k {
    values[idx] = 1.0
  }
  distribute_from_array(k, values)
}

///|
/// 理想孤波分布。
pub fn ideal_soliton(k : Int32) -> Distribution {
  let values : Array[Double] = Array::make(k, 0.0)
  for i = 0; i < k; i = i + 1 {
    values[i] = ideal_rho(i + 1, k)
  }
  distribute_from_array(k, values)
}

///|
/// 鲁棒孤波分布 `μ(d) = (ρ(d) + τ(d)) / β`。
pub fn robust_distribution(
  k : Int32,
  c : Double,
  delta : Double,
) -> Distribution {
  let beta = robust_beta(k, c, delta)
  let values : Array[Double] = Array::make(k, 0.0)
  for i = 0; i < k; i = i + 1 {
    let d = i + 1
    values[i] = (ideal_rho(d, k) + robust_tau(d, k, c, delta)) / beta
  }
  distribute_from_array(k, values)
}

///|
/// 归一化校验：`|Σμ - 1| <= 1e-12`，且每一项非负、无 NaN。
pub fn validate_distribution(dist : Distribution) -> Result[Unit, LtError] {
  let mut total = 0.0
  for d = 1; d <= dist.k; d = d + 1 {
    let p = dist.pmf[d]
    if p.is_nan() || p < 0.0 {
      return Err(LtError::DistributionNotNormalized(total))
    }
    total = total + p
  }
  let err = total - 1.0
  if err.abs() > 0.000000000001 {
    Err(LtError::DistributionNotNormalized(total))
  } else {
    Ok(())
  }
}

///|
/// 带参数校验的鲁棒孤波构造。
///
/// 拒绝的输入：`K < 1`、`c <= 0`、`δ <= 0`、`δ > 1`。
/// `δ` 的物理含义是「目标解码失败概率」，大于 1 没有意义。
pub fn robust_soliton_checked(
  k : Int32,
  c : Double,
  delta : Double,
) -> Result[Distribution, LtError] {
  if k < 1 {
    return Err(LtError::InvalidDegree(k, k))
  }
  if c <= 0.0 || c.is_nan() {
    return Err(LtError::DistributionNotNormalized(c))
  }
  if delta <= 0.0 || delta > 1.0 || delta.is_nan() {
    return Err(LtError::DistributionNotNormalized(delta))
  }
  let dist = robust_distribution(k, c, delta)
  match validate_distribution(dist) {
    Ok(_) => Ok(dist)
    Err(e) => Err(e)
  }
}

///|
/// **便利入口**（PLAN.md §4 的签名）：每次调用重建分布表。
///
/// 循环里要抽很多次度数时，请先 `robust_distribution(...)` 拿到 `Distribution`
/// 再反复 `Distribution::sample` —— 那才是 O(log K) 的路径，这条是 O(K)。
pub fn sample_degree(
  rng : Ltrng,
  k : Int32,
  c : Double,
  delta : Double,
) -> Int32 {
  robust_distribution(k, c, delta).sample(rng)
}
