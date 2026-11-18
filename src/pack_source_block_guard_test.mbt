///|
/// LT25（2026-11-19 审计）：`SourceBlock` 是 `pub(all)`，调用者可以不经
/// `SourceBlock::new/from_bytes` 直接填字段；`pack_container` 不能只依赖构造器
/// 曾经校验过这些字段。写侧必须复核会进入容器头的 K 与 symbol_len 域。
test "LT25: pack rejects a manually constructed oversized K" {
  let k = @src.max_source_symbols() + 1
  let block = @src.SourceBlock::{ k, symbol_len: 1, sources: [b"\x01"], }
  let outcome = try {
    let packed = @src.pack_container(block, 7UL, b"\x01", 0.1, 0.5, [])
    let back = try {
      let _ = @src.unpack_container(packed)
      "unpacked"
    } catch {
      e => "unpack-raise: \{@src.error_text(e)}"
    }
    "packed → \{back}"
  } catch {
    e => "pack-raise: \{@src.error_text(e)}"
  }
  inspect(
    outcome,
    content="pack-raise: source too large: K=1048577 exceeds the limit of 1048576 source symbols",
  )
}

///|
/// K=0 不是 payload_len 越界：它与正常构造器一样，首先是空源。
test "LT25: pack rejects a manually constructed zero K as EmptySource" {
  let block = @src.SourceBlock::{ k: 0, symbol_len: 1, sources: [], }
  let outcome = try {
    let _ = @src.pack_container(block, 7UL, b"\x01", 0.1, 0.5, [])
    "packed"
  } catch {
    e => @src.error_text(e)
  }
  inspect(
    outcome,
    content="empty source: at least one source symbol with a non-zero length is required",
  )
}

///|
/// symbol_len=0 同理；不能借 payload_len=1 > K×0 报成另一种头部错误。
test "LT25: pack rejects a manually constructed zero symbol_len as EmptySource" {
  let block = @src.SourceBlock::{ k: 1, symbol_len: 0, sources: [b""], }
  let outcome = try {
    let _ = @src.pack_container(block, 7UL, b"\x01", 0.1, 0.5, [])
    "packed"
  } catch {
    e => @src.error_text(e)
  }
  inspect(
    outcome,
    content="empty source: at least one source symbol with a non-zero length is required",
  )
}
