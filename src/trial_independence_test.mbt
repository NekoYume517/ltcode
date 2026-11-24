///|
/// 度量可信度回归锁（LT36，2026-11-24 审计）。
///
/// ## 为什么补这三条
///
/// `src/encoder.mbt` 的 `symbol_rng` 注释里写着本项目**最恶性**的一条历史缺陷：
/// 早期用 `splitmix64(seed ^ index)` 派生每个符号的 PRNG，于是相邻种子的试验
/// 高度相关，10 个「独立」的 200 次试验块之间标准差实测 **0.350**，而二项分布
/// 只允许 **0.034** —— 当时量到 overhead=1.2 的成功率 1.000 是假象
/// （`docs/implementation.md` 第 5 节）。
///
/// 那条缺陷只写在注释与文档里，**没有任何测试锁住它**：`distribution_test`
/// 锁的是 pmf 频率、`independent_sweep_test` 锁的是「过载下逐字节解码」，
/// 都抓不住「试验之间不独立」。而这类缺陷的破坏方式恰恰是「所有别的测试都
/// 更绿」。因此补三条，分别锁不同环节：
///
/// 1. **逐次重算**：`decode_success_rate` 的 `successes` 必须等于用
///    `run_trial(k, oh, seed + t, …)` 逐次重算出来的成功数。这条把「聚合
///    循环用的种子步长」和「聚合口径」钉死 —— 两者任何一处漂移（步长 2、
///    种子重复、只信标签不逐字节核对）都会让它红。
/// 2. **块间方差**：10 个不相交种子窗口的块间标准差必须落在二项噪声内。
///    这条**经变异验证**：把 `symbol_rng` 换回旧的
///    `splitmix64(seed ^ index)`，它立刻红（实测 sd 远超 3σ 上界）；
///    换回新写法即绿。
/// 3. **`rate` 不许是编出来的**：`rate` 必须等于 `round3(successes / trials)`，
///    且同一参数两次调用逐位相同。
///
/// 三条都不依赖墙钟：种子写死，结果逐位可复现。
test "LT36: 聚合成功率等于逐次 run_trial 的重算（含种子步长）" {
  let k = 48
  let overhead = 1.3
  let trials = 24
  let seed = 777UL
  let point = @src.decode_success_rate(
    k,
    overhead,
    trials,
    seed,
    1,
    @src.default_c(),
    @src.default_delta(),
  ) catch {
    e => abort("decode_success_rate failed: \{@src.error_text(e)}")
  }
  // 参考实现：直接按「试验 t 用种子 seed + t」逐次跑，不复用聚合里的任何代码
  let mut recomputed = 0
  for t = 0; t < trials; t = t + 1 {
    let out = @src.run_trial(
      k,
      overhead,
      seed + t.to_uint64(),
      1,
      @src.default_c(),
      @src.default_delta(),
    ) catch {
      e => abort("run_trial failed: \{@src.error_text(e)}")
    }
    if out.success {
      recomputed = recomputed + 1
    }
  }
  assert_eq(point.successes, recomputed)
  assert_eq(point.trials, trials)
  assert_eq(point.received, @src.received_count(k, overhead))
  // 这一档参数下成功率既不是 0 也不是 1，才说明比对有区分度
  assert_true(recomputed > 0 && recomputed < trials)
}

///|
/// 统计级：10 个不相交种子窗口、每块 100 次试验的块间标准差必须落在二项
/// 噪声里。旧写法（`splitmix64(seed ^ index)`）在同类参数上量到 0.350 ——
/// 用变异测试确认过：换回旧写法这条立刻红。
///
/// 当前实现实测 sd = 0.0195，二项 3σ 上界 0.0846（p ≈ 0.085、n = 100）。
test "LT36: 10 个种子块的块间标准差在二项噪声内" {
  let k = 64
  let overhead = 1.2
  let per_block = 100
  let blocks : Array[Double] = []
  for b = 0; b < 10; b = b + 1 {
    let base = (b * 100_000).to_uint64()
    let point = @src.decode_success_rate(
      k,
      overhead,
      per_block,
      base,
      1,
      @src.default_c(),
      @src.default_delta(),
    ) catch {
      e => abort("decode_success_rate failed: \{@src.error_text(e)}")
    }
    blocks.push(point.rate)
  }
  // 合并成功率与二项标准差（用合并值做 σ 的估计）
  let mut sum = 0.0
  for r in blocks {
    sum = sum + r
  }
  let mean = sum / blocks.length().to_double()
  let mut var_sum = 0.0
  for r in blocks {
    var_sum = var_sum + (r - mean) * (r - mean)
  }
  // 样本标准差（n-1 分母）
  let sd = (var_sum / (blocks.length() - 1).to_double()).sqrt()
  let sigma_binom = (mean * (1.0 - mean) / per_block.to_double()).sqrt()
  // 10 个样本的标准差自身带抽样噪声：用 3 倍 σ 作上界（旧写法 0.350 是它的 4 倍）
  let bound = 3.0 * sigma_binom
  inspect(sd < bound, content="true")
  // 不许「块全是 1.000 或全是 0.000」这种退化 —— 那正是假 1.000 的形状
  assert_true(mean > 0.0 && mean < 1.0)
  inspect(sd > 0.0, content="true")
}

///|
/// `rate` 是 `successes / trials` 的四舍五入，不是另算的一个数；同一参数
/// 两次调用逐位相同（度量里不许有隐藏状态）。
test "LT36: rate 与 successes 自洽，且同一参数两次调用逐位相同" {
  let k = 32
  let overhead = 1.35
  let trials = 40
  let a = @src.decode_success_rate(
    k,
    overhead,
    trials,
    424242UL,
    2,
    @src.default_c(),
    @src.default_delta(),
  ) catch {
    e => abort("decode_success_rate failed: \{@src.error_text(e)}")
  }
  let b = @src.decode_success_rate(
    k,
    overhead,
    trials,
    424242UL,
    2,
    @src.default_c(),
    @src.default_delta(),
  ) catch {
    e => abort("decode_success_rate failed: \{@src.error_text(e)}")
  }
  assert_eq(a.successes, b.successes)
  assert_eq(a.trials, b.trials)
  assert_eq(a.received, b.received)
  inspect(a.rate == b.rate, content="true")
  inspect(
    a.rate == @src.round3(a.successes.to_double() / a.trials.to_double()),
    content="true",
  )
}
