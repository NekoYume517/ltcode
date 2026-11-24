///|
/// LT35（2026-11-24 审计）：`decode` 的「missing indices」诊断行**必须有界**。
///
/// 现象（修复前实测，release native）：
///
/// ```text
/// ltcode encode --input p40.bin --symbols 1048576 --count 0 --out big.ltc
///   → out: big.ltc (43 bytes)        # 结构完好、README 承认它合法
/// ltcode decode --input big.ltc
///   → exit 1，stdout 7,277,598 字节，其中下标行单行 6,888,889 字符
/// ```
///
/// 根因：`missing` 的长度域是 `K`（上界 `max_source_symbols()` = `1 << 20`），
/// 而渲染路径 `join_ints(missing)` 与它成正比，全链路没有上限 ——
/// 与 LT33 / lincheck LC-31 同族（把输入规模映射成控制台输出）。
///
/// 红测试先于实现存在：修复前用 `join_ints` 对 1e6 个下标渲染，
/// 实测长度 6,888,889（断言要求 `< 600`）。
///
/// 下面四条锁的是**新的**契约：有界 + 省略数如实 + 小 K 输出逐字不变。
test "LT35: 1e6 缺失下标渲染成有界文本，且省略数如实" {
  let missing : Array[Int32] = []
  for i = 0; i < 1_000_000; i = i + 1 {
    missing.push(i)
  }
  let (shown, omitted) = missing_preview(missing, LT_MAX_LISTED_MISSING)
  // 单行不再随 K 增长：64 项、每项最多 7 位 + 逗号 ⇒ 远小于 600
  assert_true(shown.length() < 600)
  // 列出的就是前 64 个（首项 0、末项 63）
  assert_true(shown.has_prefix("0,1,2,"))
  assert_true(shown.has_suffix(",63"))
  // 省略数必须**恰好**是剩下的，不能凑整、不能藏
  assert_eq(omitted, 1_000_000 - LT_MAX_LISTED_MISSING)
  inspect(omitted, content="999936")
}

///|
/// 边界两侧：`limit` 项本身**不省略**（否则 README 的 51 项例子会被截），
/// 多 1 项就省略 1 项。
test "LT35: 上限边界是 limit 本身，不是 limit-1" {
  let exact : Array[Int32] = []
  for i = 0; i < LT_MAX_LISTED_MISSING; i = i + 1 {
    exact.push(i)
  }
  let (shown, omitted) = missing_preview(exact, LT_MAX_LISTED_MISSING)
  assert_eq(omitted, 0)
  // 正好等于 limit 时与旧输出逐字相同（不接受任何多余后缀）
  inspect(shown == join_ints(exact), content="true")
  let one_more : Array[Int32] = []
  for i = 0; i <= LT_MAX_LISTED_MISSING; i = i + 1 {
    one_more.push(i)
  }
  let (shown2, omitted2) = missing_preview(one_more, LT_MAX_LISTED_MISSING)
  assert_eq(omitted2, 1)
  inspect(shown2 == join_ints(exact), content="true")
}

///|
/// 小 K 不动：README / DEMO 里逐字引用的那段 `K=100` 输出是 51 个下标，
/// 修复后必须**逐字节相同**（否则文档与实测立刻脱节）。这里用一个 51 项的
/// 列表锁定「不超过上限就原样输出」这条契约 —— 具体下标值随 payload 变，
/// 因此这里只锁规模与拼接格式（`join_ints` 的逗号分隔、首尾项）。
test "LT35: 51 项缺失下标（README 例子的规模）逐字不变" {
  let missing : Array[Int32] = [
    0, 2, 4, 6, 8, 9, 10, 18, 21, 22, 23, 24, 25, 29, 30, 31, 33, 34, 36, 38, 42,
    47, 48, 49, 50, 52, 53, 55, 57, 58, 60, 61, 63, 64, 65, 66, 68, 69, 70, 71, 72,
    74, 75, 76, 78, 80, 81, 82, 83, 84, 85,
  ]
  assert_eq(missing.length(), 51)
  let (shown, omitted) = missing_preview(missing, LT_MAX_LISTED_MISSING)
  assert_eq(omitted, 0)
  inspect(shown.has_prefix("0,2,4,6,8,9,10,"), content="true")
  inspect(shown.has_suffix(",84,85"), content="true")
  inspect(shown == join_ints(missing), content="true")
}

///|
/// 退化输入不许谎报：空列表 → 空文本 + 0 省略；负上限 → 一项不列、
/// 省略数等于总数（不是 0，也不是负数）。
test "LT35: 空列表与负上限都不许谎报省略数" {
  let empty : Array[Int32] = []
  let (shown, omitted) = missing_preview(empty, LT_MAX_LISTED_MISSING)
  inspect(shown, content="")
  assert_eq(omitted, 0)
  let some : Array[Int32] = [3, 7, 9]
  let (shown2, omitted2) = missing_preview(some, -5)
  inspect(shown2, content="")
  assert_eq(omitted2, 3)
}
