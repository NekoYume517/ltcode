///|
/// LT26（2026-11-19 审计）：decode_verified 是公开 Container 的校验解码入口，
/// 必须与 unpack_container 一样拒绝非法 payload_len；否则它会先恢复真实数据，
/// 再按非法长度裁切并用裁切后的哈希制造 Complete 假成功。
fn lt26_container(payload_len : Int32, hash : UInt64) -> Container {
  let data = b"\x5a"
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 77UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let received : Array[ReceivedSymbol] = []
  for s in enc.symbols(0, 16) {
    received.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  Container::{
    k: 1,
    seed: 77UL,
    symbol_len: 1,
    payload_len,
    payload_hash: hash,
    c: 0.1,
    delta: 0.5,
    symbols: received,
  }
}

///|
test "LT26: verified decode rejects zero payload_len instead of returning empty Complete" {
  let container = lt26_container(0, payload_hash(b""))
  let outcome = try {
    match decode_verified(container) {
      Complete(sources) =>
        "Complete(reassembled=\{reassemble(sources, container.payload_len).length()})"
      Incomplete(_, missing) => "Incomplete(missing=\{missing.length()})"
    }
  } catch {
    e => "raise: \{error_text(e)}"
  }
  inspect(
    outcome,
    content="raise: invalid container header: payload_len=0 is below the minimum 1; the encoder cannot produce a container with a zero-length payload (empty input is rejected by EmptySource), so this header can only come from hand-crafted bytes",
  )
}

///|
/// 上界同样要在解码入口复核；reassemble 对超长长度只返回现有字节，不能借此
/// 让一个声明 payload_len=2、实际只有 1 字节的容器通过 verified decode。
test "LT26: verified decode rejects payload_len above K times symbol_len" {
  let container = lt26_container(2, payload_hash(b"\x5a"))
  let outcome = try {
    match decode_verified(container) {
      Complete(sources) =>
        "Complete(reassembled=\{reassemble(sources, container.payload_len).length()})"
      Incomplete(_, missing) => "Incomplete(missing=\{missing.length()})"
    }
  } catch {
    e => "raise: \{error_text(e)}"
  }
  inspect(
    outcome,
    content="raise: invalid container header: payload_len=2 exceeds the maximum 1",
  )
}
