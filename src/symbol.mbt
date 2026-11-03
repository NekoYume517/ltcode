///|
/// 符号表示。
///
/// 设计取舍：**统一用 `Bytes`，不用 `Array[Byte]`**。
/// - LT 编码符号就是「若干个源符号的逐字节 XOR」，`Bytes` 正好是这个形状；
/// - `Bytes` 在 MoonBit 里是不可变的值语义，能让「同参数两次编码逐字节相同」
///   这条契约不依赖任何隐藏状态；
/// - 解码器的累加值需要原地 XOR，因此内部用 `FixedArray[Byte]` 作为工作区，
///   只在出参时转成 `Bytes`。这样热路径不产生「读-改-写-新分配」的垃圾。

///|
/// 一个源块：K 个等长源符号。
///
/// 构造时强制：
/// - `K >= 1`，否则 `EmptySource`
/// - `K <= max_source_symbols()`，否则 `SourceTooLarge`
/// - 所有符号等长，否则 `SymbolLengthMismatch`
/// - `symbol_len >= 1` 且非空，否则 `EmptySource`
///
/// 这些检查放在**构造**而不是编码时，是因为它们是「输入不可用」，
/// 与「收到的符号不够」（那是解码的 `Incomplete`）是两类问题。
pub(all) struct SourceBlock {
  k : Int32
  symbol_len : Int32
  sources : Array[Bytes]
}

///|
/// 源符号数上限。理由：编码器在 O(K) 上建一次 CDF 表（分布采样要用），
/// 解码器维护 `Array[Array[Int]]` 邻接表。`1 << 20` (1,048,576) 在 64 位
/// 目标上是 8MB 量级的索引数组，仍然可用；再大就该换分块方案了。
/// 这个数**不是**性能调优的产物，而是一条显式的「超出请分块」边界，
/// 有测试锁定它的值。
pub fn max_source_symbols() -> Int32 {
  1 << 20
}

///|
/// 构造源块。所有错误分支都是显式返回，不做静默修正
/// （长度不齐时不补零 —— 补零会让解码器恢复出「看起来对但多了零字节」的数据）。
pub fn SourceBlock::new(sources : Array[Bytes]) -> Result[SourceBlock, LtError] {
  let k = sources.length()
  if k == 0 {
    return Err(LtError::EmptySource)
  }
  let limit = max_source_symbols()
  if k > limit {
    return Err(LtError::SourceTooLarge(k, limit))
  }
  let len = sources[0].length()
  if len == 0 {
    return Err(LtError::EmptySource)
  }
  for i = 1; i < k; i = i + 1 {
    let other = sources[i].length()
    if other != len {
      return Err(LtError::SymbolLengthMismatch(len, other))
    }
  }
  Ok({ k, symbol_len: len, sources, })
}

///|
/// 把一段连续字节切成 K 个等长符号，末尾不足部分补零。
///
/// 补零发生在这里是**有意**的，并且必须记录下来：`payload_len` 记录了
/// 原始字节数，解码端用 `reassemble` 截回。这样「补零」不会污染语义 ——
/// 它与「解码时用假数据填缺符号」是两回事，后者被严格禁止。
pub fn SourceBlock::from_bytes(
  data : Bytes,
  k : Int32,
) -> Result[SourceBlock, LtError] {
  if k < 1 {
    return Err(LtError::EmptySource)
  }
  let limit = max_source_symbols()
  if k > limit {
    return Err(LtError::SourceTooLarge(k, limit))
  }
  if data.length() == 0 {
    return Err(LtError::EmptySource)
  }
  // symbol_len = ceil(len / k)，至少 1
  let len = data.length()
  let mut symbol_len = len / k
  if len % k != 0 {
    symbol_len = symbol_len + 1
  }
  if symbol_len < 1 {
    symbol_len = 1
  }
  let sources : Array[Bytes] = []
  let work : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
  for i = 0; i < k; i = i + 1 {
    // 每次复用同一块工作区，先清零（上一轮可能残留末尾字节）
    for j = 0; j < symbol_len; j = j + 1 {
      work[j] = b'\x00'
    }
    let base = i * symbol_len
    let mut j = 0
    while j < symbol_len && base + j < len {
      work[j] = data[base + j]
      j = j + 1
    }
    sources.push(Bytes::from_array(work))
  }
  Ok({ k, symbol_len, sources, })
}

///|
/// 把 K 个符号接回一段字节，并截到最后 `payload_len` 字节
/// （去掉 `from_bytes` 补的零）。
pub fn reassemble(sources : Array[Bytes], payload_len : Int32) -> Bytes {
  let sb = StringBuilder()
  let out : Array[Byte] = []
  for s in sources {
    for i = 0; i < s.length(); i = i + 1 {
      if out.length() < payload_len {
        out.push(s[i])
      }
    }
  }
  let _ = sb
  Bytes::from_array(out)
}

///|
/// 逐字节 XOR 累加：`dst ^= src`。长度不等时只处理较短的部分
/// （调用方必须先校验长度，这里不做静默扩展）。
fn xor_into(dst : FixedArray[Byte], src : Bytes) -> Unit {
  let n = dst.length()
  let m = src.length()
  let limit = if m < n { m } else { n }
  for i = 0; i < limit; i = i + 1 {
    dst[i] = dst[i] ^ src[i]
  }
}

///|
/// 一个编码符号：`(index, data)`。
///
/// `index` 是它在流中的序号 —— 编码符号的**子集只由 `(seed, index)` 决定**，
/// 因此任何一个编码符号都能独立重新生成，不依赖「之前生成过哪些」。
/// 这是 rateless 性质在实现层面的落点：接收方丢掉任意一段，剩下的仍可用，
/// 补发也只需给新的 index。
pub(all) struct Symbol {
  index : Int32
  data : Bytes
} derive(Eq, Debug)

///|
/// 一个收到的符号。解码器需要知道它的 index 才能重建子集。
pub(all) struct ReceivedSymbol {
  index : Int32
  data : Bytes
} derive(Eq, Debug)
