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
    CorruptionDetected(actual, expected) =>
      "payload checksum mismatch: got 0x\{actual.to_string(radix=16)}, expected 0x\{expected.to_string(radix=16)}; the received symbols are corrupted or mixed from another encoding"
  }
}
