///|
/// LT8（2026-11-17 审计）：工作量预算漏了**字节轴** `--symbol-len`。
///
/// 修复前 `guard_work` 守的是 `trials × max(K, received)`（LT7 的符号级代
/// 理量），而每个「符号操作」实际要处理 `symbol_len` 个字节：
/// `random_sources` 每字节一次 `next_below(256)`，`peel` 的 `acc` 每个收到
/// 符号一份 `symbol_len`，XOR 消去是 `symbol_len` 字节的寄存器级拷贝。
///
/// 于是三个轴各自都在域内、乘积却可以到 `2e6 × 1 MB = 2 TB`：
///
/// ```text
/// simulate --symbols 100 --overhead 1.2 --trials 16666 --symbol-len 1048576
/// ```
///
/// 四个守卫全部放行（`trials=16667` 才被 ops 轴拦下），而 release native
/// 实测单 trial 2.9 s（`symbol-len` 阶梯 4/1024/16384/65536 = 309/127/985/
/// 3481 ms 近线性）→ 16666 trials 外推 **13.4 小时**不退出。
///
/// 修法：同一份预算加第二条轴，单位是「字节级符号操作」
/// `trials × max(K, received) × symbol_len ≤ LT_MAX_WORK_BYTES`。
/// 两条轴各自成文、各自可断言；符号轴保持 `2e6` 不变（README/DEMO 的全部
/// 锚点都是 `symbol_len=4`，所以字节轴对这些命令只剩 4e6~5e7，离上限还有
/// 两个数量级）。
///
/// 红测试先于实现存在：修复前第 1、2 条断言全红（`check_metric_magnitudes`
/// 返回空串 = 放行）。
test "LT8: a 13-hour combination at max symbol-len is rejected" {
  // K=100、overhead 1.2 → received 120；trials=16666 → ops 轴恰好
  // 1.99992e6 <= 2e6（放行），字节轴 2.1e12（必须被拦）。
  let msg = check_metric_magnitudes(100, [1.2], 16666, 1048576)
  assert_true(!msg.is_empty())
  // 文案必须点名 `--symbol-len`（用户要改的是它，不是 K）
  assert_true(msg.contains("--symbol-len"))
}

///|
/// 同一个 (K, overhead, trials) 在默认 `symbol-len=4` 下必须**继续放行**：
/// LT8 的字节轴不能把符号轴的既有边界顺手收窄。
test "LT8: the same trials at the default symbol length still pass" {
  inspect(check_metric_magnitudes(100, [1.2], 16666, 4), content="")
  inspect(check_metric_magnitudes(1000, [1.2], 1000, 4), content="")
}

///|
/// 不误伤：`symbol_len = 1 MB` 本身是合法值，小规模组合（实测 2.9 s/trial）
/// 必须放行。守卫量是**乘积**，不是任何单个因子。
test "LT8: max symbol-len at one trial is not over-blocked" {
  inspect(check_metric_magnitudes(100, [1.2], 1, 1048576), content="")
  // 边界（LT32 起含平均度上界）：K=100 → degree 上界 11，per_trial=120 →
  // 每 trial 120 × 1048576 × 11 = 1.384e9 真实字节。
  // 4 trials = 5.53e9 <= 6e9 放行（实测 ≈ 11.6 s，与 2.9 s/trial 相符），
  // 5 trials = 6.92e9 拒。
  inspect(check_metric_magnitudes(100, [1.2], 4, 1048576), content="")
  assert_true(!check_metric_magnitudes(100, [1.2], 5, 1048576).is_empty())
}

///|
/// README / DEMO / API.md 里出现的每条度量命令都必须继续可复现（逐条代进
/// `check_metric_magnitudes`）。这是 LT6 那条教训（阈值靠文档锚点校准）的
/// 回归：新增一条轴时最容易顺手把文档命令判死。
test "LT8: every documented metric command stays inside the byte budget" {
  // README「实测成功率」：curve 9 点 × trials 100（省略 = 100）
  let readme_curve = [1.0, 1.1, 1.15, 1.18, 1.2, 1.25, 1.3, 1.5, 2.0]
  inspect(check_metric_magnitudes(1000, readme_curve, 100, 4), content="")
  // DEMO 同一条 curve 加 --trials 500
  inspect(check_metric_magnitudes(1000, readme_curve, 500, 4), content="")
  // DEMO「种子基准不影响结论」：3 点 × 500
  inspect(check_metric_magnitudes(1000, [1.18, 1.2, 1.25], 500, 4), content="")
  // README「度量」小节：4 点 × 500
  inspect(
    check_metric_magnitudes(1000, [1.0, 1.15, 1.2, 1.3], 500, 4),
    content="",
  )
  // DEMO 的两条 simulate 锚点
  inspect(check_metric_magnitudes(1000, [1.0], 1000, 4), content="")
  inspect(check_metric_magnitudes(1000, [1.2], 1000, 4), content="")
  // DEMO 的三条 distcmp 锚点
  for oh in [1.2, 1.3, 1.5] {
    inspect(check_metric_magnitudes(1000, [oh], 200, 4), content="")
  }
  // PLAN.md §7 的样本量命令
  inspect(check_metric_magnitudes(1000, [1.2], 100, 4), content="")
}
