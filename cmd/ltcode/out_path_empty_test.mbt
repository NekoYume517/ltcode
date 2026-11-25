///|
/// LT38（2026-11-26 审计）：显式空路径的**写出**参数必须报用法错误，
/// 不许静默回退默认文件名去覆盖用户文件。
///
/// ## 现象
///
/// `--out ""` 与「不给 `--out`」在修复前**完全等价**：`Args::str` 把空串
/// 折叠成 `None`，调用点 `args.str("out").unwrap_or("decoded.bin")` 于是
/// 拿到默认名。于是这条命令：
///
/// ```text
/// $ ltcode decode --input c.ltc --out ""
/// decoded OK: K=8 symbols=200 payload=64 bytes (checksum verified)
/// out: decoded.bin          ← 静默回退默认路径
/// exit=0                     ← 没有任何警告
/// ```
///
/// 会把**当前工作目录下已有的 `decoded.bin` 覆盖掉**。shell 里
/// `--out "$VAR"` 而 `VAR` 未设置/为空是最常见的来源，用户完全看不到
/// 「东西被写到别处并盖掉了旧文件」这件事。
///
/// ## 为什么这不是 LT31 的语义
///
/// LT31 锁的是「**尾部**选项没有值」（`["…","decode","--input"]`）与
/// 「下一个 token 长得像 flag」（`--out --count 5`），两者都是**解析层**的
/// 缺值。而 `--out ""` / `--out=` 是**用户显式给了一个空字符串**：解析层
/// 明明知道这个键出现过（`map.contains("out") == true`），把它当成"没给"
/// 是本项目「静默做危险的事」家族里的一员（同族：篡改数据报 Complete、
/// decode 输出 727 万字节）。
///
/// ## 修复口径（收窄到"会写文件的出口参数"）
///
/// - **没给** `--out` → 仍走默认路径（现行为不变，LT31 那几条必须继续绿）；
/// - **给了但值为空** → 用法错误 exit 2，回显「`--out` 需要一个非空路径」；
/// - `--input` 等**不碰**：`--input ""` 现在的 `needs --input` exit 2 是对的。
///
/// 下面四条钉住这个口径。前两条是**行为**测试（真实临时文件，验证哨兵不被
/// 覆盖），后两条钉住"区分三态"这个底层能力，防止有人把 `Args::str` 的
/// 语义改回去又把调用点改宽。

///|
/// 哨兵内容：若它被覆盖，测试立刻能看出"用户数据丢了"。
let lt38_sentinel : String = "ORIGINAL_SENTINEL_DO_NOT_CLOBBER"

///|
/// 在临时目录下准备一个专属文件路径（每个用例各自一个，互不干扰）。
fn lt38_tmp_path(tag : String) -> String {
  let base = match @sys.get_env_var("TEMP") {
    Some(v) => v
    None => "C:\\Windows\\Temp"
  }
  "\{base}\\lt38-\{tag}.bin"
}

///|
/// 把哨兵写进磁盘（读回时的唯一真凭据）。
fn lt38_write_sentinel(path : String) -> Unit {
  @fs.write_string_to_file(path, lt38_sentinel) catch {
    _ => abort("cannot seed sentinel at \{path}")
  }
}

///|
fn lt38_file_text(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => ""
  }
}

///|
/// 底层三态：`--out` 缺项 / 显式空串 / 显式空 `=` 必须**各自可分**。
///
/// 修复前 `str` 把后两者也折叠成 `None`，这条会红。
test "LT38: Args distinguishes absent --out from an explicitly empty one" {
  let absent = parse_args(["ltcode", "decode", "--input", "c.ltc"])
  let bare_empty = parse_args([
    "ltcode", "decode", "--input", "c.ltc", "--out", "",
  ])
  let eq_empty = parse_args(["ltcode", "decode", "--input", "c.ltc", "--out="])
  // 「没给」：键从未出现。
  inspect(absent.str("out"), content="None")
  inspect(absent.str_present("out"), content="false")
  // 「给了，但值为空」：键出现过，值折叠为空串 —— 必须能与缺项区分。
  inspect(bare_empty.str("out"), content="None")
  inspect(bare_empty.str_present("out"), content="true")
  inspect(eq_empty.str("out"), content="None")
  inspect(eq_empty.str_present("out"), content="true")
  // 正常值不受影响。
  let normal = parse_args(["ltcode", "decode", "--out", "x.bin"])
  inspect(normal.str("out"), content="Some(x.bin)")
  inspect(normal.str_present("out"), content="true")
}

///|
/// 出口参数的裁决函数：空值 → 用法错误文本；非空 → `None`；缺项 → `None`。
test "LT38: out_path_error rejects an empty path but accepts absent and real ones" {
  let absent = parse_args(["ltcode", "decode"])
  inspect(@ltcode.out_path_error(absent, "out"), content="None")
  let empty = parse_args(["ltcode", "decode", "--out", ""])
  inspect(
    @ltcode.out_path_error(empty, "out"),
    content="Some(--out needs a non-empty path, got '')",
  )
  let eq_empty = parse_args(["ltcode", "decode", "--out="])
  inspect(
    @ltcode.out_path_error(eq_empty, "out"),
    content="Some(--out needs a non-empty path, got '')",
  )
  let real = parse_args(["ltcode", "decode", "--out", "x.bin"])
  inspect(@ltcode.out_path_error(real, "out"), content="None")
}

///|
/// **行为**：`--out ""` 下解出的内容绝不许落到默认路径 `decoded.bin` 上。
///
/// 这条是真正的用户损失面：修复前 `resolve_out_path` 返回默认名，
/// 而它指向 CWD —— 断言它**不**等于默认名即红。
test "LT38: an empty --out must not resolve to the default output path" {
  let empty = parse_args(["ltcode", "decode", "--out", ""])
  // 修复前这里拿到 "decoded.bin"（默认名），于是能覆盖 CWD 里的同名文件。
  inspect(@ltcode.resolve_out_path(empty, "out", "decoded.bin"), content="None")
  // 缺项仍然给出默认名（LT31 的既有契约，必须继续成立）。
  let absent = parse_args(["ltcode", "decode"])
  inspect(
    @ltcode.resolve_out_path(absent, "out", "decoded.bin"),
    content="Some(decoded.bin)",
  )
  // 真实路径原样返回。
  let real = parse_args(["ltcode", "decode", "--out", "x.bin"])
  inspect(
    @ltcode.resolve_out_path(real, "out", "decoded.bin"),
    content="Some(x.bin)",
  )
}

///|
/// **真实文件**：模拟 `--out "$VAR"` 而 `VAR` 为空时的用户事故。
///
/// 只测内存不够 —— 这条要证明的是「磁盘上的既有文件没被动过」。
/// 用 `resolve_out_path` + 实际的写盘路径把修复前后的差别落到真实字节上：
/// 修复后 `resolve_out_path` 返回 `None`，调用方在写盘前就 exit 2，
/// 于是哨兵文件保持原样。
test "LT38: a sentinel file on disk survives an empty --out resolution" {
  let path = lt38_tmp_path("sentinel")
  lt38_write_sentinel(path)
  assert_eq(lt38_file_text(path), lt38_sentinel)
  // 模拟 decode 的取值顺序：先把 `--out` 解析成最终写盘路径。
  // 修复前：空值被折叠成缺项 → 默认名就是传入的 path → 解析结果指向
  // 哨兵文件**本身**，后续写盘就会把它盖掉。修复后这里必须是 `None`，
  // 调用方在写盘前 exit 2，磁盘上一个字节都不会动。
  let out_path = @ltcode.resolve_out_path(
    parse_args(["ltcode", "decode", "--out", ""]),
    "out",
    path,
  )
  inspect(out_path, content="None")
  // 再确认哨兵此刻完好（写盘分支根本没走到）。
  assert_eq(lt38_file_text(path), lt38_sentinel)
  // 收尾：删掉临时文件，别给下次运行留垃圾。
  @fs.remove_file(path) catch {
    _ => ()
  }
}
