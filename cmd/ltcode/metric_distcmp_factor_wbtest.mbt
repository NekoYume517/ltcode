///|
/// LT14（2026-11-17 审计）：`distcmp` 用同一个 `guard_work` 值实跑约 2×。
///
/// `cmd_distcmp` 的注释写着「它对这几个参数的敏感度是 simulate 的三倍 ——
/// 同一个守卫值在这里尤其不能漏」，但守卫本身没有乘任何系数。实测
/// （release native，同 K=1000 / overhead 1.2 / trials 500）：
///
/// ```text
/// simulate  7627 ms   (单分布)
/// distcmp  14828 ms   (robust + ideal + fixed5，ratio 1.94)
/// ```
///
/// 不是精确 3× 是因为 ideal / fixed 两条路径更便宜（不建鲁棒孤波表、剥皮
/// 更早卡死），但方向与量级都得进预算。这就是 §19.8-4 那条「不可断言的
/// 守卫」：注释里知道要乘，代码里没乘，而唯一可观测的只是墙钟。
///
/// 修法：`guard_work` / `check_metric_magnitudes` 加一个 `dist_factor`
/// 可选参数，`cmd_distcmp` 传 2（保守覆盖实测 1.94×）。默认 1 ⇒
/// simulate / curve 的既有边界逐字不变。
///
/// 红测试先于实现存在：修复前 `dist_factor` 不存在（编译期即红）。
test "LT14: distcmp charges its budget twice (measured 1.94x)" {
  // simulate 的边界：1000 × 2000 = 2e6 恰好放行、2001 符号 +1 拒
  inspect(check_metric_magnitudes(1000, [2.0], 500, 4), content="")
  // distcmp 用同一组参数：单分布口径下 1e6，乘 2 后 2e6 —— 仍放行
  inspect(check_metric_magnitudes_scaled(1000, [2.0], 500, 4, 2), content="")
  // 501 trials：单分布 1.002e6（放行），乘 2 后 2.004e6 → 必须拒
  inspect(check_metric_magnitudes(1000, [2.0], 501, 4), content="")
  let msg = check_metric_magnitudes_scaled(1000, [2.0], 501, 4, 2)
  assert_true(!msg.is_empty())
  // 大字报要点名这份预算是按两份算的（否则用户不知道自己被乘了 2）
  assert_true(msg.contains("2x") || msg.contains("distcmp"))
}

///|
/// DEMO 的三条 `distcmp` 锚点（K=1000、trials 200、overhead 1.2/1.3/1.5）
/// 乘 2 之后仍然在预算内 —— 新增系数不能误伤文档承诺可复现的命令。
test "LT14: documented distcmp commands stay inside the doubled budget" {
  for oh in [1.2, 1.3, 1.5] {
    inspect(check_metric_magnitudes_scaled(1000, [oh], 200, 4, 2), content="")
  }
  // 字节轴也乘 2：symbol_len=4 的文档命令仍是两个数量级余量
  inspect(check_metric_magnitudes_scaled(1000, [1.2], 200, 4, 2), content="")
}
