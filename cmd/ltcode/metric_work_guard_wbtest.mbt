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
/// 守卫量取 **trials × received**（单点的符号操作总量），上限
/// `LT_MAX_WORK = 10_000_000`：README/DEMO 的全部既有命令每点 ≤ 1e6
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
/// 放行侧：README/DEMO 的全部既有命令（每点 ≤ 1e6 符号操作）不受影响；
/// 上限边界精确（恰好 1e6 放、+1 拒）。注意 K=1e6、trials=1（1.2e6）
/// **也被拒** —— 它是 33 分钟级的单次作业（实测 1961 s 未跑完被杀），
/// 在「最坏合法组合分钟级」的预算之外；要测大 K 就降 overhead 或分批。
test "LT6: documented commands still pass and the boundary is exact" {
  // README 的 curve 点：K=1000、oh=1.2、trials=500 → 6e5
  let a = check_metric_magnitudes(1000, [1.2], 500, 4)
  assert_true(a.is_empty())
  // README 的 distcmp：K=1000、oh=2.0、trials=200 → 4e5
  let b = check_metric_magnitudes(1000, [2.0], 200, 4)
  assert_true(b.is_empty())
  // DEMO 的 simulate：K=1000、oh=1.0、trials=1000 → 1e6（恰在上限）
  let c = check_metric_magnitudes(1000, [1.0], 1000, 4)
  assert_true(c.is_empty())
  // 实测过耗时的组合：K=10000、trials=50、oh=1.2 → 6e5（11.95 s）
  let c2 = check_metric_magnitudes(10000, [1.2], 50, 4)
  assert_true(c2.is_empty())
  // 边界 +1：1000 × 1001 = 1001000 > 1e6 拒
  let d = check_metric_magnitudes(1000, [1.0], 1001, 4)
  assert_true(!d.is_empty())
  // K=1e6、trials=1 → 1.2e6 > 1e6 拒（33 分钟级的单次作业）
  let e = check_metric_magnitudes(1000000, [1.2], 1, 4)
  assert_true(!e.is_empty())
}
