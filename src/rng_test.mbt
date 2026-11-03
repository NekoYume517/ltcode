///|
/// PRNG 测试。
///
/// **锁定的 16 个输出是外部算出来的**，不是「跑一遍实现把结果抄下来」——
/// 后者只能防「以后改坏了」，不能防「一开始就写错」。这些数字由一份独立的
/// Python 参考实现（同样实现 splitmix64 + xorshift128+）算出，见
/// `docs/implementation.md` 第 2 节。

///|
test "prng first 16 outputs from seed 0x0123456789ABCDEF are locked" {
  let rng = Ltrng::new(0x0123456789ABCDEFUL)
  let expected : Array[UInt64] = [
    0x16D1852795370BBAUL, 0x93AEBB731108DA74UL, 0xC02F7F9B82A3A75FUL, 0xF2F9A128870A0F8FUL,
    0x810B563338F5194CUL, 0xF95E72F761290B3FUL, 0x4A72CFE96AE0A4C6UL, 0xDD47280B88329186UL,
    0x5FAB09018A216A94UL, 0x7C9FBA30ABFD35C8UL, 0x9C2F919C3F49AE9DUL, 0x07398F88C280380CUL,
    0x2D6605ACB3D4CF70UL, 0xE18D6CCAA3F0877DUL, 0x8AD149A1E272AF48UL, 0x1E91AA21601F200FUL,
  ]
  for i = 0; i < 16; i = i + 1 {
    let got = rng.next_u64()
    if got != expected[i] {
      println("index \{i}: got 0x\{got.to_string(radix=16)}")
    }
    assert_eq(got, expected[i])
  }
}

///|
test "prng same seed replays identically" {
  let a = Ltrng::new(42UL)
  let b = Ltrng::new(42UL)
  for i = 0; i < 64; i = i + 1 {
    assert_eq(a.next_u64(), b.next_u64())
  }
}

///|
test "prng different seeds diverge immediately" {
  let a = Ltrng::new(1UL)
  let b = Ltrng::new(2UL)
  let mut same = 0
  for i = 0; i < 32; i = i + 1 {
    if a.next_u64() == b.next_u64() {
      same = same + 1
    }
  }
  inspect(same, content="0")
}

///|
/// 无偏性：`next_below(7)` 在 70000 次里各值出现 10000±300。
///
/// 这个区间对应 3σ 略宽（σ = sqrt(70000 * (1/7) * (6/7)) ≈ 92.6，
/// 300 约等于 3.24σ），留出确定性种子下仍能通过的余量 —— 但**足以抓住
/// 取模导致的偏差**：`next_u64() % 7` 的偏差是最小值比最大值多 1/2^64
/// 个计数，在 70000 次里完全看不出来。所以这条测试真正排除的是
/// 「用低几位做掩码」这类明显有偏的实现（例如 `% 8` 再重映射），而不是
/// 检测 2^-64 量级的偏差。这一点在 README 里如实写明。
test "prng next_below(7) is uniform within 3 sigma over 70000 draws" {
  let rng = Ltrng::new(0x9E3779B97F4A7C15UL)
  let counts : Array[Int32] = Array::make(7, 0)
  let total = 70000
  for i = 0; i < total; i = i + 1 {
    let v = rng.next_below(7)
    counts[v] = counts[v] + 1
  }
  let mut out_of_range = 0
  for i = 0; i < 7; i = i + 1 {
    let d = counts[i] - 10000
    if d.abs() > 300 {
      out_of_range = out_of_range + 1
    }
  }
  inspect(out_of_range, content="0")
}

///|
test "prng next_below respects bounds and rejects non-positive n" {
  let rng = Ltrng::new(7UL)
  let mut bad = 0
  for i = 0; i < 2000; i = i + 1 {
    let v = rng.next_below(13)
    if v < 0 || v >= 13 {
      bad = bad + 1
    }
  }
  inspect(bad, content="0")
  inspect(rng.next_below(0), content="0")
  inspect(rng.next_below(-3), content="0")
  // n == 1 的退化情况：永远返回 0
  for i = 0; i < 32; i = i + 1 {
    inspect(rng.next_below(1), content="0")
  }
}

///|
/// 拒绝采样逻辑本身的直接断言：手算出来的「哪些原始值必须被丢」。
///
/// `n = 7` 时 `2^64 mod 7 = 2`（`2^3 ≡ 1 (mod 7)`，`64 = 3·21+1`），
/// 所以原始值 `0` 和 `1` 必须被拒绝 —— 否则它们对应的余数 0、1
/// 会比余数 2..6 多出现一次。
test "prng rejection threshold is exactly 2^64 mod n" {
  inspect(rejection_threshold(7), content="2")
  inspect(rejection_threshold(13), content="3")
  inspect(rejection_threshold(3), content="1")
  inspect(rejection_threshold(10), content="6")
  // 2 的幂整除 2^64，偏差为零，阈值必须是 0（永远不拒绝）
  inspect(rejection_threshold(8), content="0")
  inspect(rejection_threshold(256), content="0")
  // 退化输入
  inspect(rejection_threshold(0), content="0")
  inspect(rejection_threshold(1), content="0")
}

///|
/// `map_below` 的行为：拒绝区返回 None，其余返回真实余数。
test "prng map_below drops exactly the biased prefix" {
  // n = 7：0 和 1 被丢弃
  inspect(map_below(0UL, 7) is None, content="true")
  inspect(map_below(1UL, 7) is None, content="true")
  inspect(map_below(2UL, 7), content="Some(2)")
  inspect(map_below(8UL, 7), content="Some(1)")
  inspect(map_below(9UL, 7), content="Some(2)")
  // 最大原始值必须被接受：2^64-1 ≡ 1 (mod 7)（因为 2^64 ≡ 2）
  inspect(map_below(0xFFFFFFFFFFFFFFFFUL, 7), content="Some(1)")
  // n = 8 是 2 的幂：一个都不丢
  let mut rejected = 0
  for v = 0; v < 64; v = v + 1 {
    if map_below(v.to_uint64(), 8) is None {
      rejected = rejected + 1
    }
  }
  inspect(rejected, content="0")
  // n <= 1：退化
  inspect(map_below(12345UL, 1), content="Some(0)")
  inspect(map_below(12345UL, 0), content="Some(0)")
}

///|
/// 覆盖测试：若不拒绝而是裸取模，余数 0 和 1 在全空间里各多 1 个计数。
/// 这条断言直接对 `[0, 2^64)` 的前 2^24 段做穷举计数差 —— 在小范围内
/// 偏差是**可见的**（这正是「统计测试抓不到」的反面证据）。
test "prng modulo bias would be visible without rejection" {
  // 在 [0, 2^24) 上，n = 7：2^24 mod 7 = 2，所以裸取模下余数 0,1 各多一次。
  let span : Int32 = 1 << 24
  let counts : Array[Int32] = Array::make(7, 0)
  for v = 0; v < span; v = v + 1 {
    let r = v % 7
    counts[r] = counts[r] + 1
  }
  // 裸取模：余数 0 与 1 比其余多一个（2^24 = 7*2396745 + 1，实际差 1）
  let diff_raw = counts[0] - counts[2]
  // 有拒绝：把多出的那一段丢掉，差值降到 0 以内（只统计被接受的取值）
  let counts2 : Array[Int32] = Array::make(7, 0)
  let thr = rejection_threshold(7)
  for v = 0; v < span; v = v + 1 {
    match map_below(v.to_uint64(), 7) {
      Some(r) => counts2[r] = counts2[r] + 1
      None => ()
    }
  }
  let diff_rej = counts2[0] - counts2[2]
  // 原始取模在 span=2^24 上确实存在可见偏差
  assert_true(diff_raw != 0)
  // 拒绝后（在这个小 span 上）差值不比原来更大
  assert_true(diff_rej <= diff_raw)
  // 并且被拒绝的样本数就是 (span mod 7) 相关的那一点点
  let mut dropped = 0
  for v = 0; v < span; v = v + 1 {
    if v.to_uint64() < thr {
      dropped = dropped + 1
    }
  }
  inspect(dropped, content="2")
}

///|
test "splitmix64 matches reference values" {
  // splitmix64 的输出是公开算法（Steele/Lea 2014），取值可独立核对。
  assert_eq(splitmix64(0UL), 0xE220A8397B1DCDAFUL)
  assert_eq(splitmix64(1UL), 0x910A2DEC89025CC1UL)
  assert_eq(splitmix64(2UL), 0x975835DE1C9756CEUL)
  assert_eq(splitmix64(3UL), 0x1D0B14E4DB018FEDUL)
}
