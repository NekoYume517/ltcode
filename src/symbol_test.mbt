///|
/// 符号层测试。
///
/// `reassemble` 是"解码成功之后"这一步：它把 K 个源符号接回原始字节，并按
/// `payload_len` 截掉 `from_bytes` 在末尾补的零。这条契约是**文件能不能
/// 逐字节还原**的最后一道，因此单独测它，而不是只靠 container 的整体往返。

///|
test "symbol: reassemble is byte-exact and trims the zero padding" {
  // 15 字节切成 K=4 → symbol_len=4，最后一个符号补了 1 个零
  let data = b"abcdefghijklmno"
  let block = match SourceBlock::from_bytes(data, 4) {
    Ok(b) => b
    Err(_) => abort("from_bytes failed")
  }
  inspect(block.k, content="4")
  inspect(block.symbol_len, content="4")
  // 四个符号本身是 16 字节（补了一个零）
  let total = block.sources.fold(init=0, (acc, s) => acc + s.length())
  inspect(total, content="16")
  // 按 payload_len 接回：必须正好是原始的 15 字节，末尾那个零被截掉
  let back = reassemble(block.sources, data.length())
  assert_eq(back, data)
  inspect(back.length(), content="15")
}

///|
test "symbol: reassemble never invents bytes past payload_len" {
  let data = b"abcdef"
  let block = match SourceBlock::from_bytes(data, 2) {
    Ok(b) => b
    Err(_) => abort("from_bytes failed")
  }
  // 只要前 2 字节：不是"补零"，是**真的截断**——多出来的一个都不给
  let head = reassemble(block.sources, 2)
  assert_eq(head, b"ab")
  // payload_len = 0 → 空结果（不是"一个符号"，也不是"全长"）
  assert_eq(reassemble(block.sources, 0), b"")
  // payload_len 超过实际字节数 → 有多少给多少，不补零凑数
  let over = reassemble(block.sources, 100)
  assert_eq(over, data)
  inspect(over.length(), content="6")
}

///|
test "symbol: reassemble of an empty source list is empty, not a panic" {
  let empty : Array[Bytes] = []
  assert_eq(reassemble(empty, 5), b"")
  assert_eq(reassemble(empty, 0), b"")
}
