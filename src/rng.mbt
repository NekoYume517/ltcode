///|
/// 确定性 PRNG：`xorshift128+`，种子经 `splitmix64` 扩展为 2×UInt64 状态。
///
/// 为什么不用宿主随机源：本项目的核心承诺是「同一种子 + 同一输入，输出逐字节相同」。
/// 任何时间、地址、哈希随机化都会破坏这一点，且是**跨目标不一致**的经典来源
/// （wasm 与 native 的地址空间布局不同）。这里的状态完全由种子决定。
///
/// `xorshift128+` 的选择理由：Vigna 2014 的构造，周期 2^128-1，
/// 通过 BigCrush；状态只有 16 字节，适合作为「可以随便复制/重放」的编码器随机源。
/// 它**不是**密码学安全的，本项目也不需要 —— 编码符号的子集选择是可公开的。

///|
/// splitmix64：Steele/Lea 2014。用于把单个种子扩展成 `xorshift128+` 的
/// 2×64 位状态（`xorshift128+` 不能由全零状态起步，而小整数种子直接放进去
/// 会产生高度相关的前几个输出）。
pub fn splitmix64(z : UInt64) -> UInt64 {
  let mut x = z + 0x9E3779B97F4A7C15UL
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9UL
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBUL
  x ^ (x >> 31)
}

///|
/// 状态：两个 64 位字。
pub struct Ltrng {
  priv mut s0 : UInt64
  priv mut s1 : UInt64
}

///|
/// 由单个种子构造。状态为 `splitmix64(seed)` 与其下一次输出 —— 这两步
/// 保证任意种子（含 0）都不会落到全零状态。
pub fn Ltrng::new(seed : UInt64) -> Ltrng {
  let a = splitmix64(seed)
  let b = splitmix64(a)
  { s0: a, s1: b, }
}

///|
/// 取出下一个 64 位输出（xorshift128+ 标准形式）。
pub fn Ltrng::next_u64(self : Ltrng) -> UInt64 {
  let mut x = self.s0
  let y = self.s1
  self.s0 = y
  x = x ^ (x << 23)
  self.s1 = x ^ y ^ (x >> 17) ^ (y >> 26)
  self.s1 + y
}

///|
/// `2^64 mod n`：拒绝采样的阈值。小于这个值的原始样本被丢弃，
/// 因为它们在 `[0, 2^64)` 里属于「多出来的那一段」。
///
/// 单列成函数是为了让拒绝逻辑**可以被独立验证**：手算 `n = 7` 时
/// `2^64 mod 7 = 2`（因为 `2^3 ≡ 1`，`2^64 = 2^(3·21+1) ≡ 2`），
/// 于是原始值 0 和 1 必须被丢弃 —— 这条有测试锁定（`rng_test.mbt`）。
pub fn rejection_threshold(n : Int32) -> UInt64 {
  if n <= 1 {
    return 0UL
  }
  let bound = n.to_uint64()
  // 0xFFFF...FFFF + 1 在 UInt64 上回绕成 0，所以这里写成 (max - bound + 1) 的形式，
  // 语义是 (2^64 - n) mod n == 2^64 mod n。
  (0xFFFFFFFFFFFFFFFFUL - bound + 1UL) % bound
}

///|
/// 把一个原始 64 位样本映射到 `[0, n)`；落在拒绝区时返回 `None`。
/// `next_below` 就是「反复取样本直到不被拒绝」。
pub fn map_below(v : UInt64, n : Int32) -> Int32? {
  if n <= 1 {
    return Some(0)
  }
  let bound = n.to_uint64()
  if v < rejection_threshold(n) {
    None
  } else {
    Some((v % bound).to_int())
  }
}

///|
/// `[0, 1)` 内的均匀 Double，53 位精度。
///
/// 取 `next_u64() >> 11` 得到 53 位尾数（Double 的有效位数），
/// 再乘 `2^-53`。这样每个可表示的 Double 取值概率相等，
/// 而 `(next_u64() as Double) / 2^64` 会因为 Double 只有 53 位精度
/// 使低位随机性被舍入掉（不影响结果，但 `>> 11` 是更干净的写法）。
pub fn Ltrng::next_double(self : Ltrng) -> Double {
  let top = self.next_u64() >> 11
  top.to_double() * 0.00000000000000011102230246251565
}

///|
/// `[0, n)` 内的均匀整数。
///
/// **用拒绝采样，不用裸取模**。裸取模会引入偏差：`2^64` 一般不能被 `n` 整除，
/// 最小的 `2^64 mod n` 个余数比其余余数各多出现一次。对 `n = 7` 这个偏差是
/// 2/2^64 量级，在统计测试里**根本抓不到** —— 所以本项目的验证方式不是
/// 「跑很多次看频率」，而是把拒绝逻辑拆成 `map_below` 直接断言
/// 「哪些原始值必须被丢」（见 `rng_test.mbt` 的 `n = 7` 用例）。
///
/// `n <= 1` 时返回 0：退化输入只有唯一可能取值，不报错。
pub fn Ltrng::next_below(self : Ltrng, n : Int32) -> Int32 {
  if n <= 1 {
    return 0
  }
  while true {
    match map_below(self.next_u64(), n) {
      Some(v) => return v
      None => continue
    }
  }
  0
}
