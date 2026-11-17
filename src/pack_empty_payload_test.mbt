///|
/// LT23（2026-11-17-b 审计）：`pack_container` 仍能写出 `payload_len = 0`
/// 的容器 —— LT21 的镜像缺口。
///
/// 上一轮（LT21）把 `unpack_container` 的 `payload_len` 域从 `0 ..=` 收到
/// `1 ..=`，理由写在 `src/container.mbt` 与 `API.md` §8：
///
/// > 编码器**永远产不出**这种容器：空输入在 `SourceBlock::from_bytes` 就被
/// > `EmptySource` 拒掉，`payload.length() >= 1` 恒成立。
///
/// 并让 `error_text` 对 `payload_len=0` 追加一句「the encoder cannot produce
/// a container with a zero-length payload …, so this header can only come
/// from hand-crafted bytes」。
///
/// 那句话在库层是**假的**：`pack_container` 的第二个数据参数就是原始
/// payload 字节，它能收 `Bytes::make(0)`，而它的前置校验（LT20）只查
/// `payload.length() > K × symbol_len` —— `0 > limit` 为假，于是它照样把
/// 一个 `payload_len=0` 的头写出来，再被自己的 `unpack_container` 判死，
/// 报文还告诉用户「这份头只可能来自手工字节」（实际是它刚写的）。
///
/// 与 LT20（`payload` 超长 / 符号体长度不符）是同一件事的第三只：**写出去
/// 必须读得回来**。修复与 LT20 同形 —— `pack_container` 前置校验并 `raise`。
test "LT23: packing an empty payload is rejected" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x01'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let empty : Bytes = Bytes::make(0, b'\x00')
  let outcome = try {
    let packed = pack_container(block, 7UL, empty, 0.1, 0.5, [])
    let mut payload_len = 0UL
    for i = 23; i < 31; i = i + 1 {
      payload_len = (payload_len << 8) | packed[i].to_uint64()
    }
    let back = try {
      let _ = unpack_container(packed)
      "unpacked"
    } catch {
      e => "unpack-raise: \{error_text(e)}"
    }
    "packed payload_len=\{payload_len} → \{back}"
  } catch {
    e => "pack-raise: \{error_text(e)}"
  }
  inspect(
    outcome,
    content="pack-raise: empty source: at least one source symbol with a non-zero length is required",
  )
}

///|
/// 不误伤：**一个字节**的 payload 必须照旧写出、读回、解码。
///
/// 下界是 1 而不是「差不多 1」：`SourceBlock::from_bytes` 对空输入报
/// `EmptySource`，对 1 字节输入给出 `symbol_len = 1` —— 这正是
/// `payload_len` 域的真实下界，边界两侧各取一次。
test "LT23: a one-byte payload still packs, unpacks and decodes" {
  let data = Bytes::from_array([b'\x5a'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 3UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let packed = pack_container(block, 3UL, data, 0.1, 0.5, enc.symbols(0, 8)) catch {
    e => abort("one-byte pack raised: \{error_text(e)}")
  }
  let c = unpack_container(packed) catch {
    e => abort("one-byte unpack raised: \{error_text(e)}")
  }
  assert_eq(c.payload_len, 1)
  match decode_verified(c) {
    Complete(sources) => {
      let round = reassemble(sources, 1)
      assert_eq(round, data)
    }
    Incomplete(_, missing) => abort("missing \{missing.length()}")
  }
}
