///|
/// CLI 子命令实现。
///
/// 每个子命令自己负责：参数校验（用法错误 → 退出码 2）、输入校验
/// （文件读不到/格式不对 → 退出码 3）、业务结果（解码不足 → 退出码 1）。
///
/// **数值参数一律走 `req_*` / `opt_*` 两个助手**（LT-1 的修复）：
/// 它们把"没给"（用默认值或报缺项）和"给了垃圾"（报用法错误并带上原始
/// token）分开处理。子命令里不允许再出现 `args.int(..).unwrap_or(默认)`
/// —— 那正是 `--trials abc` 静默跑 100 次的写法。

///|
/// 必需整数参数。缺 → `missing` 文本；非法 → `--key needs an integer, got '..'`。
///
/// 返回 `None` 表示**已经报过错**，调用方负责 `exit_usage()` 并返回。
fn req_int(args : Args, key : String, missing : String) -> Int32? {
  match args.int(key) {
    Absent => {
      arg_error(missing)
      None
    }
    Invalid(raw) => {
      arg_error(num_error("--\{key}", "an integer", raw))
      None
    }
    Present(v) => Some(v)
  }
}

///|
/// 可选整数参数：没给就用默认值，给了垃圾照旧报错（不静默回退默认值）。
fn opt_int(args : Args, key : String, fallback : Int32) -> Int32? {
  match args.int(key) {
    Absent => Some(fallback)
    Invalid(raw) => {
      arg_error(num_error("--\{key}", "an integer", raw))
      None
    }
    Present(v) => Some(v)
  }
}

///|
/// 必需浮点参数。
fn req_double(args : Args, key : String, missing : String) -> Double? {
  match args.double(key) {
    Absent => {
      arg_error(missing)
      None
    }
    Invalid(raw) => {
      arg_error(num_error("--\{key}", "a number", raw))
      None
    }
    Present(v) => Some(v)
  }
}

///|
/// 可选种子：没给用默认常数，给了非法值报错（`--seed abc` / `--seed -1`）。
fn opt_seed(args : Args) -> UInt64? {
  match args.uint64("seed") {
    Absent => Some(@lib.default_seed())
    Invalid(raw) => {
      arg_error(num_error("--seed", "a decimal or 0x-prefixed hex number", raw))
      None
    }
    Present(v) => Some(v)
  }
}

///|
/// `--count` 的量级上限（LC-1，2026-11-08 审计）。
///
/// count 只查 < 0 时，`--count 2147483647` 进入 enc.symbols 的逐符号
/// 生成循环（度分布采样 + GF(256) 运算），实测 120 秒不终止 —— 既不是
/// 用法错误也不是数据错误，就是挂死。这里需要的不是溢出防护而是
/// **量级上限**：百万符号容器（每符号约 5+ 字节，数十 MB）已远超
/// 本项目「K 至多数千」的定位，超限一律用法错误并写明上限。
pub const LT_MAX_COUNT : Int32 = 1_000_000

///|
/// `--count 0` 产出无符号容器时打印的那句提示。
///
/// 抽成函数而非常量，是为了让 README / API.md 逐字引用的那句话有**唯一**
/// 定义处：文档与实现引同一份文本，改一处就得改另一处，不存在"文档说会
/// 打印、代码其实没打"的位置。
pub fn symbol_free_note() -> String {
  "note: --count 0 wrote a symbol-free container; decode will always report INCOMPLETE"
}

///|
/// 产出侧提示：`count == 0` 才有话说，其余情况是空串（调用方据此决定是否
/// 打印）。返回空串而不是 `Option`，是因为调用点只想 `println` 一次。
pub fn encode_note(count : Int32) -> String {
  if count == 0 {
    symbol_free_note()
  } else {
    ""
  }
}

///|
/// `encode`：读文件 → 切块 → 编码 N 个符号 → 写自描述容器。
fn cmd_encode(args : Args) -> Unit {
  let input = match args.str("input") {
    None => {
      arg_error("encode needs --input")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let k = match req_int(args, "symbols", "encode needs --symbols K") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  if k < 1 {
    arg_error("--symbols must be >= 1")
    exit_usage()
    return
  }
  let out_path = args.str("out").unwrap_or("\{input}.ltc")
  let seed = match opt_seed(args) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  // 默认 count = ceil(K * 1.5)：够本项目的默认参数成功，又不至于大得离谱
  let count = match args.int("count") {
    Absent => (k.to_double() * 1.5).to_int() + 1
    Invalid(raw) => {
      arg_error(num_error("--count", "an integer", raw))
      exit_usage()
      return
    }
    Present(v) => v
  }
  if count < 0 {
    arg_error("--count must be >= 0")
    exit_usage()
    return
  }
  // LC-1：巨大 count 会让 enc.symbols 挂死（实测 120s 不终止），量级
  // 上限拒绝而不是坐进无界分配。
  if count > LT_MAX_COUNT {
    arg_error(
      "--count must be <= \{LT_MAX_COUNT} (got \{count}); split the payload or raise K instead",
    )
    exit_usage()
    return
  }
  let data = match read_file(input) {
    None => {
      arg_error("cannot read input file '\{input}'")
      exit_bad_input()
      return
    }
    Some(d) => d
  }
  let block = match @lib.SourceBlock::from_bytes(data, k) {
    Err(e) => {
      arg_error("cannot split input: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
    Ok(b) => b
  }
  let enc = match
    @lib.Encoder::new(block, seed, @lib.default_c(), @lib.default_delta()) {
    Err(e) => {
      arg_error("cannot build encoder: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
    Ok(e) => e
  }
  let symbols = enc.symbols(0, count)
  let packed = @lib.pack_container(
    block,
    seed,
    data,
    @lib.default_c(),
    @lib.default_delta(),
    symbols,
  )
  match write_file(out_path, packed) {
    None => {
      arg_error("cannot write '\{out_path}'")
      exit_bad_input()
      return
    }
    Some(_) => ()
  }
  println(
    "encoded \{data.length()} bytes -> K=\{k} symbol_len=\{block.symbol_len} symbols=\{count} seed=\{seed}",
  )
  println("out: \{out_path} (\{packed.length()} bytes)")
  // `--count 0` 的语义（LT-4）：容器结构完好但一个符号都没有。
  // 这种容器**永远**解不出来，所以产出这一侧必须说清楚，而不是让调用方
  // 拿到一个"encode 成功、decode 永远 INCOMPLETE"的文件回去猜。
  // 不改成 exit 2 的理由见 README「`--count 0` 的语义」：0 是良定义的下界
  // （"先建头部、符号之后再补"），拒绝它会把可表达的请求变成不可表达；
  // 该给的警告在产出侧给足就够了。
  let note = encode_note(count)
  if !note.is_empty() {
    println(note)
  }
  exit_ok()
}

///|
/// `decode`：读容器 → 剥皮 → 成功写出原文，失败打印缺项并退出码 1。
fn cmd_decode(args : Args) -> Unit {
  let input = match args.str("input") {
    None => {
      arg_error("decode needs --input")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let out_path = args.str("out").unwrap_or("decoded.bin")
  let data = match read_file(input) {
    None => {
      arg_error("cannot read input file '\{input}'")
      exit_bad_input()
      return
    }
    Some(d) => d
  }
  let container = @lib.unpack_container(data) catch {
    e => {
      arg_error("not a ltcode container: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
  }
  // --symbols / --seed 是可选核对项：文件自描述，给了就必须一致。
  // 给了垃圾（`--symbols abc` / `--seed abc` / `--seed -1`）是用法错误，
  // 不是"这一项没给" —— 静默忽略等于让核对项形同虚设。
  match args.int("symbols") {
    Absent => ()
    Invalid(raw) => {
      arg_error(num_error("--symbols", "an integer", raw))
      exit_usage()
      return
    }
    Present(k) =>
      if k != container.k {
        arg_error("--symbols \{k} does not match container K=\{container.k}")
        exit_usage()
        return
      }
  }
  match args.uint64("seed") {
    Absent => ()
    Invalid(raw) => {
      arg_error(num_error("--seed", "a decimal or 0x-prefixed hex number", raw))
      exit_usage()
      return
    }
    Present(s) =>
      if s != container.seed {
        arg_error("--seed \{s} does not match container seed=\{container.seed}")
        exit_usage()
        return
      }
  }
  // **逐字节校验**由库内的 `decode_verified` 负责（PLAN §9）：
  // 剥皮本身发现不了「收到的符号互相矛盾」—— 一个被改过的度 1 符号
  // 会让解出来的源符号直接是错的，而解码仍然报 Complete。
  // 因此"成功"的定义里必须含哈希比对，且这个比对只在库里有**一份**实现
  // （CLI 不重复写一遍，否则迟早两边不一致）。
  let result = @lib.decode_verified(container) catch {
    @lib.CorruptionDetected(actual, expected) => {
      arg_error(
        "decoded payload FAILED checksum: got 0x\{actual.to_string(radix=16)}, expected 0x\{expected.to_string(radix=16)}",
      )
      println(
        "  this means the received symbols were corrupted or mixed from another encoding",
      )
      println("  the decoded bytes were NOT written to disk")
      exit_bad_input()
      return
    }
    e => {
      arg_error("decode error: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
  }
  match result {
    @lib.Complete(sources) => {
      let bytes = @lib.reassemble(sources, container.payload_len)
      match write_file(out_path, bytes) {
        None => {
          arg_error("cannot write '\{out_path}'")
          exit_bad_input()
          return
        }
        Some(_) => ()
      }
      println(
        "decoded OK: K=\{container.k} symbols=\{container.symbols.length()} payload=\{bytes.length()} bytes (checksum verified)",
      )
      println("out: \{out_path}")
      exit_ok()
    }
    @lib.Incomplete(_, missing) => {
      println(
        "decode INCOMPLETE: need more symbols (missing \{missing.length()} of \{container.k} source symbols)",
      )
      println("missing indices: \{join_ints(missing)}")
      exit_incomplete()
    }
  }
}

///|
/// `simulate`：单点成功率。
fn cmd_simulate(args : Args) -> Unit {
  let k = match req_int(args, "symbols", "simulate needs --symbols K") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let overhead = match
    req_double(args, "overhead", "simulate needs --overhead O") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let trials = match opt_int(args, "trials", 100) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let seed = match opt_seed(args) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let symbol_len = match opt_int(args, "symbol-len", 4) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  if k < 1 || trials < 1 || symbol_len < 1 {
    arg_error("--symbols/--trials/--symbol-len must be >= 1")
    exit_usage()
    return
  }
  if overhead <= 0.0 {
    arg_error("--overhead must be > 0")
    exit_usage()
    return
  }
  let point = @lib.decode_success_rate(
    k,
    overhead,
    trials,
    seed,
    symbol_len,
    @lib.default_c(),
    @lib.default_delta(),
  ) catch {
    e => {
      arg_error("simulate failed: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
  }
  println(
    "simulate  K=\{k}  c=\{@lib.format_fixed(@lib.default_c(), 2)}  delta=\{@lib.format_fixed(@lib.default_delta(), 2)}  trials=\{trials}  seed=\{seed}  symbol_len=\{symbol_len}",
  )
  println("")
  println("  overhead  received  successes  rate")
  let sb = StringBuilder()
  sb.write_string("  ")
  sb.write_string(@lib.format_fixed(point.overhead, 2))
  sb.write_string("      ")
  sb.write_string(point.received.to_string())
  sb.write_string("        ")
  sb.write_string(point.successes.to_string())
  sb.write_char('/')
  sb.write_string(point.trials.to_string())
  sb.write_string("      ")
  sb.write_string(@lib.format_fixed(point.rate, 3))
  println(sb.to_string())
  exit_ok()
}

///|
/// `curve`：整条曲线。
fn cmd_curve(args : Args) -> Unit {
  let k = match req_int(args, "symbols", "curve needs --symbols K") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let spec = match args.str("overheads") {
    None => {
      arg_error("curve needs --overheads a,b,c")
      exit_usage()
      return
    }
    Some(v) => v
  }
  // LT-3：非法项必须报错，不能静默丢掉（`1.0,abc,1.5` 只跑两行是欺骗）
  let overheads = match parse_overheads_strict(spec) {
    Ok(v) => v
    Err(bad) => {
      arg_error("--overheads '\{bad}' is not a positive number")
      exit_usage()
      return
    }
  }
  if overheads.length() == 0 {
    arg_error("--overheads must list at least one positive number")
    exit_usage()
    return
  }
  let trials = match opt_int(args, "trials", 100) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let seed = match opt_seed(args) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let symbol_len = match opt_int(args, "symbol-len", 4) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  if k < 1 || trials < 1 || symbol_len < 1 {
    arg_error("--symbols/--trials/--symbol-len must be >= 1")
    exit_usage()
    return
  }
  let points = @lib.evaluate(
    k,
    overheads,
    trials,
    seed,
    symbol_len,
    @lib.default_c(),
    @lib.default_delta(),
  ) catch {
    e => {
      arg_error("curve failed: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
  }
  println(
    "curve  K=\{k}  c=\{@lib.format_fixed(@lib.default_c(), 2)}  delta=\{@lib.format_fixed(@lib.default_delta(), 2)}  trials=\{trials}  seed=\{seed}  symbol_len=\{symbol_len}",
  )
  println("")
  println("  overhead  received  successes  rate")
  for p in points {
    let sb = StringBuilder()
    sb.write_string("  ")
    sb.write_string(@lib.format_fixed(p.overhead, 2))
    sb.write_string("      ")
    sb.write_string(p.received.to_string())
    sb.write_string("        ")
    sb.write_string(p.successes.to_string())
    sb.write_char('/')
    sb.write_string(p.trials.to_string())
    sb.write_string("      ")
    sb.write_string(@lib.format_fixed(p.rate, 3))
    println(sb.to_string())
  }
  exit_ok()
}

///|
/// `distcmp`：同一 K / overhead / 种子下，三种度数分布的成功率对照。
///
/// 这条命令存在的意义是让「鲁棒孤波的 τ 尖峰到底有没有用」变成一个
/// 可以被任何人当场复现的实验，而不是文档里的一句断言。
fn cmd_distcmp(args : Args) -> Unit {
  let k = match req_int(args, "symbols", "distcmp needs --symbols K") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let overhead = match
    req_double(args, "overhead", "distcmp needs --overhead O") {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let trials = match opt_int(args, "trials", 100) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let seed = match opt_seed(args) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  let symbol_len = match opt_int(args, "symbol-len", 4) {
    None => {
      exit_usage()
      return
    }
    Some(v) => v
  }
  if k < 1 || trials < 1 || symbol_len < 1 || overhead <= 0.0 {
    arg_error("--symbols/--trials/--symbol-len must be >= 1, --overhead > 0")
    exit_usage()
    return
  }
  let rows = @lib.distribution_comparison(k, overhead, trials, seed, symbol_len) catch {
    e => {
      arg_error("distcmp failed: \{@lib.error_text(e)}")
      exit_bad_input()
      return
    }
  }
  println(
    "distcmp  K=\{k}  overhead=\{@lib.format_fixed(overhead, 2)}  trials=\{trials}  seed=\{seed}  symbol_len=\{symbol_len}",
  )
  println("")
  println("  distribution          successes  rate")
  for _, (name, p) in rows {
    let sb = StringBuilder()
    sb.write_string("  ")
    sb.write_string(name)
    // 对齐到 22 列
    let pad = 22 - name.length()
    if pad > 0 {
      sb.write_string(String::make(pad, ' '))
    }
    sb.write_string(p.successes.to_string())
    sb.write_char('/')
    sb.write_string(p.trials.to_string())
    let shown = "\{p.successes}/\{p.trials}"
    let pad2 = 11 - shown.length()
    if pad2 > 0 {
      sb.write_string(String::make(pad2, ' '))
    }
    sb.write_string(@lib.format_fixed(p.rate, 3))
    println(sb.to_string())
  }
  exit_ok()
}

///|
/// 解析 `"1.0,1.1,1.2"`，**非法项导致整条命令失败**（LT-3）。
///
/// 旧实现在 `catch { _ => () }` 里把非法段静默丢掉：`--overheads 1.0,abc,1.5`
/// 只跑两行、exit 0、不吭一声。那不是一个"部分成功"，而是**一次假的实验**
/// —— 用户以为曲线覆盖了三个点，实际只有两个。度量工具最不能做的就是
/// 悄悄缩小自己的工作范围。
///
/// 返回 `Err(token)` 时 `token` 是**原始片段**（trim 过，但保留用户写的样子），
/// 这样报错能说"`--overheads 的 'abc' 不是正数`"，用户不用回去数逗号。
pub fn parse_overheads_strict(spec : String) -> Result[Array[Double], String] {
  let out : Array[Double] = []
  // 空串给空列表：`split` 对空串返回一个空元素，那是"什么都没写"，
  // 不是"写了一个空的项"。子命令随后报 "--overheads must list at least one"。
  if spec.trim().to_owned().is_empty() {
    return Ok(out)
  }
  for part in spec.split(",") {
    let trimmed = part.trim().to_owned()
    // 其余情况下空段（"1.0,,1.5" 或多余逗号）是错：既不是"省略"也不是"默认"
    if trimmed.is_empty() {
      return Err("(empty)")
    }
    let v = match parse_finite_double(trimmed) {
      Some(v) => v
      None => return Err(trimmed)
    }
    if v <= 0.0 {
      return Err(trimmed)
    }
    out.push(v)
  }
  Ok(out)
}

///|
/// 宽松包装：非法项仍然丢弃，但只给**确实想丢弃**的调用方用。
///
/// 保留是因为它对"尽力而为"的输入清洗仍然有用；但子命令**不许**用它
/// —— `cmd_curve` 走 `parse_overheads_strict`。这条注释就是那两个函数
/// 之间唯一的区别说明，改的人不该两边都改。
pub fn parse_overheads(spec : String) -> Array[Double] {
  let out : Array[Double] = []
  for part in spec.split(",") {
    let trimmed = part.trim().to_owned()
    if !trimmed.is_empty() {
      match parse_finite_double(trimmed) {
        Some(v) => if v > 0.0 { out.push(v) }
        None => ()
      }
    }
  }
  out
}

///|
pub fn join_ints(values : Array[Int32]) -> String {
  let sb = StringBuilder()
  for i, v in values {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(v.to_string())
  }
  sb.to_string()
}

///|
fn read_file(path : String) -> Bytes? {
  Some(@fs.read_file_to_bytes(path)) catch {
    _ => None
  }
}

///|
fn write_file(path : String, data : Bytes) -> Unit? {
  try {
    @fs.write_bytes_to_file(path, data)
    Some(())
  } catch {
    _ => None
  }
}
