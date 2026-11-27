///|
/// LT46（2026-11-27 审计）：重复 `--key` 必须报用法错误，不许静默「后者胜出」。
///
/// ## 现象（修复前）
///
/// `parse_args` 对同一个键第二次出现时执行 `map[key] = value`，无条件覆盖。
/// 于是：
///
/// ```text
/// $ ltcode decode --input good.ltc --out a.bin --out b.bin
/// decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
/// out: b.bin          ← a.bin 从未被写
/// exit=0              ← 没有任何警告
/// ```
///
/// `a.bin` 一个字节都没出现，退出码却是 0。这与 LT-F（未知 `--flag` 被静默
/// 接受）、LT38（`--out ""` 静默回退默认名）是同一族缺陷：**命令行上写了
/// 什么，就必须要么全部生效、要么明确报错**。脚本里
/// `--out "$A" --out "$B"`（两个变量都非空，比如循环拼接出错）会让 A 被
/// 静默丢弃，而下游读 `.bin` 的步骤读到的却是 B 的内容 —— 静默的数据错位。
///
/// **为什么不能靠「值冲突校验」兜住**：`--symbols` 重复会被
/// 「does not match container K」抓到，但那是因为 K 恰好可交叉核对。
/// `--out` / `--input` 没有任何可核对的参照物，所以必须在这层拒绝。
///
/// ## 判据（双向）
///
/// - 重复的 `--out`：`parse_args` 记下该键出现了两次；`duplicate_arg_error`
///   返回非空文本，且文本**点名那个键与它的出现次数**。
/// - 每个子命令的每个可接受键都要能被报出来（不能只硬编码 `out`）。
/// - 不重复时返回空串（合法输入 must 接）。
/// - 只有一次出现的键即使值相同也不算重复（去重按**出现次数**，不按值）。
test "LT46: duplicate --key is reported with the key name and count" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--out", "a.bin", "--out", "b.bin",
  ])
  let msg = @ltcode.duplicate_arg_error(args)
  assert_true(msg != "")
  // 必须点名那个键（用户要能直接对上自己写的那两处）
  assert_true(msg.contains("--out"))
  // 必须说明出现了两次 —— 只写"重复"不写次数，用户无法判断是不是自己写错了
  assert_true(msg.contains("2"))
  // 不许把没重复的键点进来
  assert_true(!msg.contains("--input"))
}

///|
/// LT46：值相同也算重复。
///
/// 反复出现同一个键是**命令行本身有歧义**，与两次的值是否相同无关。
/// 若按值去重，`--out a --out a` 会被放行 —— 那只是把缺陷藏得更深。
test "LT46: identical values still count as duplicates" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--out", "a.bin", "--out", "a.bin",
  ])
  let msg = @ltcode.duplicate_arg_error(args)
  assert_true(msg != "")
  assert_true(msg.contains("--out"))
}

///|
/// LT46：不重复时返回空串（合法输入 must 接）。
test "LT46: no duplicate means empty message" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--input", "x.ltc", "--out", "a.bin", "--seed", "7",
  ])
  assert_eq(@ltcode.duplicate_arg_error(args), "")
}

///|
/// LT46：`=` 形式与分离形式混用也算重复。
///
/// `--out=a.bin --out b.bin` 在 `map` 里是同一个键，必须被同一份判据抓住
/// —— 否则「换个写法就能绕过」。
test "LT46: = form and separated form collide on the same key" {
  let args = @ltcode.parse_args([
    "ltcode", "decode", "--out=a.bin", "--out", "b.bin",
  ])
  let msg = @ltcode.duplicate_arg_error(args)
  assert_true(msg != "")
  assert_true(msg.contains("--out"))
}

///|
/// LT46：报错文本要说清「该怎么办」，而不是只说「错」。
test "LT46: duplicate message tells the user what to do" {
  let args = @ltcode.parse_args([
    "ltcode", "encode", "--out", "a.bin", "--out", "b.bin",
  ])
  let msg = @ltcode.duplicate_arg_error(args)
  // 必须给出可操作的动作（指定一次）
  assert_true(msg.contains("once"))
}
