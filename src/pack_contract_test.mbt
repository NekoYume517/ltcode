///|
/// LT20（2026-11-17 审计）：`pack_container` 不校验 `payload` 与 `block`，
/// 于是**写得出自己读不回**的容器。
///
/// 两条独立的自洽性：
/// 1. `payload.length() <= K × symbol_len` —— 否则 `unpack_container` 的
///    `payload_len` 域校验会直接判死（`InvalidHeaderField`）；
/// 2. 每个符号体的长度 == `block.symbol_len` —— 否则 `decode_with_stats`
///    的 `TruncatedSymbol` 会判死。
///
/// CLI 路径两个量同源（`data` 既切块又算哈希），所以这两条恒真；但
/// `pack_container` 是 `pub` 的，绕过 CLI 直接调库就能造出坏容器 ——
/// 与 LT-I（`--count 0` 写出的头被自己的解码器拒）同族的第二只。
///
/// 修法：`pack_container` 加前置校验并 `raise`（调用方必须处理）。测试与
/// CLI 都走自洽输入，因此行为逐字节不变；`cmd_encode` 在 `catch` 里按
/// 输入错误（exit 3）报出 —— 真触发说明有 bug，比静默写出坏容器好。
test "LT20: packing a payload longer than K*symbol_len is rejected" {
  let block = match SourceBlock::from_bytes(Bytes::make(100, b'\x11'), 10) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  // block.symbol_len = 10，K = 10 → 上限 100 字节；给 200 字节
  assert_eq(block.symbol_len, 10)
  let too_long = Bytes::make(200, b'\x12')
  let outcome = try {
    let _ = pack_container(block, 1UL, too_long, 0.1, 0.5, [])
    "ok"
  } catch {
    LtError::InvalidHeaderField(name, value, _, high) =>
      "hdr:\{name}=\{value}/\{high}"
    e => "other:\{error_text(e)}"
  }
  inspect(outcome, content="hdr:payload_len=200/100")
}

///|
/// 符号体长度与头部 `symbol_len` 不一致同样要被拦（修复前写得进去，读的
/// 时候才在 `decode_with_stats` 里炸 `TruncatedSymbol`）。
test "LT20: packing a symbol body of the wrong length is rejected" {
  let data = Bytes::make(100, b'\x13')
  let block = match SourceBlock::from_bytes(data, 10) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let bad : Array[Symbol] = [
    Symbol::{ index: 0, data: Bytes::make(9, b'\x00'), },
  ]
  let outcome = try {
    let _ = pack_container(block, 1UL, data, 0.1, 0.5, bad)
    "ok"
  } catch {
    LtError::SymbolLengthMismatch(a, b) => "len:\{a}/\{b}"
    e => "other:\{error_text(e)}"
  }
  inspect(outcome, content="len:10/9")
}

///|
/// 不误伤：**自洽**的输入（含 `--count 0` 的零符号容器、以及 `payload_len`
/// 小于 `K × symbol_len` 的补零情形）必须照旧写出来，且能被读回。
test "LT20: self-consistent inputs still pack and unpack" {
  let data = Bytes::make(101, b'\x14')
  let block = match SourceBlock::from_bytes(data, 10) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  // 101 字节、K=10 → symbol_len=11 → 上限 110 >= 101，补零情形
  assert_eq(block.symbol_len, 11)
  let enc = match Encoder::new(block, 3UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let packed = pack_container(block, 3UL, data, 0.1, 0.5, enc.symbols(0, 30)) catch {
    _ => abort("self-consistent pack raised")
  }
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  assert_eq(c.payload_len, 101)
  match decode_verified(c) {
    Complete(sources) => {
      let round = reassemble(sources, 101)
      assert_eq(round, data)
    }
    Incomplete(_, missing) => abort("missing \{missing.length()}")
  }
  // 零符号容器（README 的 --count 0 契约）不受新校验影响
  let zero = pack_container(block, 3UL, data, 0.1, 0.5, []) catch {
    _ => abort("zero-symbol pack raised")
  }
  let zc = unpack_container(zero) catch { _ => abort("zero unpack raised") }
  assert_eq(zc.symbols.length(), 0)
}
