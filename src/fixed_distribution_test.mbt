///|
/// LT15（2026-11-17 审计）：`fixed_distribution(d0, k)` 对 `d0 > k` / `d0 < 1`
/// **静默**返回一张全零 pmf（未归一化），而 `Distribution::sample` 在
/// `cdf` 全零时把 `lo` 推到 `k+1` 再钳到 `k` —— 于是「固定度 5」在 K=2/3/4
/// 时实际是「固定度 K」，对照行的含义与名字不符。
///
/// CLI 可达：`distcmp` 恒用 `fixed(5)`，实测 K=1 → 1.000、K=2/3/4 → 0.000。
/// HANDOVER §20.5 把这条记成「`sample` 的 k≤1 早退，K<3 对照口径退化」——
/// **那只解释 K=1**。K=2..4 走的是上面这条完全不同的路径（零 pmf 钳位），
/// 所以那句记录在事实层面是错的（已在 REPORT.md §5 纠正）。
///
/// 修法：把 `d0` **钳到 `[1, k]`**（`fixed_distribution` 的文档本来就写着
/// 前置条件 `1 <= d0 <= k`，只是没有检查）。于是分布恒归一化（pmf 为单位
/// 质量），`distcmp` 的 0.000 / 1.000 结论不变 —— 变的是它不再是「一张
/// 全零表被钳位」的副产品。CLI 的对外行为逐字未变（下面有断言）。
test "LT15: fixed_distribution clamps d0 into [1, k] instead of writing a zero pmf" {
  // K=2 + d0=5：钳到 2（= K）→ pmf 是单位质量，值是 degree 2
  let d = fixed_distribution(5, 2)
  assert_eq(d.pdf(1), 0.0)
  assert_eq(d.pdf(2), 1.0)
  // 归一化校验必须通过（修复前 sum=0，validate 会拒）
  match validate_distribution(d) {
    Ok(_) => ()
    Err(e) => abort("clamped distribution is not normalized: \{error_text(e)}")
  }
  // d0 < 1 钳到 1：K=4 + d0=0 → 全为度 1，剥皮必然成功
  let e = fixed_distribution(0, 4)
  assert_eq(e.pdf(1), 1.0)
  match validate_distribution(e) {
    Ok(_) => ()
    Err(err) => abort("d0=0 clamp broken: \{error_text(err)}")
  }
  // 域内 d0 逐位不变（不误伤）：d0=3, K=10
  let f = fixed_distribution(3, 10)
  assert_eq(f.pdf(3), 1.0)
  assert_eq(f.pdf(1), 0.0)
  assert_eq(f.expected_degree(), 3.0)
}

///|
/// CLI 侧的对外结论**不变**（这是「双向验证」的另一半）：`distcmp` 的
/// `fixed(5)` 行在 K=1 仍是 1.000（度 1 退化成唯一解）、K=2..4 仍是 0.000
/// （度 k 的方程彼此相同，没有度 1 符号可用）。修复只让那张表**归一化**，
/// 不改结论。
test "LT15: distcmp fixed(5) conclusions are unchanged at small K" {
  let at_k1 = fixed_degree_success_rate(1, 5, 2.0, 20, 1UL, 4) catch {
    e => abort("K=1: \{error_text(e)}")
  }
  assert_eq(at_k1.successes, 20)
  for k in [2, 3, 4] {
    let point = fixed_degree_success_rate(k, 5, 2.0, 20, 1UL, 4) catch {
      e => abort("K=\{k}: \{error_text(e)}")
    }
    assert_eq(point.successes, 0)
  }
}
