///|
/// LT10（2026-11-17 审计）：`curve` 只做**逐点**预算，点数与总量都没有上界。
///
/// `check_metric_magnitudes` 对 `overheads` 里的每个点分别过一遍
/// `guard_overhead` + `guard_work`，但一条 `curve` 命令的真实成本是
/// **Σ_points per-point work**。`--overheads` 的长度既没有域也没有量级守卫
/// （HANDOVER §19.6 记着「`curve --overheads` 点数无上界」）。
///
/// 实测（release native，`check_metric_magnitudes(1000, [1.2]*N, 200, 4)`，
/// 每点 2.4e5 远低于单点上限 2e6）：N = 1 / 5 / 20 分别是
/// 2881 / 15768 / 69215 ms，全部 exit 0 —— 外推 1000 点 ≈ 1 h、
/// 10000 点 ≈ 10 h。这就是「每个因子都合法、乘积没守卫」在**点数轴**上的
/// 复现，与 LT6（trials × received）、LT8（× symbol_len）同族。
///
/// 修法两条：
/// 1. 点数上界 `LT_MAX_OVERHEAD_POINTS = 64`（20 点 69 s 已是分钟级，
///    64 点约 3.5 min 是忍耐上限）；
/// 2. 整条命令的总预算 `Σ_points trials × max(K, received)` 与
///    `Σ_points ... × symbol_len` 各有上限（见 `LT_MAX_WORK_TOTAL`）。
///    每点都合法但点多到几十条时，单点上限管不住总墙钟。
///
/// 红测试先于实现存在：修复前下面两条 `assert_true(!...is_empty())` 全红。
test "LT10: more than 64 overhead points is rejected" {
  let pts : Array[Double] = []
  for i = 0; i < 65; i = i + 1 {
    pts.push(1.0 + i.to_double() * 0.001)
  }
  let msg = check_metric_magnitudes(1000, pts, 100, 4)
  assert_true(!msg.is_empty())
  // 文案必须点名 --overheads（用户要改的是点数，不是 K 或 trials）
  assert_true(msg.contains("--overheads"))
  // 64 点本身合法：点数上界是 64，不是 63
  let ok : Array[Double] = []
  for i = 0; i < 64; i = i + 1 {
    ok.push(1.0 + i.to_double() * 0.001)
  }
  inspect(check_metric_magnitudes(1000, ok, 100, 4), content="")
}

///|
/// 点数合法但**总量**越界也必须拦：64 点 × 500 trials × overhead 2.0
/// = 6.4e7 符号操作，每点 1e6 都在单点上限之内。
test "LT10: a long curve is bounded by the per-command total budget" {
  let pts : Array[Double] = []
  for i = 0; i < 64; i = i + 1 {
    pts.push(2.0)
  }
  let msg = check_metric_magnitudes(1000, pts, 500, 4)
  assert_true(!msg.is_empty())
  // 同一条曲线把 trials 降下来就回到预算内（总量是 trials 的线性函数）：
  // 64 点 × 50 trials × 2000 = 6.4e6 <= 1e7。
  inspect(check_metric_magnitudes(1000, pts, 50, 4), content="")
}

///|
/// 字节轴的总量同样要守（LT32 起单点/总量都含平均度上界）：K=100、
/// oh=1.2、`symbol_len=1048576`、trials=4 的单点 = 4 × 120 × 1048576 × 11
/// = 5.53e9 真实字节（<= 单点 6e9）；3 个这样的点 = 1.66e10 仍在总量 2e10 内，
/// 4 个点 = 2.21e10 就必须被**总量**拦下 —— 边界精确。
test "LT10: the total budget also covers the byte axis" {
  let p3 : Array[Double] = []
  for i = 0; i < 3; i = i + 1 {
    p3.push(1.2)
  }
  let p4 : Array[Double] = []
  for i = 0; i < 4; i = i + 1 {
    p4.push(1.2)
  }
  inspect(check_metric_magnitudes(100, [1.2], 4, 1048576), content="")
  inspect(check_metric_magnitudes(100, p3, 4, 1048576), content="")
  let msg = check_metric_magnitudes(100, p4, 4, 1048576)
  assert_true(!msg.is_empty())
  assert_true(msg.contains("byte"))
}
