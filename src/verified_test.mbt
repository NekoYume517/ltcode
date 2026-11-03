///|
/// 校验和路径的测试。
///
/// 这一层对应 `docs/implementation.md` §5b 记录的真实缺陷：
/// 剥皮会在被篡改的数据上返回 `Complete`，而解出来的源符号是错的。
/// 因此 `decode_verified` 把"哈希核对通过"并入 `Complete` 的定义。

///|
fn vblock(k : Int32, symbol_len : Int32) -> SourceBlock {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let b : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      b[j] = ((i * 13 + j * 7 + 1) % 251).to_byte()
    }
    sources.push(Bytes::from_array(b))
  }
  match SourceBlock::new(sources) {
    Ok(b) => b
    Err(_) => abort("vblock failed")
  }
}

///|
fn vpayload(block : SourceBlock) -> Bytes {
  let out : Array[Byte] = []
  for s in block.sources {
    for j = 0; j < s.length(); j = j + 1 {
      out.push(s[j])
    }
  }
  Bytes::from_array(out)
}

///|
test "verified: intact container decodes and passes the checksum" {
  let k = 20
  let block = vblock(k, 4)
  let payload = vpayload(block)
  let seed = 0x77UL
  let enc = match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 80)
  let packed = pack_container(block, seed, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  let r = decode_verified(c) catch {
    e => abort("unexpected: \{error_text(e)}")
  }
  match r {
    Complete(sources) => {
      let bytes = reassemble(sources, c.payload_len)
      assert_eq(bytes, payload)
    }
    Incomplete(_, missing) =>
      abort("should complete, missing \{missing.length()}")
  }
}

///|
/// **核心回归**：篡改一个度 1 的符号 → `decode_verified` 必须 raise
/// `CorruptionDetected`，而不是返回 `Complete`。
///
/// 这条测试如果失败，说明有人把校验和又改成了"可选"或者只在 CLI 里做 ——
/// 那正是这个 bug 第一次出现时的形态。
test "verified: tampered degree-1 symbol raises CorruptionDetected" {
  let k = 20
  let block = vblock(k, 4)
  let payload = vpayload(block)
  let seed = 0xCAFEUL
  let dist = robust_distribution(k, 0.1, 0.5)
  let enc = match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 80)
  let packed = pack_container(block, seed, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  // 找度 1 的符号
  let mut target = -1
  for i, s in c.symbols {
    if subset_for(c.seed, s.index, k, dist).length() == 1 && target < 0 {
      target = i
    }
  }
  assert_true(target >= 0)
  let tampered : Array[ReceivedSymbol] = []
  for i, s in c.symbols {
    if i == target {
      let arr = s.data.to_array()
      arr[0] = (arr[0].to_int() ^ 0xFF).to_byte()
      tampered.push(ReceivedSymbol::{
        index: s.index,
        data: Bytes::from_array(arr),
      })
    } else {
      tampered.push(s)
    }
  }
  let bad : Container = { ..c, symbols: tampered, }
  // 关键断言：要么 raise CorruptionDetected，要么 Incomplete。
  // **绝不允许**返回一个 Complete。
  let outcome = try {
    let r = decode_verified(bad)
    if r.is_complete() {
      "COMPLETE (bad!)"
    } else {
      "incomplete"
    }
  } catch {
    CorruptionDetected(_, _) => "corruption"
    _ => "other-error"
  }
  if outcome == "COMPLETE (bad!)" {
    abort("tampered data decoded as Complete — checksum did not run")
  }
  // 篡改一个度 1 符号在这个用例里实测会走到 corruption 分支
  inspect(outcome, content="corruption")
}

///|
test "verified: error_text renders the corruption variant readably" {
  let msg = error_text(CorruptionDetected(1UL, 2UL))
  assert_true(msg.contains("payload checksum mismatch"))
  assert_true(msg.contains("corrupted"))
}
