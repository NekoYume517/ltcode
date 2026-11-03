///|
/// CLI 子命令实现。
///
/// 每个子命令自己负责：参数校验（用法错误 → 退出码 2）、输入校验
/// （文件读不到/格式不对 → 退出码 3）、业务结果（解码不足 → 退出码 1）。

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
  let k = match args.int("symbols") {
    None => {
      arg_error("encode needs --symbols K")
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
  let seed = args.uint64("seed").unwrap_or(@lib.default_seed())
  // 默认 count = ceil(K * 1.5)：够本项目的默认参数成功，又不至于大得离谱
  let count = match args.int("count") {
    None => (k.to_double() * 1.5).to_int() + 1
    Some(v) => v
  }
  if count < 0 {
    arg_error("--count must be >= 0")
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
  // --symbols / --seed 是可选核对项：文件自描述，给了就必须一致
  match args.int("symbols") {
    Some(k) =>
      if k != container.k {
        arg_error("--symbols \{k} does not match container K=\{container.k}")
        exit_usage()
        return
      }
    None => ()
  }
  match args.uint64("seed") {
    Some(s) =>
      if s != container.seed {
        arg_error("--seed \{s} does not match container seed=\{container.seed}")
        exit_usage()
        return
      }
    None => ()
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
  let k = match args.int("symbols") {
    None => {
      arg_error("simulate needs --symbols K")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let overhead = match args.double("overhead") {
    None => {
      arg_error("simulate needs --overhead O")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let trials = args.int("trials").unwrap_or(100)
  let seed = args.uint64("seed").unwrap_or(@lib.default_seed())
  let symbol_len = args.int("symbol-len").unwrap_or(4)
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
  let k = match args.int("symbols") {
    None => {
      arg_error("curve needs --symbols K")
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
  let overheads = parse_overheads(spec)
  if overheads.length() == 0 {
    arg_error("--overheads must list at least one positive number")
    exit_usage()
    return
  }
  let trials = args.int("trials").unwrap_or(100)
  let seed = args.uint64("seed").unwrap_or(@lib.default_seed())
  let symbol_len = args.int("symbol-len").unwrap_or(4)
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
  let k = match args.int("symbols") {
    None => {
      arg_error("distcmp needs --symbols K")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let overhead = match args.double("overhead") {
    None => {
      arg_error("distcmp needs --overhead O")
      exit_usage()
      return
    }
    Some(v) => v
  }
  let trials = args.int("trials").unwrap_or(100)
  let seed = args.uint64("seed").unwrap_or(@lib.default_seed())
  let symbol_len = args.int("symbol-len").unwrap_or(4)
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
/// 解析 `"1.0,1.1,1.2"`。
pub fn parse_overheads(spec : String) -> Array[Double] {
  let out : Array[Double] = []
  for part in spec.split(",") {
    let trimmed = part.trim()
    if !trimmed.is_empty() {
      try {
        let v = @strconv.parse_double(trimmed)
        if v > 0.0 {
          out.push(v)
        }
      } catch {
        _ => ()
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
