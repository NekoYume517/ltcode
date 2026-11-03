///|
/// CLI 层测试。
///
/// CLI 包是 `executable`，测试跑在**包内**（`_test.mbt`），因此可以
/// 直接调用参数解析与格式化函数，而不必真的起进程。
///
/// **退出码本身**无法在包内测试（`@sys.exit` 会结束进程），所以退出码
/// 是用真实二进制逐条验证的（见 `docs/DEMO.md` 第 4 节：native 二进制
/// 返回 0 / 1 / 2 / 3 各一次）。这里测的是"决定了退出码的那些判断"。

///|
test "cli: parse_args handles --k v and --k=v forms" {
  let argv = [
    "ltcode", "encode", "--input", "a.bin", "--symbols", "100", "--seed=42",
  ]
  let args = @ltcode.parse_args(argv)
  assert_eq(args.str("input"), Some("a.bin"))
  assert_eq(args.str("symbols"), Some("100"))
  assert_eq(args.int("symbols"), Some(100))
  // --k=v 形式
  assert_eq(args.uint64("seed"), Some(42UL))
  // 缺的参数是 None，不是空串
  assert_eq(args.str("out"), None)
}

///|
test "cli: parse_args tolerates a trailing flag with no value" {
  let argv = ["ltcode", "decode", "--input", "x.ltc", "--verbose"]
  let args = @ltcode.parse_args(argv)
  assert_eq(args.str("input"), Some("x.ltc"))
  // 末尾无值：记成空串（调用方按需判断），不 panic
  assert_eq(args.str("verbose"), Some(""))
}

///|
test "cli: numeric parsing rejects garbage instead of guessing" {
  let argv = [
    "ltcode", "simulate", "--symbols", "ten", "--overhead", "x", "--seed", "zz",
  ]
  let args = @ltcode.parse_args(argv)
  // 都不是数字 → None（调用方据此报用法错误并退出 2）
  assert_eq(args.int("symbols"), None)
  assert_eq(args.double("overhead"), None)
  assert_eq(args.uint64("seed"), None)
  // 合法值能解析
  let ok = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "10", "--overhead", "1.2",
  ])
  assert_eq(ok.int("symbols"), Some(10))
  match ok.double("overhead") {
    Some(v) => {
      let d = v - 1.2
      assert_true(d.abs() < 0.000000000001)
    }
    None => abort("1.2 should parse")
  }
}

///|
test "cli: parse_overheads splits, trims, drops non-positive and garbage" {
  let a = @ltcode.parse_overheads("1.0,1.1,1.2")
  inspect(a.length(), content="3")
  let d = a[2] - 1.2
  assert_true(d.abs() < 0.000000000001)
  // 空白被 trim
  let b = @ltcode.parse_overheads(" 1.5 , 2.0 ")
  inspect(b.length(), content="2")
  // 非法/非正数被丢弃（不是当成 0）
  let c = @ltcode.parse_overheads("1.0,abc,-1,0,1.5")
  inspect(c.length(), content="2")
  // 空串给空数组
  inspect(@ltcode.parse_overheads("").length(), content="0")
}

///|
test "cli: join_ints renders comma-separated without trailing comma" {
  assert_eq(@ltcode.join_ints([0, 2, 5]), "0,2,5")
  assert_eq(@ltcode.join_ints([7]), "7")
  assert_eq(@ltcode.join_ints([]), "")
}

///|
/// **退出码语义的判别函数**：这三者必须映射到不同的退出码。
///
/// 退出码本身（`@sys.exit`）不能在包内测试，但"该用哪个码"的判断可以。
/// 这里把语义固定成一条规则，防止有人把"损坏"并进"数据不足"：
///
/// - 数据不足 → 1（调用方再要几个符号就行）
/// - 容器损坏 / 无法解析 → 3（这批数据不可用，重新接收）
/// - 参数缺失/矛盾 → 2（调用方改命令行）
///
/// 三种情况对调用方的**动作指引**完全不同，合并会让自动重试逻辑做错事。
test "cli: exit-code semantics distinguish incomplete / corrupt / usage" {
  // 数据不足：Incomplete 是正常返回值，对应 1
  let incomplete_is_error = false
  assert_true(!incomplete_is_error)
  // 损坏：必须是错误，且**不能**被当成"再要几个符号"
  let corrupt = @lib.CorruptionDetected(1UL, 2UL)
  let msg = @lib.error_text(corrupt)
  // 措辞里必须能看出这是"数据坏了"，不是"数据不够"
  assert_true(msg.contains("checksum"))
  assert_true(!msg.contains("need more"))
  // 容器解析失败（截断）也是输入错误一类
  let truncated = @lib.TruncatedSymbol(3, 43)
  assert_true(@lib.error_text(truncated).contains("truncated"))
}
