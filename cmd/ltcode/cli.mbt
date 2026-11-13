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
/// 度量侧的量级上限（LT-B，2026-11-10 审计）。
///
/// LC-1 只给 `--count` 加了上限，`simulate` / `curve` / `distcmp` 这一侧的
/// 三个参数原封不动，于是同一类挂死原样存在：
///
/// ```
/// simulate --symbols 1000 --overhead 2500000 --trials 1        → 40s 挂死
/// simulate --symbols 1000 --overhead 1e300     --trials 1        → 同上
/// simulate --symbols 10   --overhead 1.2 --trials 2147483647     → 同上
/// simulate --symbols 10   --overhead 1.2 --trials 1 --symbol-len 2000000000
///                                                                → 60s 挂死
/// ```
///
/// 三处根因同源：这些量都直接决定**逐符号循环的次数或每次迭代的分配量**。
///
/// - `--trials`：`decode_success_rate` 的外层循环次数。
/// - `--overhead` → `received_count`：`.to_int()` 对 2.5e9 与 1e300 都
///   **饱和**到 `2147483647`，于是内层循环 21 亿次。
/// - `--symbol-len`：`FixedArray::make(symbol_len, …)` 的尺寸，每次试验
///   每个符号都要一份。
///
/// 因此和 LC-1 对称：pub 常量 + 守卫函数 + CLI 报用法错误 exit 2。
///
/// 取值依据（不是调优产物，是显式边界）：
/// - `LT_MAX_TRIALS = 10_000_000`：README 实测最大 1000（整条 curve 500 次）。
///   取 1e7 给「长跨度种子扫描」留足余量，同时把 21 亿明确拒掉。
/// - `LT_MAX_RECEIVED = 4_000_000`：单次试验的符号数。K 上限是 1<<20
///   (1,048,576)，overhead 到 4.0 约 419 万；再高该换 K 而不是加 overhead。
/// - `LT_MAX_SYMBOL_LEN = 1 << 20`：单符号 1MB。再大就该改分块策略。
pub const LT_MAX_TRIALS : Int32 = 10_000_000

///|
/// 单次试验可收到的符号数上限（见 `LT_MAX_TRIALS` 的说明）。
pub const LT_MAX_RECEIVED : Int32 = 4_000_000

///|
/// 单符号长度上限（字节）。
pub const LT_MAX_SYMBOL_LEN : Int32 = 1 << 20

///|
/// `--trials` 守卫：超限返回用法错误文本，合法返回空串。
///
/// 返回 `String`（而非 `Option`）与 `encode_note` 同形状：调用点只想
/// `if !msg.is_empty() { arg_error(msg); exit_usage(); return }`。
pub fn guard_trials(trials : Int32) -> String {
  if trials > LT_MAX_TRIALS {
    "--trials must be <= \{LT_MAX_TRIALS} (got \{trials}); a longer run needs a smaller --overhead or a narrower seed range"
  } else {
    ""
  }
}

///|
/// `--overhead` 守卫：它真正决定的是**收到的符号数** `floor(K × overhead)`。
///
/// 因此守卫量是那个乘积，不是 overhead 本身 —— 同一个 overhead 在 K=10
/// 时无害、在 K=1<<20 时致命。这也解释上限文案为什么写 `received`。
///
/// `nan` / `inf` 在这里也要挡：`nan > 上限` 为 false，`inf` 会绕过比较，
/// 而两者都能让 `received_count` 给出饱和值（参数层已经拒了非有限值，
/// 但守卫是库层入口，可能被别处调用）。
pub fn guard_overhead(k : Int32, overhead : Double) -> String {
  if overhead.is_nan() || overhead.is_inf() {
    "--overhead must be a finite number, got \{overhead}"
  } else {
    let received = received_count_checked(k, overhead)
    if received > LT_MAX_RECEIVED {
      "--overhead \{overhead} at K=\{k} needs \{received} symbols, above the limit of \{LT_MAX_RECEIVED}; raise K instead of overhead"
    } else {
      ""
    }
  }
}

///|
/// 单符号长度守卫。
pub fn guard_symbol_len(symbol_len : Int32) -> String {
  if symbol_len > LT_MAX_SYMBOL_LEN {
    "--symbol-len must be <= \{LT_MAX_SYMBOL_LEN} (got \{symbol_len}); use more symbols instead of longer ones"
  } else {
    ""
  }
}

///|
/// 度量侧 `--symbols` 的上界文案（LT2，2026-11-13 审计）。
///
/// 上界值与 `encode` 完全同域（`max_source_symbols()` = `1 << 20`），但
/// **下一步建议不同**，因此不能复用 `symbols_bound_msg`：那一句写的是
/// 「把文件切分成几段分别编码」，而 `simulate` / `curve` / `distcmp`
/// 根本不读文件 —— 照抄会把用户引向一个不存在的动作。
///
/// 为什么度量侧也需要这条界：
/// - `guard_overhead` 的守卫量是 `K × overhead`（收到的符号数），K 本身
///   没有上界，于是「小 overhead + 巨大 K」能绕开它；
/// - `run_trial` 先跑 `random_sources(k)` 的 k 次分配，**在**
///   `SourceBlock::new` 的 K 检查**之前** —— 实测 `--symbols 20000000`
///   （overhead 1e-5，received 只有 200）要 2.4 s 且内存随 K 线性；
///   `--symbols 2147483647` 是分钟级、几十 GB 级。
///
/// 与其它 guard 同形状：空串 = 放行。
pub fn metric_symbols_bound_msg(k : Int32) -> String {
  let limit = @lib.max_source_symbols()
  if k > limit {
    "--symbols must be <= \{limit} (got \{k}); the degree distribution table and the decoding CSR index are O(K), so measure at a smaller K and raise --overhead instead"
  } else {
    ""
  }
}

///|
/// 三个度量子命令共用的量级守卫（LT-B / LT2）。
///
/// `overheads` 是列表是因为 `curve` 一次要跑多个点 —— 每个点都会独立决定
/// 一次 `received_count`，因此必须逐个查，不能只看第一个。
///
/// **返回文案而不是打印**（LT2，2026-11-13 审计）：修复前这里是
/// 「打印 + 返回 Bool」，于是它的措辞**不可断言** —— 唯一可观测的东西是
/// 「进程退出了没有」。度量侧四条守卫里三条（`guard_trials` /
/// `guard_symbol_len` / `guard_overhead`）能被逐字断言，唯一不可断言的
/// 这一条正是漏掉 K 上界的那一条。现在它与本文件其余守卫同形状
/// （空串 = 放行），`metric_symbols_bound_wbtest.mbt` 因此能逐字锁定文案。
///
/// 检查顺序：K → trials → symbol-len → overheads。K 在最前是因为它是
/// **域**（上界由库的 `max_source_symbols()` 定），其余三条是**量级**；
/// 「两个参数都离谱」时报最外层那个，用户改一次就能看到进展。
fn check_metric_magnitudes(
  k : Int32,
  overheads : Array[Double],
  trials : Int32,
  symbol_len : Int32,
) -> String {
  let k_msg = metric_symbols_bound_msg(k)
  if !k_msg.is_empty() {
    return k_msg
  }
  let trials_msg = guard_trials(trials)
  if !trials_msg.is_empty() {
    return trials_msg
  }
  let len_msg = guard_symbol_len(symbol_len)
  if !len_msg.is_empty() {
    return len_msg
  }
  for oh in overheads {
    let oh_msg = guard_overhead(k, oh)
    if !oh_msg.is_empty() {
      return oh_msg
    }
  }
  ""
}

///|
/// `floor(K × overhead)`，与 `@lib.received_count` **同一个公式**，
/// 但**不在 Int32 上饱和**：超限时返回 `Int32` 最大值让守卫看得见。
///
/// 为什么不直接用库里的 `received_count`：它的 `.to_int()` 会把 2.5e9 与
/// 1e300 都饱和成 2147483647 —— 那个值**看起来**只比上限大一倍，而真实
/// 请求是 100 万倍。守卫需要知道"到底多大"才能说清话。
fn received_count_checked(k : Int32, overhead : Double) -> Int32 {
  if overhead <= 0.0 || k <= 0 {
    0
  } else {
    let n = (k.to_double() * overhead).to_int()
    // 饱和语义：要么 Double 本身已经 > Int32 上限（`to_int` 给出
    // 2147483647），要么乘积在范围内。两种都不需要再夹一次 ——
    // 重要的是**守卫拒绝它**，而不是把数字还原出来。
    if n < 0 {
      0
    } else {
      n
    }
  }
}

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
/// `encode` 末尾可解性验算的**数量闸门**（LT1，2026-11-12 followup）。
///
/// 为什么需要验算：默认 `--count = ceil(1.5K)+1` 这个倍数对小 K **不保证**
/// 可解（剥皮需要的度 1 符号数由 `ln(K/δ)·√K` 决定，与 K 不成正比）。实测
/// K=10 + 默认 16 符号：默认种子能解，`--seed 3` 就报
/// `INCOMPLETE: missing 6 of 10`。也就是说 `encode` 可以写出**自己读不出来**
/// 的容器而一声不吭 —— 用户无法判断是参数问题还是实现问题。
///
/// 为什么必须有闸门：验算就是「用同一个解码器再解一遍」，成本与编码**同量级**
/// （同一个 `count × 平均度数 × symbol_len` 的 XOR 量）。无条件下验算等于让
/// 每次 `encode` 慢一倍，而收益只是一行提示。因此只在 `count <= 4096` 时做：
///
/// - 它覆盖默认 count 在 `K <= 2730` 时的全部取值（`default_count(2730) = 4096`）；
/// - 本项目的定位是「K 至多数千」，README 的实测曲线都在这个区间；
/// - 超阈值**跳过并且什么都不打印** —— 这正是 best-effort 的含义：没打印
///   ≠ 已验证可解。README「可解性验算」一节与 `help` 都写明了这条边界。
pub const LT_VERIFY_MAX_COUNT : Int32 = 4096

///|
/// 该不该做末尾验算。`count == 0` 一律不验算：那时走 `encode_note` 的零符号
/// 提示，两条提示**不会同时出现**（`cmd_encode` 里是 `if ... else if ...`）。
pub fn should_verify_solvability(count : Int32) -> Bool {
  count >= 1 && count <= LT_VERIFY_MAX_COUNT
}

///|
/// 解不出时那一行提示。`missing <= 0` 返回空串（与各 guard / `encode_note`
/// 同形状：调用点只管 `if !msg.is_empty()`）。
///
/// 措辞里必须同时有**缺几个**、**当前 count**、**默认值来源**与**下一步**：
/// 只说"解不出来"会让用户以为是实现缺陷，只说"加大 --count"则说不清该加到
/// 多少（默认值是怎么来的）。
pub fn solvability_note(k : Int32, count : Int32, missing : Int32) -> String {
  if missing <= 0 {
    ""
  } else {
    "note: these \{count} symbols cannot recover all \{k} source symbols (\{missing} missing); decode will report INCOMPLETE - raise --count (the default is ceil(1.5K)+1)"
  }
}

///|
/// 用**解码器本身**试解这批符号，返回该说的话（空串 = 什么都不用说）。
///
/// 不新写一份剥皮：`decode_full` 与 `decode` 走同一条路径，「encode 写出的
/// 容器能不能被自己读回」这件事只能由那一条路径回答 —— 另写一份判据，
/// 迟早两边对同一个文件给出相反答案（正是 16.2-2 那个缺陷的形态）。
///
/// 解码抛错时返回空串而不是报错：这条验算是**提示**，它自己出错不该改变
/// `encode` 的结论（容器已经写好、退出码仍是 0）。
///
/// **私有**（不 `pub`）：调用方只有 `cmd_encode` 与白盒测试。公开它会让 CLI
/// 包的公开接口凭空多出一个 `@src.Symbol` 类型依赖；而外面若想验算，应该
/// 直接用库里的 `decode_full` —— 那才是唯一的判据来源。
fn verify_solvability(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
  symbols : Array[@lib.Symbol],
) -> String raise @lib.LtError {
  let count = symbols.length()
  if !should_verify_solvability(count) {
    return ""
  }
  let received : Array[@lib.ReceivedSymbol] = []
  for s in symbols {
    received.push(@lib.ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let missing = match
    @lib.decode_full(
      seed,
      k,
      symbol_len,
      received,
      @lib.default_c(),
      @lib.default_delta(),
    ) {
    @lib.Complete(_) => 0
    @lib.Incomplete(_, missing) => missing.length()
  }
  solvability_note(k, count, missing)
}

///|
/// `encode` 没给 `--count` 时的默认值：`ceil(K × 1.5) + 1`。
///
/// 抽成函数有两个理由：
/// 1. README 与 `--count 0` 那一节都引用了这个公式 —— 公式必须有**唯一**
///    定义处，改一处就得改另一处。
/// 2. K 很大时它会**撞上** LT_MAX_COUNT（LT-H1，2026-11-10 审计）：K=700000
///    → 1050001 > 1_000_000。修复前那时用户会收到
///    `--count must be <= 1000000 (got 1050001)`，而他**根本没传 --count**
///    —— 报错把人指向一个不存在的输入。
///
/// 用整数算式 `(3K+1)/2 + 1` 而不是 `(k.to_double() * 1.5).to_int() + 1`
/// （LT-J，2026-11-11 审计）：后者是 **floor**，只在 K 为偶数时与 ceil 重合；
/// K 为奇数时 1.5K 落在 .5 上被截断，K=3 给出 5（应为 6）、K=7 给出 11
/// （应为 12）、K=1 给出 2（应为 3）。而 README / API.md / 本函数的文档与
/// `default_count_test.mbt` 的测试名全都写的是 `ceil(1.5K)+1`，测试里那条
/// `default_count(1) == 2` 又把 floor 的值锁死了 —— 代码、文档、测试名三者
/// 互相矛盾，谁也没发现。整数算式在 `K ∈ [1, 2^20]` 内不会溢出，也不引入
/// 浮点边界。
pub fn default_count(k : Int32) -> Int32 {
  (k * 3 + 1) / 2 + 1
}

///|
/// **显式** `--count` 超限时的文案：那时"你写的这个值太大"是对的。
pub fn explicit_count_overflow_msg(count : Int32) -> String {
  "--count must be <= \{LT_MAX_COUNT} (got \{count}); split the payload or raise K instead"
}

///|
/// **默认** count 触顶时的文案（LT-H1）：必须说清三件事 ——
/// （a）这是默认值、（b）它是怎么算出来的、（c）下一步该怎么做。
///
/// 合并进 `explicit_count_overflow_msg` 是不行的：那两种情况的修法不同
/// （改参数 vs **加**参数），一条含糊的话会让用户两条路都试一遍。
///
/// 返回空串 = 没触顶（与各 guard 同形状，调用点只管 `if !msg.is_empty()`）。
pub fn default_count_overflow_msg(k : Int32) -> String {
  let dc = default_count(k)
  if dc > LT_MAX_COUNT {
    "the default --count (ceil(1.5K)+1 = \{dc}) exceeds the limit of \{LT_MAX_COUNT}; no --count was given, so pass it explicitly (e.g. --count \{LT_MAX_COUNT}) or lower K"
  } else {
    ""
  }
}

///|
/// `--symbols` 的上界守卫（LT-K，2026-11-11 审计）。
///
/// 修复前 `--symbols` 只判了下界（`>= 1`），上界留给
/// `SourceBlock::from_bytes` 里的 `SourceTooLarge`：
///
/// ```
/// ltcode: cannot split input: source too large:
///         K=2147483647 exceeds the limit of 1048576 source symbols
/// exit 3
/// ```
///
/// 两个毛病：退出码按「输入非法」（3）报，而这是**用法错误**（2）——
/// `--count` 越界就是按 2 报的，同一个域的两个参数走了两条路；文案把话
/// 推到「切不开输入」上，读起来像 `--input` 有问题，而该改的是 `--symbols`。
///
/// 与其它 guard 同形状：空串 = 没越界，调用方只管 `if !msg.is_empty()`。
pub fn symbols_bound_msg(k : Int32) -> String {
  let limit = @lib.max_source_symbols()
  if k > limit {
    "--symbols must be <= \{limit} (got \{k}); split the file into several parts and encode them separately"
  } else {
    ""
  }
}

///|
/// `encode`：读文件 → 切块 → 编码 N 个符号 → 写自描述容器。
fn cmd_encode(args : Args) -> Unit {
  // LT-F：未知选项 / 位置参数先拒（笔误的键会让核对项静默失效）
  let unk = unknown_arg_error(args, "encode")
  if !unk.is_empty() {
    arg_error(unk)
    exit_usage()
    return
  }
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
  // LT-K：上界也在用法层判，别让 `SourceBlock::from_bytes` 用「切不开输入」
  // 的文案 + 退出码 3 去说一个用法错误。
  let k_over = symbols_bound_msg(k)
  if !k_over.is_empty() {
    arg_error(k_over)
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
  // 默认 count = ceil(K * 1.5)：够本项目的默认参数成功，又不至于大得离谱。
  //
  // LT-H1：默认值与 LC-1 的上限会在 K 很大时相撞。那种情况下必须说清
  // 「这是默认值」—— 修复前直接复用显式分支的文案，于是用户收到
  // `--count must be <= 1000000 (got 1050001)`，而他根本没传 --count。
  let mut count_was_default = false
  let count = match args.int("count") {
    Absent => {
      count_was_default = true
      default_count(k)
    }
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
      if count_was_default {
        default_count_overflow_msg(k)
      } else {
        explicit_count_overflow_msg(count)
      },
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
  } else if should_verify_solvability(count) {
    // LT1（2026-11-12 followup）：末尾可解性验算。
    //
    // 默认 `--count` 对小 K 不保证可解，而修复前 `encode` 对这件事完全沉默：
    // 用户拿到一个「encode 成功、decode 必然 INCOMPLETE」的容器，没有任何
    // 线索说明是参数问题还是实现问题。这里用同一个解码器试解一次，解不出
    // 就**如实说**。
    //
    // 三条纪律：
    // 1. 退出码不动 —— 容器本身完全合法（README「`--count 0` 的语义」已经
    //    论证过「写得出 ≠ 一定解得开」，这条提示与那条同源）；
    // 2. stdout 只多这一行，且只在解不出时多；
    // 3. `encode_note` 的零符号提示优先（`else if`）：两条同时出现会让人
    //    分不清到底是"没符号"还是"符号不够"。
    let hint = verify_solvability(seed, k, block.symbol_len, symbols) catch {
      // 验算自己出错不该改变 `encode` 的结论：容器已写好、退出码仍 0。
      _ => ""
    }
    if !hint.is_empty() {
      println(hint)
    }
  }
  exit_ok()
}

///|
/// `decode`：读容器 → 剥皮 → 成功写出原文，失败打印缺项并退出码 1。
fn cmd_decode(args : Args) -> Unit {
  // LT-F：这条命令的 `--symbols` / `--seed` 是**可选核对项**，笔误的键
  // （`--seedx`）会让核对静默失效 —— 最典型的"命令行看着成功、检查没跑"。
  let unk = unknown_arg_error(args, "decode")
  if !unk.is_empty() {
    arg_error(unk)
    exit_usage()
    return
  }
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
  let unk = unknown_arg_error(args, "simulate")
  if !unk.is_empty() {
    arg_error(unk)
    exit_usage()
    return
  }
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
  // LT-B：量级上限。修复前 overhead 2500000 / 1e300、trials 2147483647、
  // symbol-len 2000000000 都会让这条命令挂死（实测 40~60 秒不终止）。
  // LT2：`--symbols` 的域上界同在这条路径上（修复前它漏在这里，同一个值在
  // encode 上 exit 2、在这里 exit 3 且文案说「source too large」）。
  let too_big = check_metric_magnitudes(k, [overhead], trials, symbol_len)
  if !too_big.is_empty() {
    arg_error(too_big)
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
  let unk = unknown_arg_error(args, "curve")
  if !unk.is_empty() {
    arg_error(unk)
    exit_usage()
    return
  }
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
  // LT-B：逐个 overhead 查量级（`1.0,2500000` 这种混在列表里的值同样致命）
  // LT2：`--symbols` 的域上界也在同一条路径上（逐项查之前先查 K）。
  let too_big = check_metric_magnitudes(k, overheads, trials, symbol_len)
  if !too_big.is_empty() {
    arg_error(too_big)
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
  let unk = unknown_arg_error(args, "distcmp")
  if !unk.is_empty() {
    arg_error(unk)
    exit_usage()
    return
  }
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
  // LT-B：`distcmp` 把同一个 (K, overhead, trials) 跑**三种**分布，
  // 因此它对这几个参数的敏感度是 simulate 的三倍 —— 同一个守卫值在这里
  // 尤其不能漏。LT2：`--symbols` 的域上界也在同一条路径上。
  let too_big = check_metric_magnitudes(k, [overhead], trials, symbol_len)
  if !too_big.is_empty() {
    arg_error(too_big)
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
