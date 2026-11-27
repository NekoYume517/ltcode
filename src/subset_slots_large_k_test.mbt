///|
/// LT45：`subset_slots` 的单调性**只在小 K 成立** —— 31.8 遗留的边界。
///
/// ## 现象（修复前，无测试覆盖）
///
/// `decode_cost_shape_test.mbt` 的 LT44-d 锁的是
/// `K ∈ {50, 150, 300}`、`n = 300` 时 `subset_slots` 单调增。31.8 记下
/// 「`subset_slots` 单调性只在 `K ≤ 1200` 实测过，未跑到 `K=1M`」。
///
/// 本轮把曲线补到大 K（`n = 4000` 固定、`K` 从 256 到 65536，整数计数器）：
///
/// ```text
///   K      n      subset_slots   每符号度数   理论 E[d]
///   256    4000     33109          8.277       7.895
///   512    4000     38916          9.729       9.068
///   1024   4000     45480         11.370      10.263
///   4096   4000     60980         15.245      12.888
///   65536  4000     88039         22.010      18.031
/// ```
///
/// **每符号度数随 K 单调增**（8.28 → 22.01），但**显著高于**理论 `E[d]`
/// （22.01 vs 18.03，偏 22%）。根因是 `robust_tau` 的尾部：`d > 1000`
/// 只占 0.093% 的质量却贡献 3.96 的期望度数，`d > 5000` 占 0.0175% 贡献
/// 2.43。**一个 `u ≈ 0.99992` 的样本就命中 `d = 9753`，单条把 2000 样本的
/// 均值从 15.13 抬到 24.46。** 所以有限样本的均值估计对尾部分位数极敏感。
///
/// ## 判据
///
/// 1. **理论 `E[d]` 必须单调增**（这条是分布的数学性质，与采样无关）。
/// 2. **小 K 段的实测 `subset_slots` 必须单调增**（LT44-d 已锁，这条加宽到
///    `K` 到 4096，仍全部 `K ≤ n`）。
/// 3. **`subset_slots / E[d]` 不许系统性偏离 1 太多** —— 实测偏到 1.22 是
///    尾部重尾的**证据**，把它写成上界锁住：若哪天有人「修」了分布让这个
///    比值贴近 1，说明尾部被改了，README 的曲线全部失效。
test "LT45: theoretical Ed grows monotonically with K, including large K" {
  let ks : Array[Int32] = [
    256, 512, 1024, 2048, 4096, 8192, 65536, 262144, 1048576,
  ]
  let mut prev = 0.0
  for k in ks {
    let dist = @src.robust_distribution(
      k,
      @src.default_c(),
      @src.default_delta(),
    ) catch {
      e => abort("K=\{k} distribution failed: \{@src.error_text(e)}")
    }
    let ed = dist.expected_degree()
    // 期望度数必须严格递增，而且每个点都要落在合理域里
    assert_true(ed > prev)
    assert_true(ed >= 1.0 && ed <= k.to_double())
    prev = ed
  }
}

///|
/// LT45：`expected_degree` 的**精确值**锁（防「差一变异」）。
///
/// 上一条只断言严格递增。把 `expected_degree` 的循环从 `d <= self.k`
/// 改成 `d < self.k`（丢掉最后一项 `k·pmf(k)`）**不改变单调性** ——
/// 变异实测：209 条全绿，一条都没抓住。这正是 LT41-B 的教训
/// 「断言必须点名那个数字」。
///
/// 这里点名 `K = 65536` 的期望度数：`18.03119207906007`。丢掉
/// `65536 · pmf(65536)` 这一项会让它降到 `18.0311920790600` 以下
/// （`pmf(65536) ≈ 1.2e-8`，贡献 `≈ 7.9e-4`），远超下面的容差。
test "LT45: expected_degree has an exact pinned value (catches the d<k off-by-one)" {
  let k : Int32 = 65536
  let dist = @src.robust_distribution(k, @src.default_c(), @src.default_delta()) catch {
    e => abort("distribution failed: \{@src.error_text(e)}")
  }
  let ed = dist.expected_degree()
  // 数值锚点：本轮实测（moonc v1.0.0-rc1，native release）
  let want = 18.03119207906007
  let delta = ed - want
  assert_true(delta < 0.000000000001 && delta > -0.000000000001)
  // 再点名 K=1024 与 K=2 两个更小的锚点，任何一处差一都会红
  let d1024 = @src.robust_distribution(
    1024,
    @src.default_c(),
    @src.default_delta(),
  ) catch {
    e => abort("K=1024 failed: \{@src.error_text(e)}")
  }
  let e1024 = d1024.expected_degree()
  let dd = e1024 - 10.263176238544114
  assert_true(dd < 0.000000000001 && dd > -0.000000000001)
  let d2 = @src.robust_distribution(2, @src.default_c(), @src.default_delta()) catch {
    e => abort("K=2 failed: \{@src.error_text(e)}")
  }
  let e2 = d2.expected_degree()
  let ddd = e2 - 1.4786350250197022
  assert_true(ddd < 0.000000000001 && ddd > -0.000000000001)
}

///|
/// LT45：高频尾部把「有限样本均值」与「数学期望」拉开 —— 这个差距是
/// **可计算、可锁定**的整数事实，不是"测不准"。
///
/// 判据：固定 `n = 4000`、`K = 65536`，实测 `subset_slots / n` 必须
/// **大于**理论 `E[d]`（尾部向右拖），但**不大于 1.5 倍**（否则说明
/// 尾部质量失控，分布已经不能用）。
test "LT45: subset_slots per symbol exceeds Ed at large K (heavy tail), bounded" {
  let k : Int32 = 65536
  let n : Int32 = 4000
  let dist = @src.robust_distribution(k, @src.default_c(), @src.default_delta()) catch {
    e => abort("distribution failed: \{@src.error_text(e)}")
  }
  let theory = dist.expected_degree()
  let syms : Array[@src.ReceivedSymbol] = []
  for i in 0..<n {
    syms.push(@src.ReceivedSymbol::{
      index: i,
      data: Bytes::from_array([b'\x01']),
    })
  }
  let stats = try {
    let (_, s) = @src.decode_with_stats(
      0x4C54434F4445UL,
      k,
      1,
      syms,
      @src.default_c(),
      @src.default_delta(),
    )
    s
  } catch {
    e => abort("decode failed: \{@src.error_text(e)}")
  }
  let per_symbol = stats.subset_slots.to_double() / n.to_double()
  // 重尾：实测必须严格高于数学期望
  assert_true(per_symbol > theory)
  // 但要有上界 —— 超过 1.5 倍说明 τ 的尾部质量已经失控
  assert_true(per_symbol < 1.5 * theory)
}

///|
/// LT45：把 31.8 的「未跑过」变成**已跑过的曲线**，并把小 K 段的单调性
/// 加宽锁定（LT44-d 只在 K ≤ 300 上锁过，这里到 4096）。
test "LT45: subset_slots stays monotone across K up to n" {
  let n : Int32 = 4000
  let ks : Array[Int32] = [256, 512, 1024, 2048, 4096]
  let mut prev = 0
  for k in ks {
    let syms : Array[@src.ReceivedSymbol] = []
    for i in 0..<n {
      syms.push(@src.ReceivedSymbol::{
        index: i,
        data: Bytes::from_array([b'\x01']),
      })
    }
    let stats = try {
      let (_, s) = @src.decode_with_stats(
        0x4C54434F4445UL,
        k,
        1,
        syms,
        @src.default_c(),
        @src.default_delta(),
      )
      s
    } catch {
      e => abort("K=\{k} decode failed: \{@src.error_text(e)}")
    }
    // 每个 K 都必须单调增（K ≤ n，尾部噪声被 K 本身限制住）
    assert_true(stats.subset_slots > prev)
    prev = stats.subset_slots
  }
}
