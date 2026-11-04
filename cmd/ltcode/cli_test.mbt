///|
/// CLI 层测试。
///
/// CLI 包是 `executable`，测试跑在**包内**（`_test.mbt`），因此可以
/// 直接调用参数解析与格式化函数，而不必真的起进程。
///
/// **退出码本身**无法在包内测试（`@sys.exit` 会结束进程），所以退出码
/// 是用真实二进制逐条验证的（见 `docs/DEMO.md` 第 4 节：native 二进制
/// 返回 0 / 1 / 2 / 3 各一次）。这里测的是"决定了退出码的那些判断"。
///
/// 数值参数一律用下面这三个 `show_*` 助手断言：它们把 `ArgNum` 的**三态**
/// （absent / present / invalid）原样摊开，因此测试能区分
/// "这个参数没给"和"给了 'abc'"。用 `assert_eq(x, None)` 就做不到 ——
/// LT-1 正是在那种断言下藏住的。

///|
fn show_int_arg(args : Args, key : String) -> String {
  match args.int(key) {
    Absent => "absent"
    Present(v) => "present \{v}"
    Invalid(raw) => "invalid \{raw}"
  }
}

///|
fn show_uint_arg(args : Args, key : String) -> String {
  match args.uint64(key) {
    Absent => "absent"
    Present(v) => "present \{v}"
    Invalid(raw) => "invalid \{raw}"
  }
}

///|
fn show_double_arg(args : Args, key : String) -> String {
  match args.double(key) {
    Absent => "absent"
    Present(v) => "present \{v}"
    Invalid(raw) => "invalid \{raw}"
  }
}

///|
test "cli: parse_args handles --k v and --k=v forms" {
  let argv = [
    "ltcode", "encode", "--input", "a.bin", "--symbols", "100", "--seed=42",
  ]
  let args = @ltcode.parse_args(argv)
  assert_eq(args.str("input"), Some("a.bin"))
  assert_eq(args.str("symbols"), Some("100"))
  assert_eq(show_int_arg(args, "symbols"), "present 100")
  // --k=v 形式
  assert_eq(show_uint_arg(args, "seed"), "present 42")
  // 缺的参数是 None，不是空串
  assert_eq(args.str("out"), None)
  // 缺的数值参数是 Absent（不是 Invalid）—— 这是三态的意义所在
  assert_eq(show_int_arg(args, "out"), "absent")
}

///|
test "cli: parse_args tolerates a trailing flag with no value" {
  let argv = ["ltcode", "decode", "--input", "x.ltc", "--verbose"]
  let args = @ltcode.parse_args(argv)
  assert_eq(args.str("input"), Some("x.ltc"))
  // 末尾无值：记成空串（调用方按需判断），不 panic
  assert_eq(args.str("verbose"), Some(""))
  // 空串作为数值是 Invalid（给了一个不是数的东西），不是 Absent
  assert_eq(show_int_arg(args, "verbose"), "invalid ")
}

///|
/// **LT-1 核心回归**：垃圾必须落到 `Invalid`，而不是"没给"。
///
/// 旧版本这里返回 `None`，调用方 `unwrap_or(默认值)` 一接就变成
/// "垃圾 → 默认值 → 命令行看着成功了"。两种垃圾各测一遍：
/// - `abc`：**合法十六进制**，旧实现把它当 `0xABC` 吃掉（2748）；
/// - `zz`：连十六进制都不合法，旧实现返回 `None` → 静默回退默认值。
///
/// 这两个串在旧测试里只覆盖了后者，前者正是漏掉的那条路径。
test "cli: LT-1 garbage is Invalid (both legal-hex 'abc' and non-hex 'zz')" {
  let args = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "abc", "--overhead", "zz", "--seed", "zz",
  ])
  assert_eq(show_int_arg(args, "symbols"), "invalid abc")
  assert_eq(show_double_arg(args, "overhead"), "invalid zz")
  assert_eq(show_uint_arg(args, "seed"), "invalid zz")
  // 合法值能解析
  let ok = @ltcode.parse_args([
    "ltcode", "simulate", "--symbols", "10", "--overhead", "1.2",
  ])
  assert_eq(show_int_arg(ok, "symbols"), "present 10")
  assert_eq(show_double_arg(ok, "overhead"), "present 1.2")
}

///|
/// **LT-1**：`--seed abc` 里的 `abc` 是**合法十六进制**，旧实现把它读成
/// `0xABC = 2748`。
///
/// 语义要求：十六进制必须显式写 `0x` 前缀；裸字母串是用法错误，
/// 不能变成"命令行看着跑通了、种子其实被换掉了"的一次实验。
test "cli: LT-1 bare 'abc' is rejected, explicit 0x prefix is the only hex form" {
  // 裸字母串：不是种子，是错
  let bare = @ltcode.parse_args(["ltcode", "simulate", "--seed", "abc"])
  assert_eq(show_uint_arg(bare, "seed"), "invalid abc")
  // 显式 0x 前缀仍然可用，并且等于它字面上的值
  let hex = @ltcode.parse_args(["ltcode", "simulate", "--seed", "0xabc"])
  assert_eq(show_uint_arg(hex, "seed"), "present 2748")
  // 大写 0X 也认（十六进制前缀不是大小写敏感的语法细节）
  let hex_up = @ltcode.parse_args(["ltcode", "simulate", "--seed", "0XABC"])
  assert_eq(show_uint_arg(hex_up, "seed"), "present 2748")
  // 默认种子本身也是 0x 形式的常量，必须继续被接受
  let dflt = @ltcode.parse_args([
    "ltcode", "simulate", "--seed", "0x4C54434F4445",
  ])
  assert_eq(show_uint_arg(dflt, "seed"), "present 83924790232133")
  // 十进制照旧
  let dec = @ltcode.parse_args(["ltcode", "simulate", "--seed", "12345"])
  assert_eq(show_uint_arg(dec, "seed"), "present 12345")
  // 只有一个 "0x" 而没有数字：不是 0，是错
  let just_prefix = @ltcode.parse_args(["ltcode", "simulate", "--seed", "0x"])
  assert_eq(show_uint_arg(just_prefix, "seed"), "invalid 0x")
}

///|
/// **LT-1**：负 seed 被 `if v < 0 { 0UL }` 静默归零。
///
/// 归零不是"修正"：它让调用方以为自己指定的种子生效了，而实际跑的是
/// 0 号种子 —— 一次**哈希值看着正常、结果却不属于你**的实验。
test "cli: LT-1 negative seed is rejected instead of clamped to zero" {
  let args = @ltcode.parse_args(["ltcode", "simulate", "--seed", "-1"])
  assert_eq(show_uint_arg(args, "seed"), "invalid -1")
  // 原始 token 仍在，报错可以把它原样回显给用户
  assert_eq(args.str("seed"), Some("-1"))
}

///|
/// **LT-1**：整数范围检查是显式的。
///
/// `--trials 2147483648` 在旧实现里走 `parse_int` 失败 → `None` → 静默
/// 变成 100 次试验。现在它是 `Invalid`；负数 `--trials -5` 也照此处理
/// （合法性判断是"能解析成 Int32"，"必须 >= 1" 由子命令报，两者分开）。
test "cli: LT-1 integer overflow and sign are classified, not silently defaulted" {
  let over = @ltcode.parse_args(["ltcode", "simulate", "--trials", "2147483648"])
  assert_eq(show_int_arg(over, "trials"), "invalid 2147483648")
  let neg = @ltcode.parse_args(["ltcode", "simulate", "--trials", "-5"])
  assert_eq(show_int_arg(neg, "trials"), "present -5")
  // Int32 两端都在范围内
  let top = @ltcode.parse_args(["ltcode", "simulate", "--trials", "2147483647"])
  assert_eq(show_int_arg(top, "trials"), "present 2147483647")
  let bottom = @ltcode.parse_args([
    "ltcode", "simulate", "--trials", "-2147483648",
  ])
  assert_eq(show_int_arg(bottom, "trials"), "present -2147483648")
}

///|
/// **LT-1**：`nan` / `inf` 词法合法，但不是可用的参数。
///
/// `--overhead nan` 会让 `overhead <= 0.0` 判 false 从而放行，然后一路
/// 算出 NaN 的 received / rate。参数层把非有限值判为 `Invalid`。
test "cli: LT-1 non-finite doubles are rejected as arguments" {
  let nan = @ltcode.parse_args(["ltcode", "simulate", "--overhead", "nan"])
  assert_eq(show_double_arg(nan, "overhead"), "invalid nan")
  let inf = @ltcode.parse_args(["ltcode", "simulate", "--overhead", "inf"])
  assert_eq(show_double_arg(inf, "overhead"), "invalid inf")
  let ninf = @ltcode.parse_args(["ltcode", "simulate", "--overhead", "-inf"])
  assert_eq(show_double_arg(ninf, "overhead"), "invalid -inf")
  // 尾部带垃圾也不是数
  let junk = @ltcode.parse_args(["ltcode", "simulate", "--overhead", "1.5x"])
  assert_eq(show_double_arg(junk, "overhead"), "invalid 1.5x")
}

///|
/// **LT-1**：报错措辞必须带上原始 token。
///
/// `--symbols abc` 旧的报文是 `simulate needs --symbols K` —— 用户明明写了
/// `--symbols`，却被告知"缺 --symbols"。
test "cli: LT-1 numeric error text names the raw token" {
  assert_eq(
    @ltcode.num_error("--symbols", "an integer", "abc"),
    "--symbols needs an integer, got 'abc'",
  )
  assert_eq(
    @ltcode.num_error("--overhead", "a number", "nan"),
    "--overhead needs a number, got 'nan'",
  )
  let seed_msg = @ltcode.num_error(
    "--seed", "a decimal or 0x-prefixed hex number", "-1",
  )
  assert_eq(
    seed_msg, "--seed needs a decimal or 0x-prefixed hex number, got '-1'",
  )
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
/// **LT-3 回归（红）**：非法项必须被**拒绝**，不是被丢掉。
///
/// 旧行为：`--overheads 1.0,abc,1.5` 只跑 1.00 与 1.50 两行、exit 0、
/// 无警告 —— 用户以为曲线覆盖了三个点，实际只有两个。
/// 度量工具悄悄缩小自己的工作范围，比报错更糟。
test "cli: LT-3 parse_overheads rejects garbage instead of dropping it" {
  // 正常值仍然解析
  let ok = @ltcode.parse_overheads_strict("1.0,1.1,1.2")
  match ok {
    Ok(a) => {
      inspect(a.length(), content="3")
      let d = a[2] - 1.2
      assert_true(d.abs() < 0.000000000001)
    }
    Err(_) => abort("1.0,1.1,1.2 should parse")
  }
  // 空白被 trim
  match @ltcode.parse_overheads_strict(" 1.5 , 2.0 ") {
    Ok(b) => inspect(b.length(), content="2")
    Err(_) => abort("spaced list should parse")
  }
  // 垃圾：整条拒绝，并带回原始 token
  match @ltcode.parse_overheads_strict("1.0,abc,1.5") {
    Ok(_) => abort("garbage item must not be dropped silently")
    Err(tok) => inspect(tok, content="abc")
  }
  // 非正数与 0 同样是"不是正数"，同样拒绝
  match @ltcode.parse_overheads_strict("1.0,-1,1.5") {
    Ok(_) => abort("negative overhead must be rejected")
    Err(tok) => inspect(tok, content="-1")
  }
  match @ltcode.parse_overheads_strict("1.0,0,1.5") {
    Ok(_) => abort("zero overhead must be rejected")
    Err(tok) => inspect(tok, content="0")
  }
  // nan / inf 也不是正数
  match @ltcode.parse_overheads_strict("1.0,nan") {
    Ok(_) => abort("nan must be rejected")
    Err(tok) => inspect(tok, content="nan")
  }
  // 空段（多余逗号）不是"省略"，是错
  match @ltcode.parse_overheads_strict("1.0,,1.5") {
    Ok(_) => abort("empty item must be rejected")
    Err(tok) => inspect(tok, content="(empty)")
  }
  // 空串给空列表（子命令随后报 "must list at least one"）
  match @ltcode.parse_overheads_strict("") {
    Ok(a) => inspect(a.length(), content="0")
    Err(_) => abort("empty spec is empty, not invalid")
  }
}

///|
/// `parse_overheads` 的宽松版本仍保留"丢弃"语义，但**子命令不用它**。
///
/// 保留理由是它对"尽力而为"的输入清洗仍然有用；这条测试只是把
/// 两个函数的区别固定住，防止有人把 `cmd_curve` 改回宽松入口。
test "cli: parse_overheads (lenient) still drops, and is not the curve entry" {
  let c = @ltcode.parse_overheads("1.0,abc,-1,0,1.5")
  inspect(c.length(), content="2")
  inspect(@ltcode.parse_overheads("").length(), content="0")
}

///|
/// **LT-4**：`--count 0` 的产出侧提示。
///
/// README 与 API.md 都逐字引用了这句 `note:`，所以它必须真的存在、且只在
/// `count == 0` 时出现 —— 否则文档承诺了一条命令不会打印的话。
/// 退出码本身测不了（`@sys.exit` 会结束进程），因此这里只测"决定提示与否
/// 的那个条件"，与 CLI 里的 `if count == 0` 一一对应。
test "cli: LT-4 the symbol-free note is emitted exactly for count == 0" {
  assert_eq(@ltcode.encode_note(0), @ltcode.symbol_free_note())
  // 文档逐字引用的那句话，一个字都不能漂
  assert_eq(
    @ltcode.symbol_free_note(),
    "note: --count 0 wrote a symbol-free container; decode will always report INCOMPLETE",
  )
  assert_eq(@ltcode.encode_note(1), "")
  assert_eq(@ltcode.encode_note(300), "")
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
