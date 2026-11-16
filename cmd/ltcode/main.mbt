///|
/// `ltcode` CLI。
///
/// 用法（PLAN.md §9）：
///
/// ```
/// ltcode encode  --input <file> --symbols K --seed S --count N --out <file>
/// ltcode decode  --input <file> --symbols K --seed S --out <file>
/// ltcode simulate --symbols K --overhead 1.2 --trials 100 --seed S
/// ltcode curve    --symbols K --overheads 1.0,1.1,1.2,1.5 --trials 100 --seed S
/// ```
///
/// 退出码：0 成功 / 1 解码失败（数据不足）/ 2 用法错误 / 3 输入错误。
///
/// 设计取舍：`decode` **不需要** `--symbols` / `--seed`（文件自描述）。
/// PLAN 的签名里带了它们，但如果强制要求，那张「解码只需要这个文件」的
/// 契约就成了空话。因此这两个参数是**可选覆盖**：给了就核对，不一致时报错
/// （防手滑），不给就从文件读。

///|
fn usage() -> String {
  let sb = StringBuilder()
  sb.write_string("ltcode — rateless erasure coding (Luby Transform)\n")
  sb.write_string("\n")
  sb.write_string("  ltcode encode   --input <file> --symbols K [--seed S] ")
  sb.write_string("[--count N] [--out <file>]\n")
  sb.write_string("  ltcode decode   --input <file> [--out <file>] ")
  sb.write_string("[--symbols K] [--seed S]\n")
  sb.write_string("  ltcode simulate --symbols K --overhead O [--trials T] ")
  sb.write_string("[--seed S] [--symbol-len N]\n")
  sb.write_string(
    "  ltcode curve    --symbols K --overheads a,b,c [--trials T] ",
  )
  sb.write_string("[--seed S] [--symbol-len N]\n")
  sb.write_string("  ltcode distcmp  --symbols K --overhead O [--trials T] ")
  sb.write_string("[--seed S] [--symbol-len N]\n")
  sb.write_string("\n")
  // 可解性验算的边界必须出现在 help 里（LT1，2026-11-12 followup）：
  // `encode` 末尾会试解一次，但只在 `--count <= 4096` 时做。不写明的话
  // 「encode 没打印提示」会被读成「这份容器一定能解码」—— 那正是
  // best-effort 与 guarantee 的区别，也是最容易误会的一句。
  sb.write_string(
    "  note: encode checks solvability up to --count 4096 (best effort, not a guarantee)\n",
  )
  sb.write_string("\n")
  sb.write_string("  exit 0 = ok, 1 = decode incomplete, 2 = usage, ")
  sb.write_string("3 = bad input\n")
  sb.to_string()
}

///|
/// 退出码常量（集中定义，避免散落的魔数）。
fn exit_ok() -> Unit {
  @sys.exit(0)
}

///|
fn exit_incomplete() -> Unit {
  @sys.exit(1)
}

///|
fn exit_usage() -> Unit {
  @sys.exit(2)
}

///|
fn exit_bad_input() -> Unit {
  @sys.exit(3)
}

///|
/// 简单参数表：`--k v` 或 `--k=v`。
///
/// 位置参数（不以 `--` 开头）**不接受**：本 CLI 的每个子命令都要求显式
/// 命名参数，这样 `ltcode encode foo` 会被当作错误而不是「碰巧被忽略的
/// 多余参数」。
///
/// **但"不接受"必须真的被检查**（LT-F，2026-11-10 审计）。修复前这里只
/// 把位置参数**跳过**、对未知 `--key` 从不检查，于是：
///
/// ```
/// ltcode decode --input x.ltc --out y.bin --seedx 999999   → exit 0
/// ltcode decode --input x.ltc --out y.bin some-junk        → exit 0
/// ```
///
/// 前者最危险：用户以为指定了种子核对（`--seedx` 是 `--seed` 的笔误），
/// 而那个核对根本没跑 —— 命令行的"成功"掩盖了一个手动核对项的静默失效。
/// 后者与上面那句注释直接矛盾：承诺的行为从来没被实现。
///
/// 因此 `Args` 现在记录两样东西：
/// - `positional`：全部位置参数（原位 token，供报错回显）
/// - `order`：**按 argv 出现顺序**记录的键名（报错时按这个顺序找第一个
///   未知键，而不是按 `Map` 的哈希序 —— 否则报哪个会随机变，脚本按文本
///   匹配就会失效）
pub struct Args {
  map : Map[String, String]
  positional : Array[String]
  order : Array[String]
}

///|
pub fn parse_args(argv : Array[String]) -> Args {
  let map : Map[String, String] = Map([])
  let positional : Array[String] = []
  let order : Array[String] = []
  // argv[0] 是可执行文件路径，argv[1] 是子命令 —— 两者都不是"参数"。
  // 修复前从 1 开始扫，`decode` 自己会被当成位置参数；现在从 2 开始。
  let mut i = 2
  while i < argv.length() {
    let a = argv[i]
    if a.has_prefix("--") {
      let body = a.clamped_view(start=2, end=a.length()).to_owned()
      match body.find("=") {
        Some(eq) => {
          let key : String = body.clamped_view(start=0, end=eq).to_owned()
          let value : String = body
            .clamped_view(start=eq + 1, end=body.length())
            .to_owned()
          map[key] = value
          order.push(key)
        }
        None => {
          map[body] = if i + 1 < argv.length() {
            let v = argv[i + 1]
            i = i + 1
            v
          } else {
            ""
          }
          order.push(body)
        }
      }
    } else {
      // 位置参数：不再静默跳过，记下来交给 unknown_arg_error 报错
      positional.push(a)
    }
    i = i + 1
  }
  { map, positional, order, }
}

///|
/// 每个子命令**接受**的键。
///
/// 集中定义而不是散在子命令里，是因为这张表就是"命令行契约"的一份声明：
/// 看一眼就该知道某个参数属于哪个命令。`decode` 的 `--symbols` / `--seed`
/// 是**可选核对项**（文件自描述），因此它们出现在 decode 里。
pub fn accepted_keys(cmd : String) -> Array[String] {
  match cmd {
    "encode" => ["input", "symbols", "seed", "count", "out"]
    "decode" => ["input", "out", "symbols", "seed"]
    "simulate" => ["symbols", "overhead", "trials", "seed", "symbol-len"]
    "curve" => ["symbols", "overheads", "trials", "seed", "symbol-len"]
    "distcmp" => ["symbols", "overhead", "trials", "seed", "symbol-len"]
    // help 不接受任何参数
    _ => []
  }
}

///|
/// 把 `Args` 里**不属于**该子命令的东西挑出来，返回可直接当用法错误
/// 打印的文本；干净时返回空串（与 `encode_note` / 各 guard 同形状）。
///
/// 报错带上**原始 token**：
/// - 未知键 → `--seedx`（带 `--` 前缀，用户能直接对上自己写的）
/// - 位置参数 → `some-junk`（原样）
///
/// 多个问题时按 argv 顺序报**第一个**：一次只说一件事，用户改完再看下一件。
/// 全列出来会让本就写错的命令行更难读。
pub fn unknown_arg_error(args : Args, cmd : String) -> String {
  let allowed = accepted_keys(cmd)
  let mut i = 0
  while i < args.order.length() {
    let key = args.order[i]
    if !allowed.contains(key) {
      return "unknown option '--\{key}' for \{cmd}; run 'ltcode help' for the accepted options"
    }
    i = i + 1
  }
  if args.positional.length() > 0 {
    let tok = args.positional[0]
    return "unexpected positional argument '\{tok}'; every argument to \{cmd} must be a named --option"
  }
  ""
}

///|
pub fn Args::str(self : Args, key : String) -> String? {
  self.map.get(key)
}

///|
/// 数值参数的**三态**取值。
///
/// LT-1 的根因就是这里只有两态：`None` 同时表示"没给这个参数"和"给了，
/// 但给的是一坨垃圾"。调用方没法区分，于是只能 `unwrap_or(默认值)` ——
/// `--trials abc` 静默跑 100 次试验，命令行看着"成功"了。
///
/// 现在把三种情况分开：
/// - `Absent`   → 调用方用默认值（合法）
/// - `Present`  → 拿到真值
/// - `Invalid`  → 用法错误（exit 2），并带上**原始 token**，
///                这样报错能说出用户到底写了什么（`got 'abc'`），
///                而不是一句"参数不对"让人回去猜。
pub(all) enum ArgNum[T] {
  Absent
  Present(T)
  Invalid(String)
}

///|
/// 从 `start` 起的子串（参数值的"去掉前缀"用）。
fn tail_from(s : String, start : Int32) -> String {
  s.exact_view(start~, end=s.length()).to_owned()
}

///|
/// 无符号十进制扫描：只认 `0`-`9`，溢出返回 `None`。
///
/// **手写而不用 `@strconv`**：`@strconv.parse_int` / `parse_int64` 的 base
/// 推断与"前缀可选"行为正是 LT-1 的来源 —— `parse_int64("abc", base=16)`
/// 合法返回 2748，`parse_int("0x10")` 合法返回 16。参数层需要的恰恰相反：
/// 一个 token 属于哪种进制**只能由 token 自己显式声明**（`0x` 前缀），
/// 不能被解析器猜。这里把猜测权收回，只有 base 由调用方写死。
fn scan_uint_digits(s : String, base : UInt64) -> UInt64? {
  if s.length() == 0 {
    return None
  }
  let max : UInt64 = 18446744073709551615UL
  let mut acc = 0UL
  for ch in s {
    let code = ch.to_int()
    let digit = if code >= 48 && code <= 57 {
      code - 48
    } else if code >= 97 && code <= 102 {
      // 'a'..'f'
      code - 87
    } else if code >= 65 && code <= 70 {
      // 'A'..'F'
      code - 55
    } else {
      -1
    }
    if digit < 0 {
      return None
    }
    let d = digit.to_uint64()
    if d >= base {
      return None
    }
    // 溢出检查写在乘法之前：acc * base + d 一旦越界就不再是"这个数"了
    if acc > (max - d) / base {
      return None
    }
    acc = acc * base + d
  }
  Some(acc)
}

///|
/// 严格十进制 `Int32`：可有一个前导 `-`，其余必须是十进制数字，
/// 且结果必须落在 `Int32` 范围内（`2147483648` 报错，不静默回绕成负数）。
fn scan_int32(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let negative = s.has_prefix("-")
  let body = if negative { tail_from(s, 1) } else { s }
  // "+100" 不是本项目接受的写法：符号只用于表示负数
  if body.length() == 0 || body.has_prefix("+") || body.has_prefix("-") {
    return None
  }
  let magnitude = match scan_uint_digits(body, 10UL) {
    None => return None
    Some(v) => v
  }
  if negative {
    if magnitude > 2147483648UL {
      return None
    }
    // 边界单独写：`2147483648` 没有对应的正 Int32，但 `-2147483648` 合法
    if magnitude == 2147483648UL {
      return Some(-2147483648)
    }
    return Some(0 - magnitude.to_int())
  }
  if magnitude > 2147483647UL {
    return None
  }
  Some(magnitude.to_int())
}

///|
/// `--seed` 的取值规则：十进制，或**显式 `0x` / `0X` 前缀**的十六进制。
///
/// 裸字母串（`abc`）不是"一个可以猜出进制的数"，它是错 —— 这正是 LT-1。
/// 负号也不接受：种子是无符号的，`-1` 归零等于偷偷换了种子。
pub fn parse_seed_token(raw : String) -> UInt64? {
  if raw.length() == 0 {
    return None
  }
  if raw.has_prefix("0x") || raw.has_prefix("0X") {
    // "0x" 后面必须真有一串十六进制数字
    if raw.length() == 2 {
      return None
    }
    return scan_uint_digits(tail_from(raw, 2), 16UL)
  }
  scan_uint_digits(raw, 10UL)
}

///|
pub fn Args::int(self : Args, key : String) -> ArgNum[Int32] {
  match self.map.get(key) {
    None => Absent
    Some(raw) =>
      match scan_int32(raw) {
        Some(v) => Present(v)
        None => Invalid(raw)
      }
  }
}

///|
pub fn Args::uint64(self : Args, key : String) -> ArgNum[UInt64] {
  match self.map.get(key) {
    None => Absent
    Some(raw) =>
      match parse_seed_token(raw) {
        Some(v) => Present(v)
        None => Invalid(raw)
      }
  }
}

///|
/// 浮点参数：`@strconv.parse_double` 负责词法（它不会吃掉尾部垃圾，
/// `"1.5x"` 报错），但**必须自己挡掉非有限值**：`nan` / `inf` 在词法上
/// 合法，在语义上是垃圾 —— `--overhead nan` 会让 `overhead <= 0.0` 这个
/// 检查判 false 从而放行，然后一路算出 NaN 的 received。
/// 参数层不接受"能解析但不是数"的东西。
pub fn parse_finite_double(raw : String) -> Double? {
  let v = Some(@strconv.parse_double(raw)) catch { _ => None }
  match v {
    None => None
    Some(d) =>
      // `nan` / `inf` 在词法上合法、在语义上是垃圾：`--overhead nan` 会让
      // `overhead <= 0.0` 判 false 从而放行，然后算出 NaN 的 received。
      if d.is_nan() || d.is_inf() {
        None
      } else {
        Some(d)
      }
  }
}

///|
pub fn Args::double(self : Args, key : String) -> ArgNum[Double] {
  match self.map.get(key) {
    None => Absent
    Some(raw) =>
      match parse_finite_double(raw) {
        Some(v) => Present(v)
        None => Invalid(raw)
      }
  }
}

///|
/// 数值参数的用法错误文本（一处定义，五个子命令共用）。
///
/// 措辞带**原始 token**：`--symbols needs an integer, got 'abc'`。
/// 只说"需要一个整数"会让用户回头怀疑自己是不是没写这个参数 ——
/// 而那句话正是 LT-1 里 `--symbols abc` 报出的误导性报文。
pub fn num_error(key : String, kind : String, raw : String) -> String {
  "\{key} needs \{kind}, got '\{raw}'"
}

///|
/// 报错到 stdout，措辞统一（`ltcode: ...`）。
fn arg_error(msg : String) -> Unit {
  println("ltcode: \{msg}")
}

///|
fn main {
  let argv = @env.args()
  if argv.length() < 2 {
    println(usage())
    exit_usage()
    return
  }
  let cmd = argv[1]
  let args = parse_args(argv)
  match cmd {
    "encode" => cmd_encode(args)
    "decode" => cmd_decode(args)
    "simulate" => cmd_simulate(args)
    "curve" => cmd_curve(args)
    "distcmp" => cmd_distcmp(args)
    "help" => {
      // help 也走同一道检查：`ltcode help --verbose` 里的 --verbose 没有
      // 去处，静默忽略等于让「我明明加了参数」变成一个谜。
      let msg = unknown_arg_error(args, "help")
      if !msg.is_empty() {
        arg_error(msg)
        exit_usage()
        return
      }
      println(usage())
      exit_ok()
    }
    _ => {
      arg_error("unknown command '\{cmd}'")
      println(usage())
      exit_usage()
    }
  }
}
