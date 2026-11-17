///|
/// LT21（2026-11-17 审计，Lead 裁决方向 1）：`payload_len = 0` 的容器必须报错。
///
/// 修复前 `unpack_container` 的 `payload_len` 域是 `0 ..= min(K × symbol_len,
/// 2^31-1)`，于是一份**手工构造**的头部（`payload_len=0` + 与之自洽的
/// `payload_hash = FNV("")`）会让 `decode_verified` 报 `Complete` 并写出一个
/// **0 字节**的文件 —— `decoded OK: ... payload=0 bytes (checksum verified)`。
///
/// 而编码器**永远产不出**这种容器：空输入在 `SourceBlock::from_bytes` 就被
/// `EmptySource` 拒掉，`payload.length() >= 1` 恒成立。于是「encode 产不出」
/// 与「decode 当成功」两条路径口径不一致 —— 与本轮 LT20（`pack_container`
/// 不校验 payload vs block，写出读不回的容器）是同一件事的编码/解码两侧
/// 镜像。
///
/// 修法：域收窄到 `1 ..= min(K × symbol_len, 2^31-1)`。这是**收窄**而不是
/// 新增静默行为：伪造的容器从「成功解出 0 字节」变成「头部非法」，方向正确。
///
/// 回归改动（本条唯一一处改既有测试）：`header_guard_test.mbt` 的 LT-A 那条
/// 原本把 `payload_len == 0` 当作「合法下界」断言（`inspect(pc.payload_len,
/// content="0")` + `abort("payload_len = 0 rejected")`）。那条断言锁的是
/// 「**格式允许这个字段取 0**」这一表述，而不是任何调用方依赖的契约 ——
/// 其自己的注释就写着「容器格式允许，encode 侧的 `EmptySource` 才拒绝」，
/// 即作者知道编码器产不出。LT21 把 decode 侧对齐到 encode 侧，因此那条
/// 断言的**方向**被反转（现在断言它必须被拒），理由见报告 §4.1。
test "LT21: a zero-length payload header is rejected" {
  let data = Bytes::make(8, b'\x21')
  let block = match SourceBlock::from_bytes(data, 4) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 5UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let packed = pack_container(block, 5UL, data, 0.1, 0.5, enc.symbols(0, 6)) catch {
    _ => abort("pack raised")
  }
  // 把 payload_len 改成 0（偏移 23..31），同时把 payload_hash 改成 FNV("")
  // 让这份伪造容器"自洽" —— 修复前正是这种组合会 exit 0 并写出空文件。
  let arr = packed.to_array()
  for i = 0; i < 8; i = i + 1 {
    arr[23 + i] = b'\x00'
  }
  let empty_hash = payload_hash(Bytes::make(0, b'\x00'))
  for i = 0; i < 8; i = i + 1 {
    arr[31 + i] = ((empty_hash >> ((7 - i) * 8)) & 0xFFUL).to_byte()
  }
  let outcome = try {
    let _ = unpack_container(Bytes::from_array(arr))
    "ok"
  } catch {
    InvalidHeaderField(name, value, low, _) => "\{name}=\{value} min=\{low}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="payload_len=0 min=1")
  // 文案必须说清「编码器产不出」，而不是只丢一个下界数字
  let msg = error_text(InvalidHeaderField("payload_len", 0UL, 1UL, 8UL))
  assert_true(msg.contains("payload_len=0"))
  assert_true(msg.contains("below the minimum 1"))
  assert_true(msg.contains("encoder cannot produce"))
}

///|
/// 相邻契约必须完好：**零符号**容器（`--count 0`）的 `payload_len` 是**非零**
/// 的原长，`count` 才是 0 —— 它在 `.ltc` 里是 `43` 字节的头，解码报
/// `INCOMPLETE`、exit 1。LT21 收窄的是 `payload_len`，绝不能连带打断它。
test "LT21: the symbol-free container is unaffected" {
  let data = Bytes::make(400, b'\x31')
  let block = match SourceBlock::from_bytes(data, 10) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  // 零符号容器：count=0、payload_len=400
  let zero = pack_container(block, 7UL, data, 0.1, 0.5, []) catch {
    _ => abort("zero-symbol pack raised")
  }
  let zc = unpack_container(zero) catch {
    _ => abort("zero container rejected")
  }
  assert_eq(zc.symbols.length(), 0)
  assert_eq(zc.payload_len, 400)
  match decode_verified(zc) {
    Complete(_) => abort("a symbol-free container must not decode")
    Incomplete(_, missing) => assert_eq(missing.length(), 10)
  }
  // 正常容器往返仍然完整
  let enc = match Encoder::new(block, 7UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let full = pack_container(block, 7UL, data, 0.1, 0.5, enc.symbols(0, 20)) catch {
    _ => abort("pack raised")
  }
  let c = unpack_container(full) catch { _ => abort("unpack rejected") }
  assert_eq(c.payload_len, 400)
  match decode_verified(c) {
    Complete(sources) => assert_eq(reassemble(sources, 400), data)
    Incomplete(_, missing) => abort("missing \{missing.length()}")
  }
}
