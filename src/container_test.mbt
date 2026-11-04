///|
/// 容器格式测试。
///
/// 这一层最重要的三条：
/// 1. **往返**：`unpack(pack(x)) == x`（每个字段都要对，尤其是浮点参数
///    经过量化后必须能精确还原）。
/// 2. **自描述**：解码只需要文件本身，不需要外部参数。
/// 3. **校验和真的拦住损坏**：篡改一个符号后，解码可能仍然"成功"，
///    但重算的 payload 哈希必须不匹配 —— 这是 `Complete` 的定义的一部分。
///
/// 文件头是**跨版本契约**：字段顺序、大小、大端都是明文规定的。
/// 测试把这些字节位置固定住，防止有人「顺手」调整格式。

///|
fn sample_block(k : Int32, symbol_len : Int32) -> SourceBlock {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let b : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      b[j] = ((i * 17 + j * 5 + 3) % 251).to_byte()
    }
    sources.push(Bytes::from_array(b))
  }
  match SourceBlock::new(sources) {
    Ok(b) => b
    Err(_) => abort("sample_block failed")
  }
}

///|
fn sample_payload(block : SourceBlock) -> Bytes {
  let out : Array[Byte] = []
  for s in block.sources {
    for j = 0; j < s.length(); j = j + 1 {
      out.push(s[j])
    }
  }
  Bytes::from_array(out)
}

///|
test "container: header layout is locked byte by byte" {
  let block = sample_block(4, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [
    Symbol::{ index: 0, data: b"\x11\x12", },
    Symbol::{ index: 7, data: b"\x21\x22", },
  ]
  let packed = pack_container(
    block, 0x0102030405060708UL, payload, 0.1, 0.5, symbols,
  )
  inspect(header_len(), content="43")
  // 魔数 "LTC2"
  inspect(packed[0].to_int(), content="76")
  inspect(packed[1].to_int(), content="84")
  inspect(packed[2].to_int(), content="67")
  inspect(packed[3].to_int(), content="50")
  // 版本 2
  inspect(packed[4].to_int(), content="2")
  // c 量化：0.1 -> 10；delta：0.5 -> 50
  inspect(packed[5].to_int(), content="10")
  inspect(packed[6].to_int(), content="50")
  // K = 4（偏移 7..11）
  inspect(packed[7].to_int(), content="0")
  inspect(packed[10].to_int(), content="4")
  // seed（偏移 11..19）
  inspect(packed[11].to_int(), content="1")
  inspect(packed[18].to_int(), content="8")
  // symbol_len = 2（偏移 19..23）
  inspect(packed[22].to_int(), content="2")
  // payload_len = 8（偏移 23..31）
  inspect(packed[30].to_int(), content="8")
  // count = 2（偏移 39..43）
  inspect(packed[42].to_int(), content="2")
  // 总长度 = header(43) + 2*(4 + 2) = 55
  inspect(packed.length(), content="55")
}

///|
test "container: round trip preserves every field exactly" {
  let block = sample_block(6, 3)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [
    Symbol::{ index: 0, data: b"\x00\x01\x02", },
    Symbol::{ index: 1, data: b"\xFF\xFE\xFD", },
    Symbol::{ index: 9, data: b"\x7F\x80\x81", },
  ]
  let packed = pack_container(
    block, 0xDEADBEEFCAFEBABEUL, payload, 0.1, 0.5, symbols,
  )
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  inspect(c.k, content="6")
  assert_eq(c.seed, 0xDEADBEEFCAFEBABEUL)
  inspect(c.symbol_len, content="3")
  inspect(c.payload_len, content="18")
  assert_eq(c.payload_hash, payload_hash(payload))
  // 浮点参数经过百分之一量化后必须精确还原
  let dc = c.c - 0.1
  let dd = c.delta - 0.5
  assert_true(dc.abs() < 0.000000000001)
  assert_true(dd.abs() < 0.000000000001)
  inspect(c.symbols.length(), content="3")
  inspect(c.symbols[0].index, content="0")
  inspect(c.symbols[2].index, content="9")
  assert_eq(c.symbols[1].data, b"\xFF\xFE\xFD")
  assert_eq(c.symbols[2].data, b"\x7F\x80\x81")
}

///|
test "container: payload_hash distinguishes payloads" {
  let a = payload_hash(b"hello")
  let b = payload_hash(b"hellp")
  assert_true(a != b)
  // 空输入也要有确定值（FNV offset basis）
  assert_eq(payload_hash(b""), 0xCBF29CE484222325UL)
  // 单字节翻转必须改变哈希
  let c = payload_hash(b"hello")
  let d = payload_hash(b"iello")
  assert_true(c != d)
}

///|
test "container: quantize/dequantize are inverse on percentages" {
  for q = 0; q <= 100; q = q + 1 {
    let d = q.to_double() / 100.0
    inspect(quantize_param(d), content="\{q}")
    let back = dequantize_param(q)
    let err = back - d
    assert_true(err.abs() < 0.000000000001)
  }
  // 钳位
  inspect(quantize_param(-1.0), content="0")
  inspect(quantize_param(3.0), content="255")
}

///|
test "container: truncated input raises, never invents bytes" {
  let block = sample_block(2, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [Symbol::{ index: 0, data: b"\x01\x02", }]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  // 空
  try {
    let _ = unpack_container(b"")
    abort("expected failure on empty input")
  } catch {
    TruncatedSymbol(_, _) => ()
    _ => abort("wrong error for empty")
  }
  // 截到头部中间
  let half = packed.clamped_view(end=20)
  try {
    let _ = unpack_container(half.to_owned())
    abort("expected failure on short header")
  } catch {
    TruncatedSymbol(_, _) => ()
    _ => abort("wrong error for short header")
  }
  // 头部完整但符号数据被截断
  let cut = packed.clamped_view(end=packed.length() - 1)
  try {
    let _ = unpack_container(cut.to_owned())
    abort("expected failure on truncated symbol body")
  } catch {
    TruncatedSymbol(_, _) => ()
    _ => abort("wrong error for truncated body")
  }
}

///|
/// **LT-2**：魔数不符报 `BadMagic`，不是 `TruncatedSymbol`。
///
/// 旧实现 raise `TruncatedSymbol(data.length(), header_len())`，CLI 于是把
/// "这根本不是 ltcode 文件"说成"文件被截断了" —— 调用方会去重传一个坏
/// 文件，而不是换一个正确的文件。**这条断言是行为变更**：它原本锁定
/// `TruncatedSymbol`，那是被 LT-2 判定为错位的语义。
test "container: bad magic is rejected with BadMagic" {
  let block = sample_block(2, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [Symbol::{ index: 0, data: b"\x01\x02", }]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  let arr = packed.to_array()
  arr[0] = b'X'
  try {
    let _ = unpack_container(Bytes::from_array(arr))
    abort("expected magic rejection")
  } catch {
    BadMagic => ()
    e => abort("wrong error for bad magic: \{error_text(e)}")
  }
}

///|
/// **LT-2**：版本不符报 `UnsupportedVersion(文件版本, 本构建版本)`，不借用
/// `SourceTooLarge`。
///
/// 旧实现 raise `SourceTooLarge(version, container_version)`，`error_text`
/// 于是输出 "source too large: K=3 exceeds the limit of 2" —— 一个版本号
/// 被当成源符号数报了出来。**这条断言也是行为变更**。
test "container: wrong version is rejected with UnsupportedVersion" {
  let block = sample_block(2, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [Symbol::{ index: 0, data: b"\x01\x02", }]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  let arr = packed.to_array()
  arr[4] = (container_version + 1).to_byte()
  try {
    let _ = unpack_container(Bytes::from_array(arr))
    abort("expected version rejection")
  } catch {
    UnsupportedVersion(found, expected) => {
      inspect(found, content="\{container_version + 1}")
      inspect(expected, content="\{container_version}")
    }
    e => abort("wrong error for version mismatch: \{error_text(e)}")
  }
}

///|
/// **LT-2**：两个新变体的人读文本必须能当场分辨"不是容器"与"版本不对"。
///
/// 措辞固定（脚本可按文本匹配），因此这里逐字锁定。
test "container: LT-2 error_text wording distinguishes magic from version" {
  // CLI 的 `cmd_decode` 已经带 "not a ltcode container: " 前缀，因此这里
  // 只给 "bad magic" —— 否则实际输出会变成
  // "not a ltcode container: not a ltcode container: bad magic"。
  assert_eq(error_text(BadMagic), "bad magic")
  assert_eq(
    error_text(UnsupportedVersion(3, 2)),
    "unsupported container version 3, this build supports 2",
  )
  // 两条措辞不能互相污染，也不能落回旧的 "source too large"
  assert_true(error_text(BadMagic) != error_text(TruncatedSymbol(64, 43)))
  assert_true(!error_text(BadMagic).contains("truncated"))
  assert_true(
    !error_text(UnsupportedVersion(3, 2)).contains("source too large"),
  )
}

///|
/// **自描述性**：从文件解出的全部参数足以完成解码，不需要外部信息。
///
/// 用 overhead 4.0 而不是 2.0：K=20 在 2.0 下实测成功率 186/200，
/// 这条测试会有约 7% 的概率「随机」失败 —— 那不是它要检验的东西。
test "container: unpacked file is sufficient to decode with no extra args" {
  let k = 20
  let block = sample_block(k, 4)
  let payload = sample_payload(block)
  let seed = 0x1234UL
  let enc = match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 80)
  let packed = pack_container(block, seed, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  // 只用文件里的字段解码
  let r = decode_full(c.seed, c.k, c.symbol_len, c.symbols, c.c, c.delta) catch {
    _ => abort("decode raised")
  }
  match r {
    Complete(sources) => {
      for i = 0; i < k; i = i + 1 {
        assert_eq(sources[i], block.sources[i])
      }
      // 校验和必须通过
      assert_eq(
        payload_hash(reassemble(sources, c.payload_len)),
        c.payload_hash,
      )
    }
    Incomplete(_, missing) =>
      abort("self-described decode failed, missing \{missing.length()}")
  }
}

///|
/// **校验和拦住静默损坏**。
///
/// 这是本项目一个真实的发现：把**一个度为 1 的符号**改掉一个字节后，
/// 剥皮照常跑完、返回 `Complete`，而解出来的若干源符号是错的。
/// 只用 `DecodeResult` 判断"成功"会写出一份"看起来成功、内容错误"的文件。
///
/// 这条测试固定住：篡改导致重算的 payload 哈希与原哈希不符。
test "container: tampered degree-1 symbol is caught by the payload checksum" {
  let k = 20
  let block = sample_block(k, 4)
  let payload = sample_payload(block)
  let seed = 0xCAFEUL
  let dist = robust_distribution(k, 0.1, 0.5)
  let enc = match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 80)
  let packed = pack_container(block, seed, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch { _ => abort("unpack raised") }
  // 找一个度为 1 的符号，篡改它的第一个字节
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
  // 解码可能仍然报 Complete（这正是危险之处）；也可能卡住 —— 都算"不接受"
  let r = decode_full(c.seed, c.k, c.symbol_len, tampered, c.c, c.delta) catch {
    _ => abort("decode raised")
  }
  match r {
    Complete(sources) => {
      let bytes = reassemble(sources, c.payload_len)
      // 关键断言：重算的哈希 ≠ 头部的哈希
      assert_true(payload_hash(bytes) != c.payload_hash)
    }
    Incomplete(_, _) => ()
  }
}
