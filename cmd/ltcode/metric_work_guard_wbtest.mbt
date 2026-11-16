/// LT6（2026-11-15 审计）：`--trials × --received` 的乘积没有守卫。
///
/// LT-B 给了三个独立上限（trials ≤ 1e7、received = K×overhead ≤ 4e6、
/// symbol-len ≤ 1MB），但**乘积**没有：每个参数都在域内时，
/// `simulate --symbols 1000000 --overhead 1.2 --trials 10` 要求
/// `10 × 1.2e6 = 1.2e7` 次符号操作 —— 实测（release native）
/// K=1e5/trials=5（6e5 符号）要 129 s 且成本随 K 超线性增长
/// （K=1e6 单 trial 600 s 量级），1.2e7 是小时级挂死。K=1000、
/// trials=1e7（ trials 上限的合法值）同样外推出 ~20 小时。
///
/// 守卫量取 **trials × max(K, received)**（LT7 补入每轮 O(K) 初始化），上限
/// `LT_MAX_WORK = 2_000_000`：README/DEMO 的全部既有命令每点 ≤ 1.2e6
/// （放行有余量），最坏合法组合（K=1e6、trials=1）≈ 1.2e6 仍是分钟级
/// 而不是天级。文案与 `guard_overhead` 同形状（可断言，不只打印）。
///
/// 红测试先于实现存在：修复前 `check_metric_magnitudes` 对这些组合
/// 全部放行（返回空串）。

///|
/// 域内参数的爆炸组合必须被守卫拦下（LT6 的行为断言）。
test "LT6: trials x received above the work limit is rejected" {
  // K=1e6（= max_source_symbols）、overhead 1.2 → received 1.2e6；
  // trials 10 → 1.2e7 符号操作，实测小时级。
  let msg = check_metric_magnitudes(1000000, [1.2], 10, 4)
  assert_true(!msg.is_empty())
}

///|
/// K=1000 + trials=1e7（各自都在 LT-B 域内）也是 20 小时级，必须拦。
test "LT6: trials at its own limit with modest K is still rejected" {
  let msg = check_metric_magnitudes(1000, [1.2], 10000000, 4)
  assert_true(!msg.is_empty())
}

///|
/// 放行侧：README/DEMO 的全部既有命令必须继续可复现。锚点是 README
/// 「PLAN 要求」的那条 `simulate --symbols 1000 --overhead 1.2 --trials
/// 1000`（= 1.2e6，文档承诺 793/1000）—— 上限因此取 2e6 而不是 1e6
/// （1e6 会把这条文档命令误伤成 exit 2）。边界精确：恰好 2e6 放、+1 拒。
test "LT6: documented commands still pass and the boundary is exact" {
  // README 的 curve 点：K=1000、oh=1.2、trials=500 → 6e5
  let a = check_metric_magnitudes(1000, [1.2], 500, 4)
  assert_true(a.is_empty())
  // README 的 distcmp：K=1000、oh=2.0、trials=200 → 4e5
  let b = check_metric_magnitudes(1000, [2.0], 200, 4)
  assert_true(b.is_empty())
  // README 的 simulate（PLAN 锚点）：K=1000、oh=1.2、trials=1000 → 1.2e6
  let c = check_metric_magnitudes(1000, [1.2], 1000, 4)
  assert_true(c.is_empty())
  // DEMO 的 simulate：K=1000、oh=1.0、trials=1000 → 1e6
  let c2 = check_metric_magnitudes(1000, [1.0], 1000, 4)
  assert_true(c2.is_empty())
  // 单次大 K：K=1e6、trials=1 → 1.2e6 放行（33 分钟级，域内合法度量）
  let e = check_metric_magnitudes(1000000, [1.2], 1, 4)
  assert_true(e.is_empty())
  // 边界：恰好 2e6 放（K=1000、oh=2.0、trials=1000）
  let f = check_metric_magnitudes(1000, [2.0], 1000, 4)
  assert_true(f.is_empty())
  // 边界 +1：2002000 > 2e6 拒
  let d = check_metric_magnitudes(1000, [2.0], 1001, 4)
  assert_true(!d.is_empty())
}

///|
/// LT7：received=0 不等于零成本。每个 trial 仍生成 K 个源符号并构造
/// 编解码两侧的 O(K) 分布表；只算 trials×received 会把这部分记成零。
test "LT7: zero received still spends trials times K setup work" {
  // received=floor(1000×0.0001)=0，旧守卫的 work=0，因而放行 1e7 次
  // O(K) 初始化。release 实测 5000 trials=2.876s，此外推约 1.6 小时。
  let msg = check_metric_magnitudes(1000, [0.0001], 10000000, 4)
  assert_true(!msg.is_empty())
}

///|
/// 小数 received 也有同族的固定成本；上界按 trials×max(K,received) 精确判定。
test "LT7: fractional received boundary accounts for per-trial setup" {
  // K=1000、received=500：恰好 2000 trials 是 2e6，放行。
  let at_limit = check_metric_magnitudes(1000, [0.5], 2000, 4)
  assert_true(at_limit.is_empty())
  // 旧守卫只算 2001×500=1.0005e6，会错误放行；固定成本是 2.001e6。
  let above_limit = check_metric_magnitudes(1000, [0.5], 2001, 4)
  assert_true(!above_limit.is_empty())
}

///|
/// 预算公式改变不得误伤 README/DEMO 已承诺可复现的全部度量锚点。
test "LT7: every documented metric command remains inside the work budget" {
  for oh in [1.0, 1.1, 1.15, 1.18, 1.2, 1.25, 1.3, 1.5, 2.0] {
    let msg = check_metric_magnitudes(1000, [oh], 500, 4)
    assert_true(msg.is_empty())
  }
  for oh in [1.0, 1.2] {
    let msg = check_metric_magnitudes(1000, [oh], 1000, 4)
    assert_true(msg.is_empty())
  }
  for oh in [1.2, 1.3, 1.5] {
    let msg = check_metric_magnitudes(1000, [oh], 200, 4)
    assert_true(msg.is_empty())
  }
}
