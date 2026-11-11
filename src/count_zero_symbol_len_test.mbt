///|
/// `--count 0` 的容器必须能被**自己的解码器**读回来（LT-I，2026-11-11 审计）。
///
/// ## 缺陷形态（修复前）
///
/// README 把 `--count 0` 记成一条正常用法：先写一个只有头部的容器，之后
/// 再把符号补进去。`pack_container` 写出的头里 `symbol_len = ceil(payload/K)`，
/// 而 `unpack_container` 把 `symbol_len` 的上界取成了**整个文件的长度**：
///
/// ```moonbit nocheck
/// let symbol_len_max = data.length().to_uint64()   // count=0 时 = 43
/// ```
///
/// 零符号容器只有 43 字节头部，于是「符号体不可能比文件长」这条原本用来
/// 防呆的约束，退化成「`symbol_len <= 43`」。任何 `ceil(payload/K) > 43`
/// 的零符号容器都被判死 —— 对 README 用的 4000 字节 payload 就是 **K <= 93**，
/// 也就是这个特性在它自己文档的例子里根本不工作：
///
/// ```
/// $ ltcode encode --input examples/payload.bin --symbols 10 --count 0 --out zero.ltc
/// encoded 4000 bytes -> K=10 symbol_len=400 symbols=0 seed=…
/// $ ltcode decode --input zero.ltc
/// ltcode: not a ltcode container: invalid container header:
///         symbol_len=400 exceeds the maximum 43
/// exit 3                       ← README 承诺的是 INCOMPLETE / exit 1
/// ```
///
/// 根因是**上界取错了量**：`symbol_len` 的真实约束来自头部自己的
/// `payload_len`（`ceil(payload/K) <= payload`，K>=1），与文件有多长无关；
/// 文件长度只能约束「能装下几个符号」，那是 `count` 的判据，不是
/// `symbol_len` 的判据。
///
/// 本文件同时锁住边界两侧：K=10（`symbol_len=400`，远超 43）必须放行，
/// 而 `symbol_len` 真的超过 `payload_len` 的头部仍然要被拒绝。

///|
/// 构造 K 个等长源符号。与 `container_test.mbt` 的同名助手独立，避免
/// 单文件内耦合。
fn cz_block(k : Int32, symbol_len : Int32) -> SourceBlock {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let b : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      b[j] = ((i * 31 + j * 7 + 5) % 251).to_byte()
    }
    sources.push(Bytes::from_array(b))
  }
  match SourceBlock::new(sources) {
    Ok(b) => b
    Err(_) => abort("cz_block failed")
  }
}

///|
fn cz_payload(block : SourceBlock) -> Bytes {
  let out : Array[Byte] = []
  for s in block.sources {
    for j = 0; j < s.length(); j = j + 1 {
      out.push(s[j])
    }
  }
  Bytes::from_array(out)
}

///|
/// 把容器头部第 `offset` 起的 4 个字节改写成大端 `value`（用于构造
/// 「头部字段非法」的 fixture，比手拼整段头部更不容易写错）。
fn cz_patch_u32(packed : Bytes, offset : Int32, value : UInt32) -> Bytes {
  let arr = packed.to_array()
  for i = 0; i < 4; i = i + 1 {
    let shift = (3 - i) * 8
    arr[offset + i] = ((value >> shift) & 0xFF).to_int().to_byte()
  }
  Bytes::from_array(arr)
}

///|
/// 核心回归：零符号容器的 `symbol_len` 可以超过头部长度（43 字节）。
///
/// K=10、payload 4000 字节 → `symbol_len=400`。修复前 unpack 报
/// `InvalidHeaderField("symbol_len", 400, 1, 43)`；修复后必须解析成功，
/// 且解码如实报 `Incomplete`（缺全部 10 个源符号），不是头部错误。
test "container: zero-symbol container with symbol_len > header_len unpacks" {
  let k = 10
  let block = cz_block(k, 400)
  let payload = cz_payload(block)
  let symbols : Array[Symbol] = []
  let packed = pack_container(
    block, 83924790232133UL, payload, 0.1, 0.5, symbols,
  )
  inspect(packed.length(), content="43")
  let c = unpack_container(packed) catch {
    e => abort("unpack must accept a symbol-free container: \{error_text(e)}")
  }
  inspect(c.k, content="10")
  inspect(c.symbol_len, content="400")
  inspect(c.payload_len, content="4000")
  inspect(c.symbols.length(), content="0")
  assert_eq(c.payload_hash, payload_hash(payload))
  let r = decode_verified(c) catch {
    e => abort("decode must report Incomplete, not an error: \{error_text(e)}")
  }
  match r {
    Incomplete(_, missing) => inspect(missing.length(), content="10")
    Complete(_) => abort("zero symbols cannot possibly decode")
  }
}

///|
/// 边界两侧：README 文档的 K=94（`symbol_len=43`，恰好等于头部长度）
/// 与 K=93（`symbol_len=44`，比头部还长一个字节）都必须放行。
///
/// 修复前这一对的分界正好落在「文件长度」这个假的判据上，于是 K=93
/// 被拒、K=94 通过 —— 这个不对称本身就是根因的指纹。
test "container: the count=0 boundary is symbol_len 43 vs 44, both accepted" {
  let payload_len = 4000
  let ks : Array[Int32] = [93, 94]
  for k in ks {
    let symbol_len = (payload_len + k - 1) / k
    let block = cz_block(k, symbol_len)
    // `from_bytes` 的产物：K 个等长符号，拼接后截到原始 payload 长度
    // （最后一段的补零不进屋 `payload_len`）。
    let payload = cz_payload(block).clamped_view(end=payload_len).to_owned()
    assert_eq(payload.length(), payload_len)
    let packed = pack_container(block, 7UL, payload, 0.1, 0.5, [])
    let c = unpack_container(packed) catch {
      e => abort("K=\{k} symbol_len=\{symbol_len} rejected: \{error_text(e)}")
    }
    inspect(c.symbol_len, content="\{symbol_len}")
    inspect(c.symbols.length(), content="0")
  }
}

///|
/// 上界不能一放了之：`symbol_len` 的**域**仍然两头都要判 —— `0` 与
/// `0x80000000`（转 Int32 会变负）必须报头部字段非法。
///
/// 这条同时守住「放宽上界」没有把负值/零值放进来：`symbol_len = 0` 会让
/// 符号体退化成「只有 index」，`symbol_len = 2^31` 会转成负数、让
/// `body_len` 与 `count_max` 的算术失去意义。
test "container: symbol_len 0 and 2^31 are still rejected on a count=0 header" {
  let block = cz_block(4, 3)
  let payload = cz_payload(block)
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, [])
  let bads : Array[UInt32] = [0U, 2147483648U]
  for bad in bads {
    let forged = cz_patch_u32(packed, 19, bad)
    try {
      let _ = unpack_container(forged)
      abort("symbol_len=\{bad} must be rejected")
    } catch {
      InvalidHeaderField(field, _, _, _) => inspect(field, content="symbol_len")
      e => abort("wrong error for symbol_len=\{bad}: \{error_text(e)}")
    }
  }
}

///|
/// `symbol_len` 大于 `payload_len` 的头部**不是**结构错误（格式允许，
/// `header_guard_test.mbt` 的 `payload_len = 0` 一例已经锁定这一点）。
///
/// 这条断言的是根因本身：`symbol_len` 的合法性与 payload 长短无关，只与
/// 「能不能被 Int32 表示、是不是正数」有关。若有人把以 `payload_len` 或
/// 文件长度为准的上界重新加回来，这条会红。
test "container: symbol_len above payload_len is a well-formed header (count=0)" {
  let block = cz_block(2, 2) // payload 4 字节
  let payload = cz_payload(block)
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, [])
  let forged = cz_patch_u32(packed, 19, 5U) // 5 > payload_len (4)
  let c = unpack_container(forged) catch {
    e => abort("symbol_len=5 with payload_len=4 must unpack: \{error_text(e)}")
  }
  inspect(c.symbol_len, content="5")
  inspect(c.payload_len, content="4")
  inspect(c.symbols.length(), content="0")
}
