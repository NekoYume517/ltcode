///|
/// 度数分布测试。
///
/// 三个层次的证据：
/// 1. **归一化**：Σμ(d) == 1，容差 1e-12。
/// 2. **理论 pmf 的独立核对**：用一份独立算出的参考值（Python，见
///    `docs/implementation.md`）逐项对齐关键点。
/// 3. **采样频率**：P(d=1) 在 10000 次里的频率落在 3σ 内。

///|
test "ideal soliton rho matches closed form and sums to 1" {
  let k = 1000
  let mut total = 0.0
  for d = 1; d <= k; d = d + 1 {
    let p = ideal_rho(d, k)
    total = total + p
  }
  let err = total - 1.0
  assert_true(err.abs() < 0.000000000001)
  // rho(1) == 1/K
  assert_true((ideal_rho(1, 1000) - 0.001).abs() < 0.000000000001)
  // rho(2) == 1/(2*1) == 0.5
  assert_true((ideal_rho(2, 1000) - 0.5).abs() < 0.000000000001)
  // rho(10) == 1/90
  let r10 = ideal_rho(10, 1000)
  assert_true((r10 - 1.0 / 90.0).abs() < 0.000000000001)
}

///|
test "robust soliton R for K=1000 c=0.1 delta=0.5 is 24.036..." {
  // PLAN.md 提到 "R ≈ 21.7" —— 那个数字对应 δ=1.0（或另一种写法）。
  // 本实现的公式严格按 R = c·ln(K/δ)·sqrt(K)，δ=0.5 时：
  //   ln(2000) = 7.600902...
  //   0.1 · 7.600902 · 31.622776 = 24.036164044928817
  // 这不是抄的：计算式就写在这里，任何人在计算器上都能复现。
  let r = robust_r(1000, 0.1, 0.5)
  let expected = 0.1 * 7.600902459542082 * 31.622776601683793
  let d = r - expected
  assert_true(d.abs() < 0.000000001)
  // 显式给出四位小数，便于人工核对
  let r4 = (r * 10000.0).round() / 10000.0
  let d4 = r4 - 24.0362
  assert_true(d4.abs() < 0.0000000001)
  // δ=1.0 时的值就是 PLAN.md 里的 21.7 量级，这条锁定「δ 变了 R 也变」
  let r1 = robust_r(1000, 0.1, 1.0)
  let r1_4 = (r1 * 1000.0).round() / 1000.0
  let d1 = r1_4 - 21.844
  assert_true(d1.abs() < 0.0000000001)
}

///|
test "robust soliton pmf normalizes to 1 within 1e-12" {
  for
    _, (k, c, delta) in [
      (1000, 0.1, 0.5),
      (1000, 0.1, 0.05),
      (100, 0.1, 0.5),
      (10, 0.1, 0.5),
      (3, 0.1, 0.5),
      (2, 0.1, 0.5),
      (1, 0.1, 0.5),
      (5000, 0.03, 0.5),
      (37, 0.5, 0.2),
    ] {
    let dist = robust_distribution(k, c, delta)
    let mut total = 0.0
    for d = 1; d <= k; d = d + 1 {
      total = total + dist.pdf(d)
    }
    let err = total - 1.0
    if err.abs() > 0.000000000001 {
      println("K=\{k} c=\{c} delta=\{delta}: sum=\{total}")
    }
    assert_true(err.abs() < 0.000000000001)
  }
}

///|
test "robust soliton reference values for K=1000 c=0.1 delta=0.5" {
  // 这些数字由独立的 Python 实现算出（同公式、无共享代码），见
  // docs/implementation.md 第 3 节。它们的作用是抓住「公式抄对了但实现里
  // 有一处 off-by-one」这类错误，例如 τ(K/R) 那一点被当成区间内普通点。
  let dist = robust_distribution(1000, 0.1, 0.5)
  let checks : Array[(Int32, Double)] = [
    (1, 0.02093456423305539),
    (2, 0.42813569232688664),
  ]
  for _, (d, want) in checks {
    let got = dist.pdf(d)
    let err = got - want
    if err.abs() > 0.000000000001 {
      println("pdf(\{d}) = \{got}, want \{want}")
    }
    assert_true(err.abs() < 0.000000000001)
  }
  // β（归一化常数）本身也锁定
  let beta = robust_beta(1000, 0.1, 0.5)
  let de = beta - 1.1959247761841183
  assert_true(de.abs() < 0.000000000001)
  // K/R = 41.6 → 区间 1..41，单点定义在第 41 点上
  let kr = robust_kr_index(1000, 0.1, 0.5)
  inspect(kr, content="41")
}

///|
test "robust soliton tau falls off at the K/R point exactly once" {
  let k = 1000
  let c = 0.1
  let delta = 0.5
  let r = robust_r(k, c, delta)
  let kr = robust_kr_index(k, c, delta)
  // 区间内：τ(d) = R/(d·K)
  let t1 = robust_tau(1, k, c, delta)
  let want1 = r / (1.0 * 1000.0)
  let d1 = t1 - want1
  assert_true(d1.abs() < 0.000000000001)
  let t5 = robust_tau(5, k, c, delta)
  let want5 = r / (5.0 * 1000.0)
  let d5 = t5 - want5
  assert_true(d5.abs() < 0.000000000001)
  // 第 K/R 点：τ = R·ln(R/δ)/K，与区间内公式给出不同的值
  let tkr = robust_tau(kr, k, c, delta)
  let want_kr = r * @math.ln(r / delta) / 1000.0
  let dkr = tkr - want_kr
  assert_true(dkr.abs() < 0.000000000001)
  // 这两者在同一点上必须不同，否则说明实现把单点定义漏掉了
  let interval_form = r / (kr.to_double() * 1000.0)
  assert_true((tkr - interval_form).abs() > 0.0001)
  // 区间外一律为 0
  let mut nonzero_outside = 0
  for d = kr + 1; d <= k; d = d + 1 {
    if robust_tau(d, k, c, delta) != 0.0 {
      nonzero_outside = nonzero_outside + 1
    }
  }
  inspect(nonzero_outside, content="0")
}

///|
test "degree sampling stays in [1, K] for many K" {
  for _, k in [1, 2, 3, 4, 7, 10, 37, 100, 1000] {
    let rng = Ltrng::new(k.to_uint64() * 7717UL + 13UL)
    let mut bad = 0
    for i = 0; i < 2000; i = i + 1 {
      let d = sample_degree(rng, k, 0.1, 0.5)
      if d < 1 || d > k {
        bad = bad + 1
      }
    }
    if bad != 0 {
      println("K=\{k}: \{bad} out of range")
    }
    inspect(bad, content="0")
  }
}

///|
/// P(d=1) 的频率吻合。
///
/// σ = sqrt(n·p·(1-p))，n=10000、p≈0.02093 → σ ≈ 14.3。
/// 3σ ≈ 43。观测频率与 p 的差必须小于 3σ。
test "P(d=1) sampling matches theoretical pmf within 3 sigma" {
  let k = 1000
  let c = 0.1
  let delta = 0.5
  let dist = robust_distribution(k, c, delta)
  let p = dist.pdf(1)
  let n = 10000
  let rng = Ltrng::new(0xC0FFEEUL)
  let mut ones = 0
  for i = 0; i < n; i = i + 1 {
    if sample_degree(rng, k, c, delta) == 1 {
      ones = ones + 1
    }
  }
  let freq = ones.to_double() / n.to_double()
  let sigma = (p * (1.0 - p) / n.to_double()).sqrt()
  let three_sigma = 3.0 * sigma
  let diff = (freq - p).abs()
  if diff > three_sigma {
    println(
      "freq=\{freq} p=\{p} diff=\{diff} 3sigma=\{three_sigma} ones=\{ones}",
    )
  }
  assert_true(diff < three_sigma)
}

///|
/// 采样还必须与完整 pmf 吻合，而不只是 d=1 那一点 ——
/// 只测一个点很容易漏掉「其余度数全错」的实现。
/// 用 K=20（分布只有 20 个桶）做卡方式的粗暴版：每个期望频数 >= 5 的桶，
/// 观测值与期望值的**相对偏差**都必须在 25% 内。200000 次采样下最大的桶
/// 本身已有 σ/μ ≈ 0.1%，25% 是很宽的窗口，但足以抓住「某个度数永不出现」
/// 或「概率表错位」这类整体性错误。
test "degree sampling matches the whole pmf for K=20" {
  let k = 20
  let dist = robust_distribution(k, 0.1, 0.5)
  let n = 200000
  let rng = Ltrng::new(0x5EEDUL)
  let counts : Array[Int32] = Array::make(k + 1, 0)
  for i = 0; i < n; i = i + 1 {
    let d = sample_degree(rng, k, 0.1, 0.5)
    counts[d] = counts[d] + 1
  }
  let mut worst = 0.0
  for d = 1; d <= k; d = d + 1 {
    let want = dist.pdf(d) * n.to_double()
    if want >= 5.0 {
      let ratio = counts[d].to_double() / want
      let dev = (ratio - 1.0).abs()
      if dev > worst {
        worst = dev
      }
    }
  }
  if worst > 0.25 {
    println("worst relative deviation = \{worst}")
  }
  assert_true(worst < 0.25)
}

///|
test "degree distribution boundary K=1" {
  // K=1：唯一可能的度数就是 1
  let dist = robust_distribution(1, 0.1, 0.5)
  let p1 = dist.pdf(1)
  let d1 = p1 - 1.0
  assert_true(d1.abs() < 0.000000000001)
  let rng = Ltrng::new(1UL)
  for i = 0; i < 100; i = i + 1 {
    inspect(sample_degree(rng, 1, 0.1, 0.5), content="1")
  }
}

///|
test "degree distribution boundary K=2" {
  let dist = robust_distribution(2, 0.1, 0.5)
  let mut total = 0.0
  for d = 1; d <= 2; d = d + 1 {
    total = total + dist.pdf(d)
  }
  let err = total - 1.0
  assert_true(err.abs() < 0.000000000001)
  // K=2 时 R = 0.1*ln(4)*sqrt(2) ≈ 0.196；K/R ≈ 10.2 → 区间 1..10 全部
  // 落在 K 之外，τ 只在 d=1..2 内非零（因为 d 不能超过 K）。
  let rng = Ltrng::new(2UL)
  let mut bad = 0
  for i = 0; i < 1000; i = i + 1 {
    let d = sample_degree(rng, 2, 0.1, 0.5)
    if d < 1 || d > 2 {
      bad = bad + 1
    }
  }
  inspect(bad, content="0")
}

///|
test "degree distribution boundary K=3" {
  let dist = robust_distribution(3, 0.1, 0.5)
  let mut total = 0.0
  for d = 1; d <= 3; d = d + 1 {
    total = total + dist.pdf(d)
  }
  let err = total - 1.0
  assert_true(err.abs() < 0.000000000001)
  let rng = Ltrng::new(3UL)
  let mut bad = 0
  for i = 0; i < 1000; i = i + 1 {
    let d = sample_degree(rng, 3, 0.1, 0.5)
    if d < 1 || d > 3 {
      bad = bad + 1
    }
  }
  inspect(bad, content="0")
}

///|
test "fixed degree distribution is deterministic and validated" {
  let dist = fixed_distribution(5, 10)
  let p5 = dist.pdf(5)
  let e5 = p5 - 1.0
  assert_true(e5.abs() < 0.000000000001)
  let p4 = dist.pdf(4)
  assert_true(p4 == 0.0)
  let rng = Ltrng::new(99UL)
  for i = 0; i < 50; i = i + 1 {
    // 固定度分布必须走它自己的 sample —— sample_degree 是「按 c/δ 建
    // 鲁棒孤波再抽一次」的便利入口，不是通用采样器。
    inspect(dist.sample(rng), content="5")
  }
  // 验证 sample_degree 确实是鲁棒孤波：K=10 时它不会恒返回 5
  let rng2 = Ltrng::new(99UL)
  let seen : Array[Bool] = Array::make(11, false)
  for i = 0; i < 200; i = i + 1 {
    seen[sample_degree(rng2, 10, 0.1, 0.5)] = true
  }
  let mut distinct = 0
  for i = 1; i <= 10; i = i + 1 {
    if seen[i] {
      distinct = distinct + 1
    }
  }
  assert_true(distinct > 1)
}

///|
test "distribution validation rejects unnormalized and bad params" {
  // 手工构造一个不归一化的分布，validate 必须报错
  let bad = distribute_from_array(10, [0.1, 0.1])
  let r = validate_distribution(bad)
  inspect(r is Err(_), content="true")
  // 参数非法：K < 1
  let r2 = robust_soliton_checked(0, 0.1, 0.5)
  inspect(r2 is Err(_), content="true")
  let r3 = robust_soliton_checked(10, 0.0, 0.5)
  inspect(r3 is Err(_), content="true")
  let r4 = robust_soliton_checked(10, 0.1, 0.0)
  inspect(r4 is Err(_), content="true")
  let r5 = robust_soliton_checked(10, 0.1, 1.5)
  inspect(r5 is Err(_), content="true")
  // 合法参数
  let ok = robust_soliton_checked(10, 0.1, 0.5)
  inspect(ok is Ok(_), content="true")
}
