///|
/// LT31（2026-11-21 审计）：`--key` 缺值时必须报「缺值」，不能被下一个
/// `--flag` **当值吃掉**。
///
/// `parse_args` 修复前对 `--key`（无 `=`）无条件消费下一个 token：
///
/// ```
/// $ ltcode encode --out --count 5 --input in.bin --symbols 10
/// ltcode: unexpected positional argument '5'; every argument to encode must be a named --option
/// ```
///
/// `--count` 被当成 `--out` 的**文件名**（用户看到的位置参数错误指错了对象），
/// 更糟的是 `--out` 的值成了 `--count`，写文件失败会报
/// `cannot write '--count'`（退出码 3，看起来像输入坏了）。
///
/// 修复：下一 token 以 `--` 开头时**不消费**（记为缺值）；空值视为缺失，
/// 于是 `--out` / `--input` 走各自的 `needs --X`（退出码 2）。

///|
fn argnum_int_text(args : Args, key : String) -> String {
  match args.int(key) {
    Absent => "Absent"
    Present(v) => "Present(\{v})"
    Invalid(raw) => "Invalid(\{raw})"
  }
}

///|
test "LT31: a flag-looking token is not swallowed as the previous value" {
  let args = parse_args(["ltcode", "encode", "--out", "--count", "5"])
  // 修复前：map["out"] = "--count"，"5" 变成位置参数。
  inspect(args.str("out"), content="None")
  inspect(argnum_int_text(args, "count"), content="Present(5)")
  inspect(args.positional.length(), content="0")
}

///|
test "LT31: a trailing option without a value reads as missing" {
  let args = parse_args(["ltcode", "decode", "--input"])
  // 修复前是 Some("")，CLI 会拿空路径去读文件（"cannot read ''"，exit 3）。
  inspect(args.str("input"), content="None")
}

///|
test "LT31: explicit empty and normal values keep working" {
  let args = parse_args([
    "ltcode", "encode", "--input=in.bin", "--out", "x.ltc", "--symbols", "10",
  ])
  inspect(args.str("input"), content="Some(in.bin)")
  inspect(args.str("out"), content="Some(x.ltc)")
  inspect(args.str("symbols"), content="Some(10)")
  assert_true(args.positional.length() == 0)
}
