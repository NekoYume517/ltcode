///|
/// LT33（2026-11-23 审计）：负数与零参数必须在入口被拒，不允许触碰分配器。
///
/// 修复前的现象（`audit/2026-11-23/ltcode/evidence/probe2-run.log`，
/// 8 条探针测试全部 `RuntimeError: unreachable`）：
///
/// - `ideal_soliton(-1)` / `fixed_distribution(1, -1)` / `robust_distribution(-1, …)`
///   在 `Array::make(k, 0.0)` 上 trap；
/// - `distribute_from_array(-2, [])` 在 `FixedArray::make(k + 1, 0.0)` 上 trap；
/// - `random_sources(1, 1, -1)` 在 `FixedArray::make(symbol_len, …)` 上 trap，
///   并顺着 `run_trial` / `ideal_success_rate` / `fixed_degree_success_rate`
///   一路把三个度量入口一起拖下水；
/// - `ideal_soliton(0)` 更隐蔽：不 trap，静默返回一张 `k=0` 的全零 pmf 表
///   —— `validate_distribution` 自己都会拒绝的分布对象，从 pub 入口直接
///   交到调用方手里。
///
/// 同一份非法参数走 `decode_with_stats` / `robust_soliton_checked` 会得到
/// 优雅的 `EmptySource` / `InvalidDegree`（LT 的既有契约），走构造器却是
/// WASM trap —— 守卫只设在 decode 路径、pub 构造器不设防，正是
/// 「公开手工结构 ≠ parser 可达输入」的同族镜像。
///
/// 修法：`k < 1` 一律 `EmptySource`（与 `SourceBlock::new` / `decode_with_stats`
/// 的 K 域同一个裁决）；`random_sources` 的 `symbol_len < 1` 同理。
/// `fixed_distribution` 对 `d0` 的钳位是 LT15（2026-11-17）锁定的既有契约，
/// 本轮不动。

///|
/// 把「调用 + 可能的 raise」折成可断言的字符串（不依赖 Show）。
fn lt33_call(f : () -> Unit raise @src.LtError) -> String {
  let r : Result[Unit, @src.LtError] = try {
    f()
    Ok(())
  } catch {
    e => Err(e)
  }
  match r {
    Ok(_) => "accepted"
    Err(@src.EmptySource) => "empty_source"
    Err(e) => "other:\{@src.error_text(e)}"
  }
}

///|
test "LT33: ideal_soliton rejects k < 1 instead of trapping" {
  for k in [-1, -2, 0] {
    let outcome = lt33_call(() => @src.ideal_soliton(k) |> ignore)
    inspect(outcome, content="empty_source")
  }
}

///|
test "LT33: fixed_distribution rejects k < 1, keeps the d0 clamp contract" {
  for k in [-1, 0] {
    let outcome = lt33_call(() => @src.fixed_distribution(1, k) |> ignore)
    inspect(outcome, content="empty_source")
  }
  // d0 的钳位（LT15）不受影响：k 合法时 d0 < 1 仍钳到 1
  let clamped = @src.fixed_distribution(-3, 4) catch {
    _ => abort("LT15 broke")
  }
  let p1 = clamped.pdf(1)
  assert_true((p1 - 1.0).abs() < 0.000000000001)
}

///|
test "LT33: distribute_from_array rejects k < 1 instead of trapping" {
  for k in [-2, -1, 0] {
    let outcome = lt33_call(() => @src.distribute_from_array(k, []) |> ignore)
    inspect(outcome, content="empty_source")
  }
}

///|
test "LT33: robust_distribution rejects k < 1 instead of trapping" {
  for k in [-1, 0] {
    let outcome = lt33_call(() => {
      @src.robust_distribution(k, 0.1, 0.5) |> ignore
    })
    inspect(outcome, content="empty_source")
  }
  // checked 入口的结论与文案不变（它先做自己的域检查：InvalidDegree(k, k)）
  let outcome = match @src.robust_soliton_checked(0, 0.1, 0.5) {
    Err(@src.InvalidDegree(0, 0)) => "invalid_degree"
    Err(_) => "other_err"
    Ok(_) => "accepted"
  }
  inspect(outcome, content="invalid_degree")
}

///|
test "LT33: random_sources rejects symbol_len < 1 and k < 1" {
  for sl in [-1, 0] {
    let outcome = lt33_call(() => @src.random_sources(1UL, 1, sl) |> ignore)
    inspect(outcome, content="empty_source")
  }
  let outcome = lt33_call(() => @src.random_sources(1UL, 0, 4) |> ignore)
  inspect(outcome, content="empty_source")
}

///|
test "LT33: metric entries report empty source for k < 1 or symbol_len < 1" {
  // k 轴修复前已由 SourceBlock::new 兜住（run_trial 先构造 random_sources
  // 再进 SourceBlock::new）；symbol_len 轴修复前在 random_sources 的
  // FixedArray::make(-1) 上 trap。
  let outcome = lt33_call(() => {
    @src.run_trial(10, 1.5, 1UL, -1, 0.1, 0.5) |> ignore
  })
  inspect(outcome, content="empty_source")
  let t1 = lt33_call(() => @src.ideal_success_rate(-1, 1.5, 1, 1UL, 4) |> ignore)
  inspect(t1, content="empty_source")
  let t2 = lt33_call(() => {
    @src.fixed_degree_success_rate(-1, 5, 1.5, 1, 1UL, 4) |> ignore
  })
  inspect(t2, content="empty_source")
  let t3 = lt33_call(() => {
    @src.run_with_distribution(
      @src.ideal_soliton(4) catch {
        _ => abort("dist")
      },
      -1,
      1.5,
      1,
      1UL,
      4,
    )
    |> ignore
  })
  inspect(t3, content="empty_source")
  // sample_degree 与 robust_distribution 同一份 k 域
  let rng = @src.Ltrng::new(1UL)
  let t4 = lt33_call(() => @src.sample_degree(rng, 0, 0.1, 0.5) |> ignore)
  inspect(t4, content="empty_source")
}

///|
test "LT33: decode_success_rate surfaces empty source for k < 1" {
  // CLI 在参数层就把 k < 1 拒成 exit 2；这条锁的是库层直调的结论：
  // 是明确的 EmptySource，而不是 trap 或一个 rate=0 的假曲线。
  let outcome = lt33_call(() => {
    @src.decode_success_rate(-1, 1.5, 5, 1UL, 4, 0.1, 0.5) |> ignore
  })
  inspect(outcome, content="empty_source")
}
