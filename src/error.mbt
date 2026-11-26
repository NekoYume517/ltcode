///|
/// 错误类型。
///
/// 设计原则：每一个「看起来可以猜」的失败都变成显式错误，而不是返回一个
/// 看起来完整的错误结果。解码失败不在错误里表达 —— 那是 `DecodeResult::Incomplete`，
/// 因为「数据不足」是正常业务状态，不是调用方的编程错误。
#derive(Eq, Debug)
pub(all) suberror LtError {
  /// 源符号数为 0（没有任何可编码的东西）
  EmptySource
  /// 源符号数超过上限（K, 上限）
  SourceTooLarge(Int32, Int32)
  /// 源符号之间长度不一致（长度 a, 长度 b）
  SymbolLengthMismatch(Int32, Int32)
  /// 手工 SourceBlock 的声明字段与实际源数组不一致（原因）。
  InvalidSourceBlock(String)
  /// 度数非法（d, K），要求 1 <= d <= K
  InvalidDegree(Int32, Int32)
  /// 分布未归一化（实际求和值），要求 |Σμ - 1| <= 1e-12
  DistributionNotNormalized(Double)
  /// 收到符号长度与声明不符（实际长度, 声明长度）。**两个字段都是字节**。
  ///
  /// LT42（2026-11-28 审计）：这个变体一直只被字节量纲的调用点使用
  /// （`Reader::u32_unsigned` / `u32` / `u64` / `byte` / `bytes`，
  /// `unpack_container` 的头部不足，`decode_with_stats` 的符号体不足 ——
  /// 共 6 处）。唯独 `unpack_container` 里 `count_raw > count_max` 那处
  /// 传的是**符号条数**，渲染成 `got 3 bytes, expected 4` 后单位与含义不符，
  /// 用户会按字节去算"还差多少"。那处已改报 `TruncatedSymbolRecords`。
  TruncatedSymbol(Int32, Int32)
  /// 文件里**符号记录的条数**不够（够读条数, 头部声明条数）。
  ///
  /// 与 `TruncatedSymbol` 分开的理由是**量纲不同**，不是措辞洁癖：
  /// 前者说字节，后者说符号条数。混用一个变体时，`got 3 / expected 4`
  /// 在两个分支上字面相同而含义完全不同 —— 这是数据表里最容易被读错的形态。
  ///
  /// 典型现场：头部声明 `count = 4`，而剩余字节只够 `3` 条记录
  /// （`count_max = remaining / (4 + symbol_len)`）。这不是"符号体被砍了
  /// 一半"，而是"文件到这里就没了"。
  TruncatedSymbolRecords(Int32, Int32)
  /// 容器的魔数不是 "LTC2" —— **不是**截断，是"这根本不是 ltcode 文件"。
  BadMagic
  /// 容器版本号本构建不支持（文件里的版本, 本构建支持的版本）
  UnsupportedVersion(Int32, Int32)
  /// 容器头部字段超出它的可表示域（字段名, 实际值, 上限）。
  ///
  /// 头部的每个字段都是**外部输入**：`count` / `payload_len` / `K` 在文件里
  /// 是 u32 / u64，读进 `Int32` 会静默截断或变成负数（`0xFFFFFFFF` → `-1`）。
  /// 那种截断不会当场崩，而是让后续逻辑给出**误导性的业务状态**：
  /// `count` 变负使符号全部被丢弃 → 解码报 `INCOMPLETE`（"再给我几个符号"），
  /// 而真实原因是"头部说这里有 42 亿个符号"。
  ///
  /// 因此域校验必须落在 unpack 层（唯一入口），不能让调用方各自记得去查。
  /// 四元组是 `(字段名, 实际值, 合法下界, 合法上界)`：上下界都写出来，
  /// 是因为同一个变体既要报 `count` 超上限，也要报 `K` 低于 1 ——
  /// 只说"超上限"会把"K=0"描述错。
  InvalidHeaderField(String, UInt64, UInt64, UInt64)
  /// 容器尾部有多余字节（文件偏移, 文件长度）。
  ///
  /// 修复前这些字节被**静默忽略**：追加 12 个 `JUNK`、把两个完整容器拼接、
  /// 或者把 `count` 改小，全都 exit 0「checksum verified」。三者都是
  /// "这不是同一份文件"的症状，而它们看起来跟成功一模一样。
  ///
  /// 与 `TruncatedSymbol` 是**两个方向**：截断是"读不到"，尾部多余是
  /// "读完了还剩"。混进同一个变体会让调用方分不清该重传还是该丢弃。
  TrailingBytes(UInt64, UInt64)
  /// 解码"完成"但重算的载荷哈希与原哈希不符（实际, 期望）。
  ///
  /// 这是**唯一一个不能返回 `Incomplete` 的失败**：数据不够可以再要符号，
  /// 但哈希不符说明收到的符号本身是坏的（被改过、或混入了另一批），
  /// 再要多少也没用。理由与实测见 `docs/implementation.md` §5b。
  CorruptionDetected(UInt64, UInt64)
  /// 参数（`c` / `delta`）越出容器头量化网格的可表示域（名字, 实际值,
  /// 下界, 上界）。
  ///
  /// 容器头把这两个参数存成 `round(x*100)` 的单字节，因此可表示域是一张
  /// **网格**而不是连续区间。修复前（LT11，2026-11-17 审计）越界的 `c` 被
  /// 原样交给 `robust_soliton_checked`，于是用户收到
  /// `degree distribution is not normalized: sum=0 (tolerance 1e-12)`
  /// —— 他给的是 **c**，却被指到一张他从没写过的分布表上。这正是 LT3
  /// （2026-11-13）在**容器头**路径上修掉的同一类错位，库入口一直没镜像。
  ///
  /// 四元组与 `InvalidHeaderField` 同形状：下界与上界都写出来，因为同一个
  /// 变体既要报 "c=0.004 太小（量化为 0）"，也要报 "c=1000 太大（量化为
  /// 100000，装不进一个字节）"。上界是**开区间**：`c=2.555` 量化成 256。
  ParamOutOfImage(String, Double, Double, Double)
  /// 资源需求在分配或 I/O 前超过显式上限（资源名, 需求, 上限）。
  ResourceLimitExceeded(String, Int64, Int64)
}

///|
/// 稳定的、人类可读的错误文本。
///
/// 不用 `derive(Debug)` 的 `to_repr`：那个输出包含类型名与括号嵌套，
/// 不适合直接写进 CLI 的 stderr。这里手写，措辞固定（有测试锁定），
/// 因此脚本可以按文本匹配。
pub fn error_text(e : LtError) -> String {
  match e {
    EmptySource =>
      "empty source: at least one source symbol with a non-zero length is required"
    SourceTooLarge(k, limit) =>
      "source too large: K=\{k} exceeds the limit of \{limit} source symbols"
    SymbolLengthMismatch(a, b) =>
      "symbol length mismatch: \{a} vs \{b}; all source symbols must be equal length"
    InvalidSourceBlock(reason) => "invalid source block: \{reason}"
    InvalidDegree(d, k) =>
      "invalid degree \{d}: must satisfy 1 <= d <= K (\{k})"
    DistributionNotNormalized(sum) =>
      "degree distribution is not normalized: sum=\{sum} (tolerance 1e-12)"
    TruncatedSymbol(actual, wanted) =>
      "truncated symbol: got \{actual} bytes, expected \{wanted} bytes"
    TruncatedSymbolRecords(actual, wanted) =>
      "truncated symbol records: got \{actual} of \{wanted} symbol(s); the file ends before the count declared in the header"
    BadMagic => "bad magic"
    UnsupportedVersion(found, supported) =>
      "unsupported container version \{found}, this build supports \{supported}"
    InvalidHeaderField(name, value, low, high) =>
      if value < low {
        let base = "invalid container header: \{name}=\{value} is below the minimum \{low}"
        // LT21（2026-11-17 审计）：`payload_len` 的下界 1 不是随手取的 ——
        // 编码器根本产不出零长载荷（空输入被 `EmptySource` 拒），所以这份
        // 头只能来自手工构造。只丢一个「低于下界 1」会让用户去怀疑自己的
        // 输入文件，得把「产不出」这件事说出来。
        if name == "payload_len" && value == 0UL {
          "\{base}; the encoder cannot produce a container with a zero-length payload (empty input is rejected by EmptySource), so this header can only come from hand-crafted bytes"
        } else {
          base
        }
      } else {
        "invalid container header: \{name}=\{value} exceeds the maximum \{high}"
      }
    TrailingBytes(offset, len) =>
      "trailing bytes after the last symbol: \{offset} bytes consumed of \{len}; this is not the same file that was packed"
    CorruptionDetected(actual, expected) =>
      "payload checksum mismatch: got 0x\{actual.to_string(radix=16)}, expected 0x\{expected.to_string(radix=16)}; the received symbols are corrupted or mixed from another encoding"
    ParamOutOfImage(name, value, low, high) =>
      "parameter \{name}=\{value} is outside the container's quantized grid [\{low}, \{high}): the header stores round(\{name}*100) in a single byte, so \{name} must round to an integer in that range"
    ResourceLimitExceeded(name, actual, limit) =>
      if actual < 0L {
        "invalid resource requirement: \{name}=\{actual} must be non-negative"
      } else {
        "resource limit exceeded: \{name}=\{actual} exceeds the maximum \{limit}; reduce the container or symbol dimensions before allocating or performing I/O"
      }
  }
}
