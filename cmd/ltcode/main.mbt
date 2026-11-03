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
  sb.write_string("  ltcode decode   --input <file> --out <file> ")
  sb.write_string("[--symbols K] [--seed S]\n")
  sb.write_string("  ltcode simulate --symbols K --overhead O --trials T ")
  sb.write_string("[--seed S]\n")
  sb.write_string("  ltcode curve    --symbols K --overheads a,b,c --trials T ")
  sb.write_string("[--seed S]\n")
  sb.write_string("  ltcode distcmp  --symbols K --overhead O --trials T ")
  sb.write_string("[--seed S]\n")
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
/// 多余参数」。因此这里没有 `rest` 字段 —— 早先版本有一个但从未被读取，
/// 留着只会让「多写的参数去哪了」变成一个谜。
pub struct Args {
  map : Map[String, String]
}

///|
pub fn parse_args(argv : Array[String]) -> Args {
  let map : Map[String, String] = Map([])
  let mut i = 1 // argv[0] 是可执行文件路径
  while i < argv.length() {
    let a = argv[i]
    if a.has_prefix("--") {
      let body = a.view(start_offset=2).to_owned()
      match body.find("=") {
        Some(eq) => {
          let key : String = body.view(end_offset=eq).to_owned()
          let value : String = body.view(start_offset=eq + 1).to_owned()
          map[key] = value
        }
        None =>
          if i + 1 < argv.length() {
            map[body] = argv[i + 1]
            i = i + 1
          } else {
            map[body] = ""
          }
      }
    }
    i = i + 1
  }
  { map, }
}

///|
pub fn Args::str(self : Args, key : String) -> String? {
  self.map.get(key)
}

///|
pub fn Args::int(self : Args, key : String) -> Int32? {
  match self.map.get(key) {
    None => None
    Some(s) => Some(@strconv.parse_int(s)) catch { _ => None }
  }
}

///|
pub fn Args::uint64(self : Args, key : String) -> UInt64? {
  match self.map.get(key) {
    None => None
    Some(s) =>
      try {
        let v = @strconv.parse_int(s)
        Some(if v < 0 { 0UL } else { v.to_uint64() })
      } catch {
        // 也接受 0x 前缀的十六进制种子，便于手工指定大种子
        _ =>
          Some(@strconv.parse_int64(s, base=16).to_uint64()) catch {
            _ => None
          }
      }
  }
}

///|
pub fn Args::double(self : Args, key : String) -> Double? {
  match self.map.get(key) {
    None => None
    Some(s) => Some(@strconv.parse_double(s)) catch { _ => None }
  }
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
