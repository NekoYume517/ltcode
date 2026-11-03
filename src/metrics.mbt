///|
/// 度量：LT 码的实际价值全在「需要多少冗余」。
///
/// 这一层刻意不引入任何近似公式：成功率的唯一来源是**真的跑一遍**编码 +
/// 丢包 + 解码。因此这里的每个数字都可以被任何人用同一条命令复现。
///
/// 三个关键量：
/// - `overhead_ratio`：收到符号数 / K。
/// - `decode_success_rate`：给定 overhead 与种子区间，成功的比例。
/// - `evaluate`：整条曲线。
///
/// **不使用墙钟时间**：CI 上不稳，而且时间无法区分「渐进复杂度错了」与
/// 「常数因子大了」。复杂度用 `DecodeStats` 的操作计数表达。

///|
/// 一次试验的结果。
pub(all) struct TrialOutcome {
  /// 本次试验的种子（可复现）
  seed : UInt64
  /// 收到的符号数
  received : Int32
  /// 是否完整解码
  success : Bool
  /// 失败时缺失的源符号数（成功为 0）
  missing : Int32
  /// 解码操作计数
  stats : DecodeStats
} derive(Debug)

///|
/// 开销比：`received / K`。
pub fn overhead_ratio(k : Int32, received : Int32) -> Double {
  if k <= 0 {
    0.0
  } else {
    received.to_double() / k.to_double()
  }
}

///|
/// 一条曲线上的一个点。
pub(all) struct CurvePoint {
  /// 目标开销
  overhead : Double
  /// 实际收到的符号数（= floor(K * overhead)，可能因取整略偏）
  received : Int32
  /// 成功次数
  successes : Int32
  /// 试验次数
  trials : Int32
  /// 成功率，3 位小数
  rate : Double
} derive(Debug)

///|
/// `floor(K * overhead)`，至少 0。
pub fn received_count(k : Int32, overhead : Double) -> Int32 {
  if overhead <= 0.0 {
    0
  } else {
    let n = (k.to_double() * overhead).to_int()
    if n < 0 {
      0
    } else {
      n
    }
  }
}

///|
/// 由 `seed` 确定性生成 K 个等长源符号。
pub fn random_sources(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
) -> Array[Bytes] {
  let rng = Ltrng::new(splitmix64(seed ^ 0x51505150UL))
  let out : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let b : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      b[j] = rng.next_below(256).to_byte()
    }
    out.push(Bytes::from_array(b))
  }
  out
}

///|
/// 一次试验：编码 K 个符号、按 overhead 取若干、解码、**逐字节比对**。
///
/// `payload` 用确定性 PRNG 由 `seed` 派生 —— 不用固定内容，否则
/// 「所有试验解同一份数据」会让失败相关性被掩盖。
pub fn run_trial(
  k : Int32,
  overhead : Double,
  seed : UInt64,
  symbol_len : Int32,
  c : Double,
  delta : Double,
) -> TrialOutcome raise LtError {
  let block = match SourceBlock::new(random_sources(seed, k, symbol_len)) {
    Ok(b) => b
    Err(e) => raise e
  }
  let enc = match Encoder::new(block, seed, c, delta) {
    Ok(e) => e
    Err(e) => raise e
  }
  let count = received_count(k, overhead)
  let received : Array[ReceivedSymbol] = []
  for i = 0; i < count; i = i + 1 {
    let s = enc.symbol(i)
    received.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let (res, stats) = decode_with_stats(seed, k, symbol_len, received, c, delta)
  match res {
    Complete(sources) => {
      // 成功时必须逐字节等于源 —— 度量里也做这件核对，
      // 而不是只信 DecodeResult 的标签。
      let mut ok = sources.length() == k
      for i = 0; i < k; i = i + 1 {
        if ok && sources[i] != block.sources[i] {
          ok = false
        }
      }
      TrialOutcome::{
        seed,
        received: count,
        success: ok,
        missing: if ok {
          0
        } else {
          1
        },
        stats,
      }
    }
    Incomplete(_, missing) =>
      TrialOutcome::{
        seed,
        received: count,
        success: false,
        missing: missing.length(),
        stats,
      }
  }
}

///|
/// 给定 overhead，跑 `trials` 次试验（种子 `seed, seed+1, ...`）。
pub fn decode_success_rate(
  k : Int32,
  overhead : Double,
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
  c : Double,
  delta : Double,
) -> CurvePoint raise LtError {
  let mut ok = 0
  let n = if trials < 0 { 0 } else { trials }
  for t = 0; t < n; t = t + 1 {
    let s = seed + t.to_uint64()
    let out = run_trial(k, overhead, s, symbol_len, c, delta)
    if out.success {
      ok = ok + 1
    }
  }
  let rate = if n == 0 { 0.0 } else { ok.to_double() / n.to_double() }
  {
    overhead,
    received: received_count(k, overhead),
    successes: ok,
    trials: n,
    rate: round3(rate),
  }
}

///|
/// 保留 3 位小数（四舍五入到最近的可表示值）。
///
/// 用 `round(x * 1000) / 1000` 而不是字符串截断：后者会把 0.9995 显示成
/// 0.999，而那会让「实测 100%」看起来像「实测 99.9%」。
pub fn round3(x : Double) -> Double {
  (x * 1000.0).round() / 1000.0
}

///|
/// 整条成功率曲线。
pub fn evaluate(
  k : Int32,
  overheads : Array[Double],
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
  c : Double,
  delta : Double,
) -> Array[CurvePoint] raise LtError {
  let out : Array[CurvePoint] = []
  for oh in overheads {
    out.push(decode_success_rate(k, oh, trials, seed, symbol_len, c, delta))
  }
  out
}

///|
/// 固定度分布下的成功率 —— 与鲁棒孤波对照。
///
/// 固定度分布**没有**度 1 的富集（除非 d0 == 1），剥皮立刻卡死；
/// 这个对照实验的作用是证明「τ 那一段不是装饰」。
pub fn fixed_degree_success_rate(
  k : Int32,
  d0 : Int32,
  overhead : Double,
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
) -> CurvePoint raise LtError {
  let mut ok = 0
  let n = if trials < 0 { 0 } else { trials }
  let dist = fixed_distribution(d0, k)
  for t = 0; t < n; t = t + 1 {
    // 与 `decode_success_rate` 一致：相邻种子（seed + t）即可，因为
    // `symbol_rng` 已经把 seed 与 index 分别混合过 —— 块间方差实测 0.029，
    // 与 n=200 的二项噪声 0.034 相符（见 encoder.mbt 的说明）。
    let s = seed + t.to_uint64()
    let block = match SourceBlock::new(random_sources(s, k, symbol_len)) {
      Ok(b) => b
      Err(e) => raise e
    }
    let count = received_count(k, overhead)
    let received : Array[ReceivedSymbol] = []
    for i = 0; i < count; i = i + 1 {
      let idx = subset_for(s, i, k, dist)
      let work : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
      for j in idx {
        xor_into(work, block.sources[j])
      }
      received.push(ReceivedSymbol::{ index: i, data: Bytes::from_array(work), })
    }
    // 注意：这里用鲁棒孤波的参数去**解码**固定度编码的符号是错的
    // （子集会算错），因此解码必须用同一个固定度分布。
    let (res, _) = peel(s, k, symbol_len, received, dist)
    if res.is_complete() {
      ok = ok + 1
    }
  }
  let rate = if n == 0 { 0.0 } else { ok.to_double() / n.to_double() }
  {
    overhead,
    received: received_count(k, overhead),
    successes: ok,
    trials: n,
    rate: round3(rate),
  }
}

///|
/// **分布对照**（PLAN.md §7 的最后一条要求）：
/// 同一个 K、同一个 overhead、同一串种子，只换度数分布。
///
/// 三行，全部用同一条 `peel` 解码路径：
/// - `robust`：本项目的默认鲁棒孤波（c=0.1, δ=0.5）
/// - `ideal`：理想孤波（没有 τ 尖峰）
/// - `fixed5`：固定度 5（既没有 τ，也没有度 1 的富集）
///
/// 结论（实测见 README）：`robust` 明显好于 `ideal`，`ideal` 好于
/// `fixed5`。这正是「τ 那一段不是装饰」的可证伪证据 —— 如果三者差不多，
/// 那么整个鲁棒孤波就没必要存在。
pub fn distribution_comparison(
  k : Int32,
  overhead : Double,
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
) -> Array[(String, CurvePoint)] raise LtError {
  let out : Array[(String, CurvePoint)] = []
  out.push(
    (
      "robust(c=0.10,d=0.50)",
      decode_success_rate(k, overhead, trials, seed, symbol_len, 0.1, 0.5),
    ),
  )
  out.push(("ideal", ideal_success_rate(k, overhead, trials, seed, symbol_len)))
  out.push(
    (
      "fixed(5)",
      fixed_degree_success_rate(k, 5, overhead, trials, seed, symbol_len),
    ),
  )
  out
}

///|
/// 理想孤波下的成功率（与 `fixed_degree_success_rate` 同构）。
pub fn ideal_success_rate(
  k : Int32,
  overhead : Double,
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
) -> CurvePoint raise LtError {
  run_with_distribution(ideal_soliton(k), k, overhead, trials, seed, symbol_len)
}

///|
/// 用任意分布跑一轮成功率。
///
/// 编码与解码**必须用同一个分布** —— 分布决定子集抽样，不是单纯的
/// 「性能旋钮」。用 A 编码、用 B 解码会让解码端算出完全不同的子集，
/// 结果必然失败（而且失败得很「莫名其妙」）。
pub fn run_with_distribution(
  dist : Distribution,
  k : Int32,
  overhead : Double,
  trials : Int32,
  seed : UInt64,
  symbol_len : Int32,
) -> CurvePoint raise LtError {
  let mut ok = 0
  let n = if trials < 0 { 0 } else { trials }
  for t = 0; t < n; t = t + 1 {
    let s = seed + t.to_uint64()
    let block = match SourceBlock::new(random_sources(s, k, symbol_len)) {
      Ok(b) => b
      Err(e) => raise e
    }
    let count = received_count(k, overhead)
    let received : Array[ReceivedSymbol] = []
    for i = 0; i < count; i = i + 1 {
      let idx = subset_for(s, i, k, dist)
      let work : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
      for j in idx {
        xor_into(work, block.sources[j])
      }
      received.push(ReceivedSymbol::{ index: i, data: Bytes::from_array(work), })
    }
    let (res, _) = peel(s, k, symbol_len, received, dist)
    if res.is_complete() {
      ok = ok + 1
    }
  }
  let rate = if n == 0 { 0.0 } else { ok.to_double() / n.to_double() }
  {
    overhead,
    received: received_count(k, overhead),
    successes: ok,
    trials: n,
    rate: round3(rate),
  }
}

///|
/// `CurvePoint` 的表格行（CLI 用同一份格式化，避免两处不一致）。
pub fn format_curve_point(p : CurvePoint) -> String {
  let sb = StringBuilder()
  sb.write_string("overhead=")
  sb.write_string(format_fixed(p.overhead, 2))
  sb.write_string("  received=")
  sb.write_string(p.received.to_string())
  sb.write_string("  successes=")
  sb.write_string(p.successes.to_string())
  sb.write_char('/')
  sb.write_string(p.trials.to_string())
  sb.write_string("  rate=")
  sb.write_string(format_fixed(p.rate, 3))
  sb.to_string()
}

///|
/// 定点小数格式化（**不用** `to_string()`：它会把 1.0 打成 "1"，
/// 让表格列对不齐，也让 1.00 与 1.0 的差别消失）。
pub fn format_fixed(x : Double, digits : Int32) -> String {
  let mut scale = 1
  for _i = 0; _i < digits; _i = _i + 1 {
    scale = scale * 10
  }
  let neg = x < 0.0
  let v = if neg { -x } else { x }
  let scaled = (v * scale.to_double()).round().to_int()
  let ip = scaled / scale
  let mut frac = scaled % scale
  let sb = StringBuilder()
  if neg {
    sb.write_char('-')
  }
  sb.write_string(ip.to_string())
  if digits > 0 {
    sb.write_char('.')
    let mut divisor = scale / 10
    while divisor > 0 {
      let digit = frac / divisor
      sb.write_string(digit.to_string())
      frac = frac % divisor
      divisor = divisor / 10
    }
  }
  sb.to_string()
}

///|
/// 一次试验的完整记录（供逐次核对）。
pub fn format_trial(o : TrialOutcome) -> String {
  let sb = StringBuilder()
  sb.write_string("seed=")
  sb.write_string(o.seed.to_string())
  sb.write_string("  received=")
  sb.write_string(o.received.to_string())
  sb.write_string("  success=")
  sb.write_string(o.success.to_string())
  sb.write_string("  missing=")
  sb.write_string(o.missing.to_string())
  sb.to_string()
}
