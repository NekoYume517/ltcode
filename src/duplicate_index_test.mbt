///|
/// LT34（2026-11-23 审计）：重复下标与冲突下标的裁决语义，固化自
/// 2026-11-23 探针（`audit/2026-11-23/ltcode/evidence/probe-run.log` 与
/// `cli-probe-full.log`）。
///
/// 三条语义一起钉死：
///
/// 1. **精确重复 = 冗余方程，不是 XOR 自毁。** peel 的每个收到符号有独立
///    accumulator，同一 index 出现两次只是两条相同的方程；解出后互相比对
///    一致，解码仍 `Complete` 且载荷逐字节正确。11-22 的逐字节翻转扫描
///    （523 次 decode）测不出「构造的重复」，这里补上。
/// 2. **冲突下标（同 index、不同 payload）= 流序首现者胜出。** 好副本在
///    前时解码照常成功；坏副本在前时解出的源符号直接是错的，由
///    `payload_hash` 兜底 → `CorruptionDetected`（CLI 不落盘）。库层的
///    `decode_full` 裸入口与 11-22 记录的「`decode` 参数不配对时无从判断」
///    同源：唯一权威裁决是 verified 入口的哈希。
/// 3. **CLI 可达形状等价。** 手工在容器里插入重复/冲突记录 + 改 count，
///    `unpack_container` 不做去重（重复是合法输入），结论与库层一致。

///|
fn lt34_payload(seed : UInt64, len : Int32) -> Bytes {
  let rng = @src.Ltrng::new(seed)
  let out : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    out[i] = rng.next_below(256).to_byte()
  }
  Bytes::from_array(out)
}

///|
test "LT34: duplicate indices are redundant equations, payload still correct" {
  let k : Int32 = 30
  let symbol_len : Int32 = 8
  let seed : UInt64 = 0xD0D0UL
  let payload = lt34_payload(0x1234UL + k.to_uint64(), k * symbol_len)
  let block = match @src.SourceBlock::from_bytes(payload, k) {
    Ok(b) => b
    Err(_) => abort("from_bytes")
  }
  let enc = match @src.Encoder::try_new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("try_new")
  }
  let symbols = enc.symbols(0, k * 3)
  let packed = @src.pack_container(block, seed, payload, 0.1, 0.5, symbols) catch {
    _ => abort("pack")
  }
  let c = @src.unpack_container(packed) catch { _ => abort("unpack") }
  // (a) 每个符号都精确重复一次：dup = [s0, s0, s1, s1, ...]
  let dup : Array[@src.ReceivedSymbol] = []
  for s in c.symbols {
    dup.push(s)
    dup.push(s)
  }
  let r = @src.decode_verified({ ..c, symbols: dup, }) catch {
    e => abort("dup exact raised: \{@src.error_text(e)}")
  }
  match r {
    @src.Complete(sources) =>
      assert_true(@src.reassemble(sources, c.payload_len) == payload)
    @src.Incomplete(_, missing) =>
      abort(
        "duplicates must not break completeness: \{missing.length()} missing",
      )
  }
  // (b) 重复装进真实容器（CLI 可达形状）：pack → unpack → decode
  let dup_syms : Array[@src.Symbol] = []
  for s in symbols {
    dup_syms.push(s)
    dup_syms.push(s)
  }
  let packed_dup = @src.pack_container(block, seed, payload, 0.1, 0.5, dup_syms) catch {
    _ => abort("pack dup")
  }
  let cd = @src.unpack_container(packed_dup) catch { _ => abort("unpack dup") }
  assert_eq(cd.symbols.length(), 2 * k * 3)
  let rd = @src.decode_verified(cd) catch {
    e => abort("dup container raised: \{@src.error_text(e)}")
  }
  match rd {
    @src.Complete(sources) =>
      assert_true(@src.reassemble(sources, cd.payload_len) == payload)
    @src.Incomplete(_, _) => abort("dup container must decode")
  }
}

///|
test "LT34: conflicting index resolves first-seen-wins, hash catches the rest" {
  // 语义细节（探针实测）：冲突副本与原符号同 index → 同子集 → 同度数。
  // - 度 1：两者都是「直接定值」方程，队列按数组顺序处理 → **数组里先出现
  //   的那个胜出**，输家的 acc 与已解值比对不符被丢弃。坏副本在前 → 错值
  //   定值 → 剥皮把错值扩散 → 哈希兜底 CorruptionDetected。
  // - 度 > 1：若其余方程已覆盖全部源，这对冲突方程可能**根本不被使用**
  //   （探针实测该情形返回 Complete 且载荷正确）—— 裁决权仍在哈希。
  //   这里选度 1 的符号构造，让两条分支都确定性可断言。
  let k : Int32 = 30
  let symbol_len : Int32 = 8
  let seed : UInt64 = 0xD1D2UL
  let payload = lt34_payload(0x5678UL, k * symbol_len)
  let block = match @src.SourceBlock::from_bytes(payload, k) {
    Ok(b) => b
    Err(_) => abort("from_bytes")
  }
  let enc = match @src.Encoder::try_new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("try_new")
  }
  let symbols = enc.symbols(0, k * 3)
  let packed = @src.pack_container(block, seed, payload, 0.1, 0.5, symbols) catch {
    _ => abort("pack")
  }
  let c = @src.unpack_container(packed) catch { _ => abort("unpack") }
  fn flipped_twin(s : @src.ReceivedSymbol) -> @src.ReceivedSymbol {
    let arr = s.data.to_array()
    arr[0] = (arr[0].to_int() ^ 0xFF).to_byte()
    { index: s.index, data: Bytes::from_array(arr), }
  }
  // 找一个度为 1 的符号（子集长度 1，直接定值一个源符号）
  let dist = @src.robust_distribution(k, 0.1, 0.5) catch { _ => abort("dist") }
  let mut degree1_pos = -1
  for i, s in c.symbols {
    if @src.subset_for(c.seed, s.index, k, dist).length() == 1 {
      degree1_pos = i
      break
    }
  }
  if degree1_pos < 0 {
    abort("no degree-1 symbol found in 90 symbols for K=30")
  }
  // (a) 好副本在前 → 首现者胜出，解码照常成功
  let good_first : Array[@src.ReceivedSymbol] = []
  for i, s in c.symbols {
    good_first.push(s)
    if i == degree1_pos {
      good_first.push(flipped_twin(s))
    }
  }
  let ra = @src.decode_verified({ ..c, symbols: good_first, }) catch {
    e => abort("good-first raised: \{@src.error_text(e)}")
  }
  match ra {
    @src.Complete(sources) =>
      assert_true(@src.reassemble(sources, c.payload_len) == payload)
    @src.Incomplete(_, _) => abort("good-first must decode")
  }
  // (b) 坏副本在前 → 错值先定值并扩散，verified 入口以哈希裁决：
  //     CorruptionDetected，绝不返回 Complete
  let bad_first : Array[@src.ReceivedSymbol] = [
    flipped_twin(c.symbols[degree1_pos]),
  ]
  for s in c.symbols {
    bad_first.push(s)
  }
  let outcome = try {
    match @src.decode_verified({ ..c, symbols: bad_first, }) {
      @src.Complete(_) => "complete_bad"
      @src.Incomplete(_, _) => "incomplete"
    }
  } catch {
    @src.CorruptionDetected(_, _) => "corruption"
    e => "other:\{@src.error_text(e)}"
  }
  inspect(outcome, content="corruption")
}

///|
test "LT34: tampered degree-1 symbol never completes with wrong payload" {
  // 11-22 翻转全扫 523 次 decode 与本轮 CLI 复核（`cli-probe-full.log`
  // 头 43 字节 44 次）的字段归类：
  // - magic/version/K 越域/count 越域/sl 越域/pl 越域 → exit 3 结构拒绝；
  // - c_q 越网格 → exit 3；delta_q > 100 → exit 3；
  // - seed/payload_hash/payload_len 尾字节 → 解出错误 payload，
  //   payload_hash 兜底 → exit 3 CorruptionDetected，不落盘；
  // - K/c_q 的个别低位翻转改变子集 → 子集全变，剥皮卡住 → exit 1
  //   INCOMPLETE（LT18 的诊断行）。
  // 库层等价构造锁住「没有任何输入能得到 Complete + 错误字节」：
  // 度为 1 的符号直接定值一个源符号，篡改它必然污染载荷 —— verified
  // 入口必须以 CorruptionDetected 拒绝；其余位置若哈希对得上，Complete
  // 的载荷就必须等于原文（冗余方程压制的情形），否则同样必须 raise。
  let k : Int32 = 20
  let symbol_len : Int32 = 10
  let seed : UInt64 = 0xF11UL
  let payload = lt34_payload(0x9999UL, k * symbol_len)
  let block = match @src.SourceBlock::from_bytes(payload, k) {
    Ok(b) => b
    Err(_) => abort("from_bytes")
  }
  let enc = match @src.Encoder::try_new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("try_new")
  }
  let symbols = enc.symbols(0, k * 3)
  let packed = @src.pack_container(block, seed, payload, 0.1, 0.5, symbols) catch {
    _ => abort("pack")
  }
  let c = @src.unpack_container(packed) catch { _ => abort("unpack") }
  // 找一个度为 1 的符号（子集长度 1，直接定值一个源符号）
  let mut degree1_pos = -1
  let dist = @src.robust_distribution(k, 0.1, 0.5) catch { _ => abort("dist") }
  for i, s in c.symbols {
    if @src.subset_for(c.seed, s.index, k, dist).length() == 1 {
      degree1_pos = i
      break
    }
  }
  if degree1_pos < 0 {
    abort("no degree-1 symbol found in 60 symbols for K=20")
  }
  // 篡改那个度 1 符号的第一个字节：它直接定值一个源符号，载荷必然被污染
  let tampered : Array[@src.ReceivedSymbol] = []
  for i, s in c.symbols {
    if i == degree1_pos {
      let arr = s.data.to_array()
      arr[0] = (arr[0].to_int() ^ 0xFF).to_byte()
      tampered.push({ index: s.index, data: Bytes::from_array(arr), })
    } else {
      tampered.push(s)
    }
  }
  let outcome = try {
    match @src.decode_verified({ ..c, symbols: tampered, }) {
      @src.Complete(_) => "complete"
      @src.Incomplete(_, _) => "incomplete"
    }
  } catch {
    @src.CorruptionDetected(_, _) => "corruption"
    e => "other:\{@src.error_text(e)}"
  }
  inspect(outcome, content="corruption")
}
