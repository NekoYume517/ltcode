// LT-H1（2026-11-10 对抗审计，P3）：默认 count 触顶时的报错文案。
//
// ## 缺陷形态（修复前）
//
// `encode` 的默认 count 是 `ceil(1.5K) + 1`。K=700000 时它算出 1050001，
// 撞上 LC-1 的 LT_MAX_COUNT（1_000_000）：
//
//     $ ltcode encode --input big.bin --symbols 700000 --out big.ltc
//     ltcode: --count must be <= 1000000 (got 1050001); split the payload
//             or raise K instead
//     exit 2
//
// 用户**根本没传 --count**，却被指着 `--count` 说事。他要么去翻文档确认
// 默认值是多少，要么怀疑自己上一条命令行里那个不存在的参数。这不是数据
// 错误也不是用法错误（K=700000 完全在域内），而是「默认值与上限撞了」
// 这一种独立情况，需要独立文案。
//
// ## 修法
//
// 把默认值的计算抽成 `default_count(k)`，并在触顶时给出**说明默认值来源**
// 的文案：
//
//     ltcode: the default --count (ceil(1.5K)+1 = 1050001) exceeds the
//             limit of 1000000; pass --count explicitly (e.g. --count 1000000)
//
// 显式给了超限值时的文案保持原样（那时"你写的 --count 太大"是对的）。

///|
/// 默认 count 的公式必须与 `docs`/README 一致：`ceil(1.5K) + 1`。
///
/// 锁定这个公式是因为 README 与 `--count 0` 那一节都引用了它 ——
/// 公式一变，文档里的例子就成了假的。
test "LT-H1: default_count is ceil(1.5K) + 1" {
  inspect(@ltcode.default_count(10), content="16") // 15 + 1
  inspect(@ltcode.default_count(100), content="151")
  inspect(@ltcode.default_count(1000), content="1501")
  inspect(@ltcode.default_count(4), content="7") // 6 + 1
  // K=1 时下限也成立
  inspect(@ltcode.default_count(1), content="2")
}

///|
/// **核心回归**：K=700000 的默认 count 是 1050001，撞上上限。
///
/// 这条断言两件事：
/// 1. `default_count(700000)` 确实算出 1050001（默认值本身没错，它是
///    README 承诺的公式）；
/// 2. 超过上限。
///
/// 因此触顶是**必然**而不是偶发，文案必须解释默认值来源。
test "LT-H1: the default count for K=700000 necessarily exceeds LT_MAX_COUNT" {
  let dc = @ltcode.default_count(700000)
  inspect(dc, content="1050001")
  assert_true(dc > @ltcode.LT_MAX_COUNT)
  // 边界：K 小到某处就不再触顶
  let safe_k = 600000
  assert_true(@ltcode.default_count(safe_k) <= @ltcode.LT_MAX_COUNT)
}

///|
/// 触顶文案必须（a）说清这是**默认值**、（b）写出算出来的数、
/// （c）给出可行的下一步（显式传 --count）。
test "LT-H1: the default-overflow message explains it is the default, not the user's input" {
  let msg = @ltcode.default_count_overflow_msg(700000)
  assert_true(!msg.is_empty())
  // 必须点明"默认值"
  assert_true(msg.contains("default"))
  // 必须写出算式与结果，用户才能对上 README
  assert_true(msg.contains("1050001"))
  assert_true(msg.contains("1.5"))
  // 必须给出下一步
  assert_true(msg.contains("--count"))
  // 必须带上上限值
  assert_true(msg.contains("1000000"))
  // **不能**说成用户传的 --count 超限（那是另一种情况的文案）
  assert_true(!msg.contains("must be <= 1000000 (got 1050001)"))
}

///|
/// 不触顶时守卫返回空串（与其它 guard 同形状），调用方据此决定是否跳过。
test "LT-H1: the guard stays silent when the default is within the limit" {
  inspect(@ltcode.default_count_overflow_msg(1000), content="")
  inspect(@ltcode.default_count_overflow_msg(100), content="")
  inspect(@ltcode.default_count_overflow_msg(600000), content="")
  // 触顶才说话
  assert_true(!@ltcode.default_count_overflow_msg(700000).is_empty())
}

///|
/// 两条文案必须**可区分**：显式超限说的是"你写的 --count"，默认触顶说的是
/// "默认值触顶"。合并成一条会让两种完全不同的修法（改参数 vs 加参数）
/// 分不出来。
test "LT-H1: the explicit-overflow text and the default-overflow text differ" {
  let explicit = @ltcode.explicit_count_overflow_msg(2000000)
  let dflt = @ltcode.default_count_overflow_msg(700000)
  assert_true(explicit != dflt)
  // 显式那条要回显用户写的值
  assert_true(explicit.contains("2000000"))
  assert_true(explicit.contains("must be <="))
  // 显式那条不该把话推到"默认值"上
  assert_true(!explicit.contains("default"))
}
