///|
/// LT28（2026-11-20）：SourceBlock 是 public(all)，Encoder 不能把手工对象
/// 当成已经通过 SourceBlock::new 的对象；构造时必须重新验证完整形状。

///|
fn assert_encoder_rejects(block : @src.SourceBlock) -> Unit {
  match @src.Encoder::new(block, 7UL, 0.1, 0.5) {
    Ok(_) => abort("Encoder::new accepted a malformed SourceBlock")
    Err(_) => ()
  }
  match @src.Encoder::try_new(block, 7UL, 0.1, 0.5) {
    Ok(_) => abort("Encoder::try_new accepted a malformed SourceBlock")
    Err(_) => ()
  }
}

///|
test "LT28: Encoder rejects a source array shorter than declared K" {
  let block = @src.SourceBlock::{ k: 2, symbol_len: 1, sources: [b"\x01"], }
  assert_encoder_rejects(block)
}

///|
test "LT28: Encoder rejects per-source lengths different from symbol_len" {
  let block = @src.SourceBlock::{
    k: 2,
    symbol_len: 1,
    sources: [b"\x01", b"\x02\x03"],
  }
  assert_encoder_rejects(block)
  let extra = @src.SourceBlock::{
    k: 1,
    symbol_len: 1,
    sources: [b"\x01", b"\x02"],
  }
  assert_encoder_rejects(extra)
}

///|
test "LT28: a well-formed manual block remains byte-for-byte compatible" {
  let manual = @src.SourceBlock::{
    k: 2,
    symbol_len: 2,
    sources: [b"\x01\x02", b"\x03\x04"],
  }
  let constructed = match @src.SourceBlock::new(manual.sources) {
    Ok(block) => block
    Err(e) => abort("valid source rejected: \{@src.error_text(e)}")
  }
  let a = match @src.Encoder::new(manual, 99UL, 0.1, 0.5) {
    Ok(encoder) => encoder.symbol(5)
    Err(e) => abort("manual encoder rejected: \{@src.error_text(e)}")
  }
  let b = match @src.Encoder::new(constructed, 99UL, 0.1, 0.5) {
    Ok(encoder) => encoder.symbol(5)
    Err(e) => abort("constructed encoder rejected: \{@src.error_text(e)}")
  }
  assert_eq(a, b)
}
