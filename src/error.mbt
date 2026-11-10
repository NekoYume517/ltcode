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
  /// 度数非法（d, K），要求 1 <= d <= K
  InvalidDegree(Int32, Int32)
  /// 分布未归一化（实际求和值），要求 |Σμ - 1| <= 1e-12
  DistributionNotNormalized(Double)
  /// 收到符号长度与声明不符（实际长度, 声明长度）
  TruncatedSymbol(Int32, Int32)
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
    InvalidDegree(d, k) =>
      "invalid degree \{d}: must satisfy 1 <= d <= K (\{k})"
    DistributionNotNormalized(sum) =>
      "degree distribution is not normalized: sum=\{sum} (tolerance 1e-12)"
    TruncatedSymbol(actual, wanted) =>
      "truncated symbol: got \{actual} bytes, expected \{wanted}"
    BadMagic => "bad magic"
    UnsupportedVersion(found, supported) =>
      "unsupported container version \{found}, this build supports \{supported}"
    InvalidHeaderField(name, value, low, high) =>
      if value < low {
        "invalid container header: \{name}=\{value} is below the minimum \{low}"
      } else {
        "invalid container header: \{name}=\{value} exceeds the maximum \{high}"
      }
    TrailingBytes(offset, len) =>
      "trailing bytes after the last symbol: \{offset} bytes consumed of \{len}; this is not the same file that was packed"
    CorruptionDetected(actual, expected) =>
      "payload checksum mismatch: got 0x\{actual.to_string(radix=16)}, expected 0x\{expected.to_string(radix=16)}; the received symbols are corrupted or mixed from another encoding"
  }
}
