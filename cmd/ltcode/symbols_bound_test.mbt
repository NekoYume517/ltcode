///|
/// `--symbols` 的上界必须在**用法层**判（LT-K，2026-11-11 审计）。
///
/// ## 缺陷形态（修复前）
///
/// `encode --symbols 2147483647` 能通过参数解析（它是合法的 Int32），
/// 一路走到 `SourceBlock::from_bytes` 才被 `SourceTooLarge` 拒掉，于是：
///
/// ```
/// ltcode: cannot split input: source too large:
///         K=2147483647 exceeds the limit of 1048576 source symbols
/// exit 3
/// ```
///
/// 两个问题：
/// 1. **退出码归类错**：`--symbols` 越界是用法错误（2），不是输入文件非法（3）。
///    `--count` 越界就是按 2 报的（`explicit_count_overflow_msg` 那一族），
///    同一个域的两个参数走了两条路。
/// 2. **文案把人指向输入文件**：`cannot split input` 读起来像「你的
///    `--input` 有问题」，而那个文件根本没被读过（`read_file` 在
///    `from_bytes` 之前，但报错说的是「切不开」）。用户会去检查/替换文件，
///    而真正该改的是 K。
///
/// 修法与其他 guard 同形状：把判定抽成返回文案的纯函数，用法层调用它，
/// 空串 = 没越界。退出码本身在包内测不了（`@sys.exit` 会结束进程），
/// 所以这里锁的是「决定了退出码的那条判断」与文案里的两个事实
/// （上界值、用户给的值）。
test "cli: --symbols above max_source_symbols is a usage error that names --symbols" {
  let limit = @lib.max_source_symbols()
  // 域内（含两个边界）静默
  inspect(@ltcode.symbols_bound_msg(1), content="")
  inspect(@ltcode.symbols_bound_msg(limit), content="")
  // 越界：文案必须点明是 `--symbols`，带上上界与用户给的值
  let over = @ltcode.symbols_bound_msg(limit + 1)
  assert_true(!over.is_empty())
  assert_true(over.contains("--symbols"))
  assert_true(over.contains("\{limit}"))
  assert_true(over.contains("\{limit + 1}"))
  // 不能把话推到输入文件上（那是 exit 3 的域）
  assert_true(!over.contains("input"))
  assert_true(!over.contains("split input"))
  // Int32 上限也走同一条款，而不是留给 SourceBlock::from_bytes
  assert_true(!@ltcode.symbols_bound_msg(2147483647).is_empty())
}
