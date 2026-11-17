/// LT4（2026-11-15 审计）：`robust_tau` 的 τ 尖峰公式在 `r = 0` 时算出
/// `0 · ln(0/δ) = 0 · (-inf) = NaN`。
///
/// `r = c·ln(K/δ)·√K = 0` 的唯一解是 **K=1 且 δ=1**（δ≤1、K≥1 时
/// `ln(K/δ) ≥ 0`，等号只在 K=δ=1）。此时 `robust_kr_index` 返回 1，
/// `d == kr` 分支给出 NaN，`robust_beta` 与 `robust_distribution` 全部
/// 变 NaN，`validate_distribution` 在第一个 pmf 项就拒绝 —— 报的还是
/// `DistributionNotNormalized(0.0)`（遇到 NaN 时累计值还是 0）。
///
/// 但 δ=1.0 是**域内合法**参数：LT3 之后 `delta_q=100`（δ=1.00）通过了
/// 头部域校验，decode 却借「分布未归一化」把它拒掉 —— 合法输入被拒 +
/// 文案指错对象，正是 LT3 要消灭的那一族。
///
/// 数学上 K=1、δ=1 的鲁棒孤波完全良定义：τ 尖峰在 r=0 处不存在
/// （`r·ln(r/δ)` 在 r→0⁺ 的极限是 0），分布退化为 μ(1)=1，编码与解码
/// 都应当工作。

///|
/// τ 尖峰在 r=0 时必须是 0，而不是 NaN。
test "LT4: tau spike at r=0 (K=1, delta=1) is 0, not NaN" {
  let t = robust_tau(1, 1, 0.1, 1.0)
  assert_true(!t.is_nan())
  assert_true(t == 0.0)
}

///|
/// `robust_soliton_checked` 必须接受 (K=1, δ=1)：分布 μ(1)=1，归一化。
test "LT4: robust soliton (K=1, delta=1) is accepted and equals mu(1)=1" {
  let dist = match robust_soliton_checked(1, 0.1, 1.0) {
    Ok(d) => d
    Err(e) => abort("legal (K=1, delta=1) rejected: \{error_text(e)}")
  }
  let p1 = dist.pdf(1)
  assert_true((p1 - 1.0).abs() < 0.000000000001)
}

///|
/// 库级往返：K=1、δ=1.0 的编码与解码必须走通（修复前 `Encoder::new`
/// 直接 Err）。
test "LT4: encode/decode round trip with K=1 and delta=1.0" {
  let data = Bytes::from_array([
    b'\x37', b'\x11', b'\xf0', b'\x02', b'\xa5', b'\x99',
  ])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 12345UL, 0.1, 1.0) {
    Ok(e) => e
    Err(e) => abort("Encoder::new rejected delta=1.0: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 3)
  let received : Array[ReceivedSymbol] = []
  for s in symbols {
    received.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let result = decode_full(12345UL, 1, 6, received, 0.1, 1.0)
  let sources = match result {
    Complete(v) => v
    Incomplete(_, missing) =>
      abort("decode incomplete with delta=1.0: missing \{missing.length()}")
  }
  assert_eq(sources[0], block.sources[0])
}

///|
/// 容器级：`pack_ok(c, delta=1.0)` 产出的头部（delta_q=100）必须
/// 能被 `unpack_container` + `decode_verified` 读回 —— pack 与 unpack
/// 对同一个合法域值给出一致答案。
test "LT4: packed container with delta=1.0 (delta_q=100) decodes verified" {
  let data = Bytes::from_array([b'\x01', b'\x02', b'\x03', b'\x04'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 777UL, 0.1, 1.0) {
    Ok(e) => e
    Err(e) => abort("Encoder::new: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 3)
  let packed = pack_ok(block, 777UL, data, 0.1, 1.0, symbols)
  // 头部第 6 字节确实是 delta_q=100
  assert_true(packed[6].to_int() == 100)
  let c = unpack_container(packed) catch {
    e => abort("unpack rejected legal delta_q=100: \{error_text(e)}")
  }
  let result = decode_verified(c)
  assert_true(result.is_complete())
}
