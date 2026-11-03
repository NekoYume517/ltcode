///|
/// 度量层测试。
///
/// 这一层最容易自欺：把「成功率」写成抽样一次的结论，或者把「约等于」
/// 写成「等于」。下面每条测试都刻意避开这两个坑。

///|
test "metrics: overhead_ratio is received/K and guards K<=0" {
  assert_eq(overhead_ratio(1000, 1000).to_string(), "1")
  let r = overhead_ratio(1000, 1200) - 1.2
  assert_true(r.abs() < 0.000000000001)
  // K<=0 不除零，返回 0
  assert_eq(overhead_ratio(0, 5).to_string(), "0")
  assert_eq(overhead_ratio(-3, 5).to_string(), "0")
}

///|
test "metrics: received_count floors K*overhead" {
  inspect(received_count(1000, 1.0), content="1000")
  inspect(received_count(1000, 1.2), content="1200")
  inspect(received_count(1000, 1.1), content="1100")
  inspect(received_count(10, 2.0), content="20")
  // 非整除：floor
  inspect(received_count(3, 1.5), content="4")
  // overhead <= 0 → 0
  inspect(received_count(100, 0.0), content="0")
  inspect(received_count(100, -1.0), content="0")
}

///|
test "metrics: round3 keeps three decimals" {
  assert_eq(format_fixed(round3(0.98765), 3), "0.988")
  assert_eq(format_fixed(round3(1.0), 3), "1.000")
  assert_eq(format_fixed(round3(0.0), 3), "0.000")
  // 0.9995 → 1.000（不是 0.999）
  assert_eq(format_fixed(round3(0.9995), 3), "1.000")
}

///|
test "metrics: format_fixed always prints the requested digit count" {
  assert_eq(format_fixed(1.0, 3), "1.000")
  assert_eq(format_fixed(0.5, 3), "0.500")
  assert_eq(format_fixed(0.05, 3), "0.050")
  assert_eq(format_fixed(0.005, 3), "0.005")
  assert_eq(format_fixed(1.2, 2), "1.20")
  assert_eq(format_fixed(1.0, 2), "1.00")
  assert_eq(format_fixed(-0.25, 2), "-0.25")
  assert_eq(format_fixed(123.456, 3), "123.456")
  assert_eq(format_fixed(0.0, 0), "0")
  // 关键：to_string() 会把 1.0 打成 "1"，这正是要避免的
  assert_eq(1.0.to_string(), "1")
}

///|
test "metrics: run_trial is deterministic for a fixed seed" {
  let a = run_trial(50, 1.5, 424242UL, 8, 0.1, 0.5) catch {
    _ => abort("trial raised")
  }
  let b = run_trial(50, 1.5, 424242UL, 8, 0.1, 0.5) catch {
    _ => abort("trial raised")
  }
  assert_eq(a.success, b.success)
  assert_eq(a.received, b.received)
  assert_eq(a.missing, b.missing)
  // 操作计数也应一致（同一条确定性路径）
  assert_eq(a.stats.subset_slots, b.stats.subset_slots)
  assert_eq(a.stats.xor_bytes, b.stats.xor_bytes)
}

///|
test "metrics: run_trial never reports success with wrong data" {
  // 成功必须意味着逐字节一致；失败必须意味着 missing > 0。
  let mut bad = 0
  for s = 0; s < 60; s = s + 1 {
    let out = run_trial(40, 1.3, s.to_uint64() * 7919UL + 1UL, 6, 0.1, 0.5) catch {
      _ => abort("trial raised")
    }
    if out.success && out.missing != 0 {
      bad = bad + 1
    }
    if !out.success && out.missing == 0 {
      bad = bad + 1
    }
  }
  inspect(bad, content="0")
}

///|
test "metrics: decode_success_rate is reproducible across two calls" {
  let a = decode_success_rate(60, 1.2, 20, 9000UL, 5, 0.1, 0.5) catch {
    _ => abort("rate raised")
  }
  let b = decode_success_rate(60, 1.2, 20, 9000UL, 5, 0.1, 0.5) catch {
    _ => abort("rate raised")
  }
  assert_eq(a.successes, b.successes)
  assert_eq(a.trials, 20)
  assert_eq(a.received, 72)
  let d = a.rate - b.rate
  assert_true(d.abs() < 0.000000000001)
}

///|
test "metrics: zero trials gives rate 0, not NaN" {
  let p = decode_success_rate(10, 1.0, 0, 0UL, 4, 0.1, 0.5) catch {
    _ => abort("rate raised")
  }
  inspect(p.trials, content="0")
  inspect(p.successes, content="0")
  assert_eq(format_fixed(p.rate, 3), "0.000")
}

///|
test "metrics: evaluate produces one point per overhead, in order" {
  let pts = evaluate(40, [1.0, 1.2, 1.5], 10, 1234UL, 4, 0.1, 0.5) catch {
    _ => abort("evaluate raised")
  }
  inspect(pts.length(), content="3")
  let d0 = pts[0].overhead - 1.0
  let d1 = pts[1].overhead - 1.2
  let d2 = pts[2].overhead - 1.5
  assert_true(d0.abs() < 0.000000000001)
  assert_true(d1.abs() < 0.000000000001)
  assert_true(d2.abs() < 0.000000000001)
  // 成功率单调性不是硬保证（有限样本会抖），但 1.5 不该比 1.0 差太多
  assert_true(pts[2].rate >= pts[0].rate - 0.2)
}

///|
/// **固定度分布 vs 鲁棒孤波**：证明 τ 那一段不是装饰。
///
/// 固定度 d0 = 5 时，一个编码符号恰含 5 个源符号；剥皮要求某个符号
/// 「恰好剩 1 个未解」—— 这在无结构的情况下也会偶然发生，但**缺少**
/// 度 1 的直给，起步极慢。实测（K=100, overhead 1.5, 20 trials）：
/// 固定度的成功率显著低于鲁棒孤波。
test "metrics: fixed degree distribution is much worse than robust soliton" {
  let k = 100
  let trials = 20
  let seed = 0x5EEDUL
  let fixed = fixed_degree_success_rate(k, 5, 1.5, trials, seed, 4) catch {
    _ => abort("fixed raised")
  }
  let robust = decode_success_rate(k, 1.5, trials, seed, 4, 0.1, 0.5) catch {
    _ => abort("robust raised")
  }
  // 断言方向：固定度 <= 鲁棒孤波。不做「差多少倍」的断言 ——
  // 那会依赖具体小样本，容易变成脆弱测试。
  if fixed.successes > robust.successes {
    println("fixed=\{fixed.successes} robust=\{robust.successes} (unexpected)")
  }
  assert_true(fixed.successes <= robust.successes)
  // 至少一侧要有信息量：鲁棒孤波在 1.5 开销下应该能成功一些
  assert_true(robust.successes > 0)
}

///|
test "metrics: format_curve_point output shape" {
  let p = CurvePoint::{
    overhead: 1.2,
    received: 1200,
    successes: 19,
    trials: 20,
    rate: 0.95,
  }
  inspect(
    format_curve_point(p),
    content="overhead=1.20  received=1200  successes=19/20  rate=0.950",
  )
}

///|
test "metrics: random_sources is deterministic and K*len sized" {
  let a = random_sources(7UL, 5, 3)
  let b = random_sources(7UL, 5, 3)
  inspect(a.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    assert_eq(a[i].length(), 3)
    assert_eq(a[i], b[i])
  }
  // 不同 seed 必须给出不同内容
  let c = random_sources(8UL, 5, 3)
  let mut differs = false
  for i = 0; i < 5; i = i + 1 {
    if a[i] != c[i] {
      differs = true
    }
  }
  assert_true(differs)
}
