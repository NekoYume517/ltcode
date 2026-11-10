// LT-B（2026-11-10 对抗审计，P1）：--overhead / --overheads / --trials /
// --symbol-len 无量级上限（LC-1 同类挂死复活）。
//
// ## 缺陷形态（修复前）
//
// LC-1 只给 `encode --count` 加了 LT_MAX_COUNT，度量侧的参数原封不动：
//
//     ltcode simulate --symbols 1000 --overhead 2500000 --trials 1     → 40s 挂死
//     ltcode simulate --symbols 1000 --overhead 1e300 --trials 1       → 同上
//     ltcode simulate --symbols 10 --overhead 1.2 --trials 2147483647  → 同上
//     ltcode simulate --symbols 10 --overhead 1.2 --trials 1 \
//                     --symbol-len 2000000000                          → 60s 挂死
//     curve / distcmp 走同一路径，同样挂死
//
// 根因两处：
//
// 1. `received_count(k, overhead)` 无上限：`(k * overhead).to_int()` 对
//    2.5e9 与 1e300 都**饱和**到 2147483647，随后 `run_trial` 进
//    `for i = 0; i < count` 的逐符号编码循环（度分布采样 + GF(256) XOR），
//    永不终止。
// 2. `trials` / `symbol_len` 没有上限：前者是同一个循环的次数，后者是
//    **每次** `FixedArray::make(symbol_len, …)` 的分配量级。
//
// 与 LC-1 是同一类问题（量级，不是溢出），因此修法对称：pub 常量 +
// 守卫函数 + CLI 报用法错误 exit 2，文案带上限值。

///|
/// 上限常量必须**可用**：拒绝巨大值，但不阻挡合理请求。
test "LT-B: metric guard constants admit real workloads and reject absurd ones" {
  assert_true(LT_MAX_TRIALS > 0)
  assert_true(LT_MAX_TRIALS < 2147483647)
  assert_true(LT_MAX_RECEIVED > 0)
  assert_true(LT_MAX_RECEIVED < 2147483647)
  assert_true(LT_MAX_SYMBOL_LEN > 0)
  assert_true(LT_MAX_SYMBOL_LEN < 2147483647)
  // README 的实测参数必须在域内
  assert_true(1000 <= LT_MAX_TRIALS) // curve --trials 500 / simulate 1000
  assert_true(LT_MAX_SYMBOL_LEN >= 40) // README 的 symbol_len=40
}

///|
/// 守卫的**接口约定**：返回空串 = 放行，非空 = 拒绝且文本可直接当用法
/// 错误打印。与 `encode_note` 同形状（调用点只想 `if !msg.is_empty()`）。
test "LT-B: guards signal acceptance with an empty string" {
  inspect(guard_trials(100), content="")
  inspect(guard_overhead(1000, 1.2), content="")
  inspect(guard_symbol_len(4), content="")
  assert_true(!guard_trials(2147483647).is_empty())
  assert_true(!guard_overhead(1000, 2500000.0).is_empty())
  assert_true(!guard_symbol_len(2000000000).is_empty())
}

///|
/// `--overhead` 守卫挡住实测挂死的那两个值，文案带上限。
test "LT-B: overhead guard rejects the values that hang, with the limit in the text" {
  let huge = guard_overhead(1000, 2500000.0)
  assert_true(!huge.is_empty())
  assert_true(huge.contains("4000000"))
  assert_true(huge.contains("overhead"))
  // 1e300（注意：不能写成科学计数法字面量，MoonBit 不支持）
  let astronomic = 10.0 * 10.0 * 10.0
  let mut scale = astronomic
  for _i = 0; _i < 99; _i = _i + 1 {
    scale = scale * 10.0
  }
  let huge2 = guard_overhead(1000, scale)
  assert_true(!huge2.is_empty())
  assert_true(huge2.contains("overhead"))
  // K 到上限、overhead 4.0：1048576 × 4 = 4194304 > 4000000
  assert_true(!guard_overhead(1048576, 4.0).is_empty())
  // 合理值必须放行：README 的整条曲线
  for oh in [1.0, 1.05, 1.1, 1.15, 1.18, 1.2, 1.25, 1.3, 1.5, 2.0, 3.0, 3.5] {
    inspect(guard_overhead(1000, oh), content="")
  }
}

///|
/// `--trials` 的量级：`2147483647` 是实测挂死的那个值。
test "LT-B: trials guard rejects 2147483647 and admits the documented sizes" {
  let huge = guard_trials(2147483647)
  assert_true(!huge.is_empty())
  assert_true(huge.contains("10000000"))
  assert_true(huge.contains("trials"))
  assert_true(!guard_trials(LT_MAX_TRIALS + 1).is_empty())
  // 边界本身合法
  inspect(guard_trials(LT_MAX_TRIALS), content="")
  inspect(guard_trials(1), content="")
  inspect(guard_trials(200), content="")
  inspect(guard_trials(500), content="")
  inspect(guard_trials(1000), content="")
}

///|
/// `--symbol-len` 的量级：`2000000000` 是实测挂死的那个值。
test "LT-B: symbol-len guard rejects 2000000000 and admits ordinary symbols" {
  let huge = guard_symbol_len(2000000000)
  assert_true(!huge.is_empty())
  assert_true(huge.contains("1048576"))
  assert_true(huge.contains("symbol-len"))
  assert_true(!guard_symbol_len(LT_MAX_SYMBOL_LEN + 1).is_empty())
  inspect(guard_symbol_len(1), content="")
  inspect(guard_symbol_len(4), content="")
  inspect(guard_symbol_len(40), content="")
  inspect(guard_symbol_len(1024), content="")
  inspect(guard_symbol_len(LT_MAX_SYMBOL_LEN), content="")
}

///|
/// **守卫与 received_count 的一致性**：守卫放行的每个 overhead，其
/// `received_count` 都必须 ≤ LT_MAX_RECEIVED。
///
/// 修复前 `received_count(1000, 2500000.0)` = 2147483647，于是 `run_trial`
/// 进 21 亿次的编码循环。`received_count` 本身仍不设上限（它是纯函数，
/// 不该夹带策略），策略在 CLI 层 —— 这条锁定两层看到的是同一个数。
test "LT-B: every overhead the guard admits yields received <= LT_MAX_RECEIVED" {
  let k = 1000
  for oh in [1.0, 1.2, 1.5, 2.0, 3.0, 3.99] {
    inspect(guard_overhead(k, oh), content="")
    let n = @lib.received_count(k, oh)
    assert_true(n <= LT_MAX_RECEIVED)
  }
  // 反方向：越过边界的 overhead 一定被拒
  let over = LT_MAX_RECEIVED.to_double() / k.to_double() + 0.5
  assert_true(!guard_overhead(k, over).is_empty())
}

///|
/// 非有限值：参数层（`parse_finite_double`）与子命令的 `overhead <= 0.0`
/// 已经各有一道，但守卫是库层入口，可能被别处调用 —— 它不能因为
/// `nan > 上限` 为 false 就放行。
test "LT-B: the overhead guard does not let nan / inf slip through" {
  let nan = 0.0 / 0.0
  assert_true(!guard_overhead(1000, nan).is_empty())
  let inf = 1.0 / 0.0
  assert_true(!guard_overhead(1000, inf).is_empty())
}

///|
/// **K 侧的对称性**：同一个 overhead 在 K=10 时无害、在 K=1<<20 时致命，
/// 因为守卫量是 `K × overhead`（收到的符号数）而不是 overhead 本身。
test "LT-B: the overhead guard scales with K, not with overhead alone" {
  // K=10, overhead=3.0 → 30 个符号，完全无害
  inspect(guard_overhead(10, 3.0), content="")
  // 同一个 overhead 在 K=1<<20 下 314 万，仍然在域内
  inspect(guard_overhead(1048576, 3.0), content="")
  // 再加一点就过界
  assert_true(!guard_overhead(1048576, 3.9).is_empty())
}
