///|
/// LT32（2026-11-21 审计）：度量预算的**字节轴漏了平均度**。
///
/// LT8 加的字节轴是 `trials × max(K, received) × symbol_len`，但每个收到的
/// 符号在 `peel` 里要过 `avg_degree` 个子集（`acc` 的分配 + XOR 消去都是
/// 按子集做的）：实测 `stats.subset_slots / received`
/// = K=100 → 6.82、K=1000 → 8.92、K=10000 → 14.45（`oh=2.0`，c=0.1、δ=0.5）。
/// 于是这条轴系统性低估 ~7-15 倍，**三个因子各自合法、乘积却到分钟级**。
///
/// 实测（release native，本轮）：
///
/// ```text
/// simulate --symbols 1000 --overhead 2.0 --trials 1000 --symbol-len 800   exit 0  91.0 s
/// simulate --symbols 1000 --overhead 1.2 --trials 1000 --symbol-len 800   exit 0  48.5 s
/// simulate --symbols 1000 --overhead 2.0 --trials 1000 --symbol-len 4     exit 0  22.0 s
/// ```
///
/// 前两条都在旧判据（1.6e9 / 1.2e9 ≤ 2e9）里放行，真实 XOR 字节是
/// 14.3e9 / 12.8e9 —— 低估 9 倍。修法：字节轴乘上
/// `degree_factor_bound(K)`（`ceil(ln K) + 6`，对上面三个实测值都是上界），
/// 上限按实测吞吐（≈157 MB/s ⇒ 40 s ≈ 6e9 真实字节）重定为 6e9。
///
/// 修复前第 1、2 条断言全红（`check_metric_magnitudes` 返回空串 = 放行）。

///|
test "LT32: the measured 91 s and 48 s points are rejected by the degree axis" {
  // 91.0 s：旧判据 1.6e9 字节放行，真实 14.3e9
  let msg = check_metric_magnitudes(1000, [2.0], 1000, 800)
  assert_true(!msg.is_empty())
  // 48.5 s：旧判据 1.2e9 放行，真实 12.8e9
  assert_true(!check_metric_magnitudes(1000, [1.2], 1000, 800).is_empty())
  // 文案要点名是字节轴（用户该改的是 --symbol-len / --trials）
  assert_true(msg.contains("--symbol-len"))
}

///|
/// 同样的参数配默认 `symbol-len=4` 必须继续放行：**不许为了更紧把轴改小**，
/// 22.0 s 那个点的真实字节只有 9e7，离 6e9 还有两个数量级。
test "LT32: the same trials at the default symbol length still pass" {
  inspect(check_metric_magnitudes(1000, [2.0], 1000, 4), content="")
  inspect(check_metric_magnitudes(1000, [1.2], 1000, 4), content="")
  inspect(check_metric_magnitudes(1000, [2.0], 100, 800), content="")
}

///|
/// README / DEMO / API.md 里每条度量命令逐条代进来都必须继续可复现。
test "LT32: every documented metric command stays inside the new byte axis" {
  let readme_curve = [1.0, 1.1, 1.15, 1.18, 1.2, 1.25, 1.3, 1.5, 2.0]
  inspect(check_metric_magnitudes(1000, readme_curve, 100, 4), content="")
  inspect(check_metric_magnitudes(1000, readme_curve, 500, 4), content="")
  inspect(check_metric_magnitudes(1000, [1.18, 1.2, 1.25], 500, 4), content="")
  inspect(
    check_metric_magnitudes(1000, [1.0, 1.15, 1.2, 1.3], 500, 4),
    content="",
  )
  inspect(check_metric_magnitudes(1000, [1.0], 1000, 4), content="")
  for oh in [1.2, 1.3, 1.5] {
    inspect(check_metric_magnitudes(1000, [oh], 200, 4), content="")
  }
}

///|
/// 边界双向：`K=1000, oh=2.0, sl=800` 下 degree 上界 = `ceil(ln 1000)+6 = 13`
/// （实测 8.92，留 1.4× 余量），每 trial 真实字节 = 2000 × 800 × 13；恰好在
/// 6e9 内的是 288 trials，289 必须被拒。
test "LT32: the byte-axis boundary is bidirectional at the new limit" {
  // 288 × 2000 × 800 × 13 = 5.99e9 <= 6e9
  inspect(check_metric_magnitudes(1000, [2.0], 288, 800), content="")
  // 289 × ... = 6.01e9 > 6e9
  assert_true(!check_metric_magnitudes(1000, [2.0], 289, 800).is_empty())
}
