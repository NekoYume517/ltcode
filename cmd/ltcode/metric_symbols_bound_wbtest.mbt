// ============================================================================
// LT2（2026-11-13 审计）：度量命令的 `--symbols` 没有上界
//
// ## 现象（修复前，真实输出）
//
// `encode` 早就在用法层拦住了 `--symbols` 的上界（LT-K），度量侧却只拦了
// `--trials` / `--symbol-len` / `--overhead`（LT-B），`--symbols` 原封不动
// 直接进库。于是**同一个参数值**在两条命令上走了两条路：
//
//   $ ltcode encode --symbols 1048577 --input f
//   ltcode: --symbols must be <= 1048576 (got 1048577); split the file ...
//   exit 2                                   ← 用法错误（对）
//
//   $ ltcode simulate --symbols 1048577 --overhead 1.0 --trials 1
//   ltcode: simulate failed: source too large: K=1048577 exceeds the limit ...
//   exit 3                                   ← 输入错误（错）
//
// `curve` / `distcmp` 走同一条路，同样 exit 3。三个问题：
//
// 1. **退出码归类错**：`--symbols` 越界是用法错误（2），不是「输入文件非法」（3）。
//    度量命令根本没有输入文件，那个错误文案却说「source too large」。
// 2. **文案把话推给一个不存在的东西**：`simulate` / `curve` / `distcmp`
//    不读任何文件，用户收到的却是一句关于「源」的报错，且没有点名 `--symbols`。
// 3. **量级没有被拦住**：`guard_overhead` 的守卫量是 `K × overhead`（收到的
//    符号数），K 本身无上界，于是「极小 overhead + 巨大 K」能绕开它；
//    `run_trial` 又先跑 `random_sources(k)` 的 k 次分配（**在**
//    `SourceBlock::new` 的 K 检查**之前**）—— 实测 `--symbols 20000000`
//    （overhead 1e-5，received 只有 200）已经要 2.4 s，内存随 K 线性，
//    K=2³¹−1 是分钟级、几十 GB 级。
//
// ## 为什么这条能长期不被发现（修法的一半）
//
// `check_metric_magnitudes` 原本是「打印 + 返回 Bool」，它的文案**不可断言**
// —— 唯一可观测的东西是「进程退出了没有」。度量侧四条守卫里三条
// （`guard_trials` / `guard_symbol_len` / `guard_overhead`）都能逐字断言，
// 唯一不可断言的那一条，正是漏掉 K 上界的那一条。现在它与本文件其余守卫
// 同形状（`空串 = 放行`），于是每一条都能像 `guard_trials` 一样被断言。
//
// 红/绿：阶段 1 用旧签名断言「越界必须被拒」→ 红在**行为**
// （`true` is not false，`LT2-red.log`）；改成返回文案后本条逐字锁定文案转绿。
// 真实 CLI 的修复前证据见 `LT2-pre.log` / `LT2-post.log`。
// ============================================================================

///|
/// 核心：越界的 `--symbols` 必须在**量级守卫**这一层就被拒，且文案点名
/// `--symbols` + 上界，不把话推给「源」或输入文件。
test "LT2: metric commands reject --symbols above max_source_symbols" {
  let limit = @lib.max_source_symbols()
  // 域内（含边界）静默。注意域内 ≠ 一律放行：量级由 LT6 的乘积守卫
  // （trials × received ≤ LT_MAX_WORK）另管 —— K=limit、oh=1.0、trials=1
  // 的组合（work = 1048576 > 1e6）现在由 guard_work 拒，这里放行侧取
  // 乘积内的等价组合锁「K 到达上界本身不是用法错误」。
  inspect(check_metric_magnitudes(1, [1.0], 1, 4), content="")
  let under_work = (limit.to_double() * 0.9).to_int()
  inspect(check_metric_magnitudes(limit, [0.9], 1, 4), content="")
  assert_true(under_work <= 2000000)
  inspect(check_metric_magnitudes(1000, [1.0, 1.2, 1.5], 500, 40), content="")
  // 越界：必须非空，且点名 `--symbols`、带上界与用户给的值
  let over = check_metric_magnitudes(limit + 1, [1.0], 1, 4)
  assert_true(!over.is_empty())
  assert_true(over.contains("--symbols"))
  assert_true(over.contains("\{limit}"))
  assert_true(over.contains("\{limit + 1}"))
  // 不能说自己「源太大」/「切不开输入」—— 那两句属于 encode 的输入侧
  assert_true(!over.contains("source too large"))
  assert_true(!over.contains("input"))
  // 与 encode 同域：Int32 上限也走这一条，而不是留给库里的 SourceTooLarge
  assert_true(!check_metric_magnitudes(2147483647, [1.0], 1, 4).is_empty())
  // 文案里给出的下一步必须是**度量命令真能做的**那件事
  assert_true(over.contains("--overhead"))
}

///|
/// 否决顺序：K 越界时**先**说 K。用户改一次就能看到进展，而不是先被
/// `--overhead` / `--trials` 的文案引开再撞回来。
///
/// 断言用**同一性**而不是「不含某个词」：K 那条文案本身就会建议
/// `raise --overhead instead`，所以「不含 --overhead」是错的判据 ——
/// 这正好也是「断言要避开同名子串」那个老坑的又一次提醒。
test "LT2: the K bound is reported before the other metric bounds" {
  let limit = @lib.max_source_symbols()
  let msg = check_metric_magnitudes(
    limit + 1,
    [2500000.0],
    2147483647,
    2000000000,
  )
  assert_eq(msg, metric_symbols_bound_msg(limit + 1))
  assert_true(!msg.contains("--trials"))
  assert_true(!msg.contains("--symbol-len"))
}

///|
/// 其余三条守卫的行为**不变**（LT-B 的回归仍在同一条路径上）：
/// 空串 = 放行，非空 = 拒绝。
test "LT2: the other three metric bounds keep working through the same helper" {
  inspect(check_metric_magnitudes(1000, [1.0], 100, 4), content="")
  assert_true(
    check_metric_magnitudes(1000, [1.0], 2147483647, 4).contains("--trials"),
  )
  assert_true(
    check_metric_magnitudes(1000, [1.0], 100, 2000000000).contains(
      "--symbol-len",
    ),
  )
  assert_true(
    check_metric_magnitudes(1000, [2500000.0], 100, 4).contains("--overhead"),
  )
  // `curve` 一次给多个 overhead：任意一个越界都要拒（逐个查，不是只看第一个）
  assert_true(
    check_metric_magnitudes(1000, [1.0, 2500000.0], 10, 4).contains(
      "--overhead",
    ),
  )
  // 非有限值同样在这条路径上被挡（参数层已有一道，这里是库层入口）
  let nan = 0.0 / 0.0
  assert_true(
    check_metric_magnitudes(1000, [nan], 10, 4).contains("--overhead"),
  )
}
