///|
/// LT16（2026-11-17 审计）：`DecodeStats.xor_bytes` 是 `Int32`，而它的文档
/// 口径（`K × avg_degree × symbol_len`）在**合法**度量参数下就会溢出。
///
/// 这不是崩溃：CLI 不打印 stats（`format_trial` 只打 seed/received/success/
/// missing），所以用户看不到；但库用户拿到的会是**负数**操作计数，而
/// `docs/implementation.md` 用它做复杂度论证。改字段类型属破坏性 API 变更
/// （HANDOVER §19.6 已记录该裁定），本轮**只加记录性断言 + 文档注记**：
/// 把「它会溢出、溢出的量级是多少、为什么暂不改」钉在测试里，下一轮谁要
/// 改类型有据可依。
test "LT16: xor_bytes worst case does not fit in Int32 (recorded, not fixed)" {
  // 文档口径的上界：K（源符号）× 平均度数 × 单符号长度。
  // 取 K=200、平均度数 12、symbol_len=1 MB（LT_MAX_SYMBOL_LEN）：
  // 2.5e9 > Int32::MAX = 2147483647。
  let worst : Int64 = 200L * 12L * 1048576L
  assert_true(worst > 2147483647L)
  // 同一个偶合下 Int32 会回绕成负数 —— 这只是算术事实，不需要真跑 2 GB。
  let wrapped = worst.to_int()
  assert_true(wrapped < 0)
}

///|
/// `xor_bytes` 的**语义**是可断言的：每个解出的源符号把它出现过的每个
/// 收到符号都 XOR 一遍，每次 `symbol_len` 字节。因此同样的 (seed, K,
/// overhead) 下 `xor_bytes` 与 `symbol_len` **严格成正比** —— 这条比
/// 「跑一遍看看数对不对」更能锁住公式。
test "LT16: xor_bytes scales exactly with symbol_len" {
  let small = decode_with_stats(
    7UL,
    40,
    8,
    random_received(7UL, 40, 1.2, 8),
    0.1,
    0.5,
  ) catch {
    e => abort("symbol_len=8: \{error_text(e)}")
  }
  let big = decode_with_stats(
    7UL,
    40,
    16,
    random_received(7UL, 40, 1.2, 16),
    0.1,
    0.5,
  ) catch {
    e => abort("symbol_len=16: \{error_text(e)}")
  }
  let a = small.1.xor_bytes
  let b = big.1.xor_bytes
  assert_true(a > 0)
  assert_eq(b, a * 2)
  // 两个视图（stats.resolved 与结果的 missing）必须自洽
  assert_eq(small.1.resolved + small.0.missing_count(), 40)
}

///|
/// 按 `(seed, K, overhead, symbol_len)` 造一批编码符号（测试夹具）。
fn random_received(
  seed : UInt64,
  k : Int32,
  overhead : Double,
  symbol_len : Int32,
) -> Array[ReceivedSymbol] {
  let block = match SourceBlock::new(random_sources(seed, k, symbol_len)) {
    Ok(b) => b
    Err(e) => abort("sources: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let out : Array[ReceivedSymbol] = []
  let count = received_count(k, overhead)
  for i = 0; i < count; i = i + 1 {
    let s = enc.symbol(i)
    out.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  out
}
