// LT-F（2026-11-10 对抗审计，P2）：未知 `--flag` 与位置参数被静默接受。
//
// ## 缺陷形态（修复前）
//
// `main.mbt` 的 `parse_args` 对非 `--` 开头的 token 只做「跳过」，对未知的
// `--key` 从不检查。于是：
//
//     $ ltcode decode --input good.ltc --out o.bin --seedx 999999
//     decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
//     exit 0
//
//     $ ltcode decode --input good.ltc --out o.bin some-junk
//     decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
//     exit 0
//
// 第一行最危险：用户以为自己指定了种子核对（`--seedx` 是 `--seed` 的笔误），
// 而那个核对**根本没跑** —— 命令行的"成功"掩盖了一个手动核对项的静默失效。
// 第二行与 `main.mbt` 里那句注释（"位置参数不接受，`ltcode encode foo` 会被
// 当作错误"）**直接矛盾**：注释承诺的行为从来没被实现。
//
// ## 修法
//
// `parse_args` 现在记录（a）全部位置参数、（b）按 argv 顺序出现的键。
// 新增 `unknown_arg_error(args, cmd)`：返回空串 = 干净，非空 = 可直接当
// 用法错误打印的文本（含**原始 token**）。各子命令入口统一调用它并
// `exit_usage()`（退出码 2）。
//
// 关键是不能误伤合法形态：
// - `--seed 0xabc`：`0xabc` 是**值**，被前一个 flag 消费，不是键
// - `--count -5` / `--trials -5`：负数是值，同样被消费
// - `--k=v`：等号形态
// - 末尾无值的 flag：记成空串，由各子命令按需报错

///|
/// **核心回归 1**：笔误的键必须被拒。
///
/// 修复前 `--seedx 999999` 只往 map 里塞一个没人读的键，命令照旧成功 ——
/// 用户以为的"种子核对"静默失效。
test "LT-F: a typo'd option is rejected and the raw token is echoed" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--out", "y.bin", "--seedx", "999999",
  ])
  let msg = @ltcode.unknown_arg_error(args, "decode")
  assert_true(!msg.is_empty())
  // 原始 token 必须回显（用户要能一眼看到自己写错了哪个）
  assert_true(msg.contains("--seedx"))
  // 指明这是哪个子命令的参数问题
  assert_true(msg.contains("decode"))
  // 正确拼写则放行
  let ok = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--out", "y.bin", "--seed", "1",
  ])
  inspect(@ltcode.unknown_arg_error(ok, "decode"), content="")
}

///|
/// **核心回归 2**：位置参数必须被拒 —— 兑现 `main.mbt` 里那句注释。
///
/// 修复前对 `some-junk` 完全无感。
test "LT-F: a positional argument is rejected" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--out", "y.bin", "some-junk",
  ])
  let msg = @ltcode.unknown_arg_error(args, "decode")
  assert_true(!msg.is_empty())
  assert_true(msg.contains("some-junk"))
  // 说清正确形态：每个参数都要有名字
  assert_true(msg.contains("--"))
}

///|
/// 子命令的**键集合互不相同**：`--overheads` 只属于 `curve`，
/// `--count` 只属于 `encode`。把某个子命令的参数写到另一个子命令上
/// 同样是笔误，必须被抓到（否则"我明明给了 count"会变成一个谜）。
test "LT-F: options are checked against the specific subcommand" {
  // --overheads 不是 simulate 的参数
  let wrong = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "100", "--overheads", "1.0,1.2",
  ])
  let msg = @ltcode.unknown_arg_error(wrong, "simulate")
  assert_true(!msg.is_empty())
  assert_true(msg.contains("--overheads"))
  // 同一个参数在 curve 上是合法的
  let right = @ltcode.parse_args([
    "ltcode", "curve", "--symbols", "100", "--overheads", "1.0,1.2",
  ])
  inspect(@ltcode.unknown_arg_error(right, "curve"), content="")
  // --count 只属于 encode
  let enc = @ltcode.parse_args([
    "ltcode", "encode", "--input", "a.bin", "--symbols", "10", "--count", "30",
  ])
  inspect(@ltcode.unknown_arg_error(enc, "encode"), content="")
  let dec = @ltcode.parse_args([
    "ltcode", "decode", "--input", "a.ltc", "--count", "30",
  ])
  let dmsg = @ltcode.unknown_arg_error(dec, "decode")
  assert_true(!dmsg.is_empty())
  assert_true(dmsg.contains("--count"))
}

///|
/// **不能误伤合法形态**：这一条是修复的主要风险面。
///
/// 值里出现 `0x` 前缀、负数、逗号列表都不是键；`--k=v` 是同一个键的
/// 另一种写法。全部必须放行，否则修复会把正常的命令变成不可用。
test "LT-F: legitimate value forms are not mistaken for unknown options" {
  // --seed 0x...：十六进制值
  let hex = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "100", "--overhead", "1.2", "--seed", "0x4C54434F4445",
  ])
  inspect(@ltcode.unknown_arg_error(hex, "simulate"), content="")
  // 负数作为值（合法性由子命令的 >= 1 检查负责，不是"未知参数"）
  let neg = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "100", "--overhead", "1.2", "--trials", "-5",
  ])
  inspect(@ltcode.unknown_arg_error(neg, "simulate"), content="")
  // 逗号列表
  let list = @ltcode.parse_args([
    "ltcode", "curve", "--symbols", "10", "--overheads", "1.0,1.1,1.2",
  ])
  inspect(@ltcode.unknown_arg_error(list, "curve"), content="")
  // --k=v 形态
  let eq = @ltcode.parse_args([
    "ltcode", "encode", "--input=a.bin", "--symbols=100", "--count=300",
  ])
  inspect(@ltcode.unknown_arg_error(eq, "encode"), content="")
  // --symbol-len 是两段连字符，不能被拆错
  let dash = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "10", "--overhead", "1.2", "--symbol-len",
    "40",
  ])
  inspect(@ltcode.unknown_arg_error(dash, "simulate"), content="")
  // 全部参数的完整组合
  let full = @ltcode.parse_args([
    "ltcode", "encode", "--input", "a.bin", "--symbols", "100", "--seed", "12345",
    "--count", "300", "--out", "a.ltc",
  ])
  inspect(@ltcode.unknown_arg_error(full, "encode"), content="")
}

///|
/// `help` 不需要任何参数，因此任何额外 token 都是多余的 —— 但空白命令
/// 必须干净（`ltcode help` 是合法调用）。
test "LT-F: help accepts no options but an empty invocation is clean" {
  let bare = @ltcode.parse_args(["ltcode", "help"])
  inspect(@ltcode.unknown_arg_error(bare, "help"), content="")
  let extra = @ltcode.parse_args(["ltcode", "help", "--verbose"])
  assert_true(!@ltcode.unknown_arg_error(extra, "help").is_empty())
}

///|
/// 位置参数与未知键**同时**出现时也要报（不能只报一个就放过另一个以后
/// 再撞上）。这里只要求报出至少一个、且是原位 token。
test "LT-F: multiple problems still produce a usable message" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--bogus", "1", "junk",
  ])
  let msg = @ltcode.unknown_arg_error(args, "decode")
  assert_true(!msg.is_empty())
  let mentions_positional = msg.contains("junk")
  let mentions_option = msg.contains("--bogus")
  assert_true(mentions_positional || mentions_option)
}

///|
/// 键顺序必须**按 argv 出现顺序**记录，而不是按 Map 的哈希序 ——
/// 否则"先报哪个"在不同运行/平台上会变，报错文本就不稳定（脚本按文本
/// 匹配会随机失效）。
///
/// `--zzz` 写在前面，因此必须报 `--zzz`；把两个键的顺序调换，报的就必须
/// 是 `--aaa`。这才是"顺序"的完整证据（只断言一个方向会被"按字典序报"
/// 这种实现碰巧蒙过）。
test "LT-F: offending tokens are reported in argv order" {
  let zfirst = @ltcode.parse_args([
    "ltcode", "decode", "--zzz", "1", "--aaa", "2",
  ])
  let m1 = @ltcode.unknown_arg_error(zfirst, "decode")
  assert_true(m1.contains("--zzz"))
  assert_true(!m1.contains("--aaa"))

  let afirst = @ltcode.parse_args([
    "ltcode", "decode", "--aaa", "2", "--zzz", "1",
  ])
  let m2 = @ltcode.unknown_arg_error(afirst, "decode")
  assert_true(m2.contains("--aaa"))
  assert_true(!m2.contains("--zzz"))
}
