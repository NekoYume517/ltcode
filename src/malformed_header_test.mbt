///|
/// 恶意声明头的**主动构造**矩阵（LT41，2026-11-28 审计）。
///
/// ## 为什么需要这一层（与 LT 历史的分工）
///
/// 之前的容器完整性审计走的是**翻转**法（LT19/LT39：逐 bit 翻转 105,944 次，
/// 0 次静默损坏）。翻转擅长发现「本应被拦住却没被拦住」，但它**只能到达
/// 原始文件已经用到的值附近** —— 一个翻转后的 `count` 顶多变到相邻的字节，
/// 永远到不了「`count = 2^31` 而文件只有 52 字节」这种主动构造的极端组合。
///
/// 这一层用**构造**法：直接拼 43 字节头部，让各字段互相矛盾或逼近域边界，
/// 检查三件事：
///
/// 1. **分配前拒绝**：`unpack_container` / `decode_with_stats` 必须在
///    `acc` / `rem` / CSR（`k+1` 的 `Int32` 与 `Int64` 数组）分配**之前**
///    就拒绝，而不是先分配再报错。
/// 2. **错误码分流**：头部字段离谱 → `InvalidHeaderField`（文案点名字段与值）；
///    文件被截断 → `TruncatedSymbol`；尾部多余 → `TrailingBytes`；
///    体积超限 → `ResourceLimitExceeded`。四者不能互相冒充。
/// 3. **`count_max` 的整除边界**：`count_max = 剩余字节 / (4 + symbol_len)`
///    是**向下取整**，所以 `count == count_max` 必须放行、`count_max + 1`
///    必须是 `TruncatedSymbol`。差一就是「最后一个符号读不全却当读到了」。
///
/// ## 本文件锁定的具体矩阵
///
/// | 组 | 构造 | 期望 |
/// |---|---|---|
/// | A | `count`/`K`/`symbol_len`/`payload_len` 互相矛盾 | 全部 `InvalidHeaderField`，exit 3 |
/// | B | `count` 恰好 = `count_max` / +1 | 放行（-> INCOMPLETE 或 Complete）/ `TruncatedSymbol` |
/// | C | 第 3 条之外的「符号体短一个字节」 | `TruncatedSymbol` |
/// | D | 合法尾部补一个字节 | `TrailingBytes` |
/// | E | 体积超 1 GiB 但头部自洽 | `ResourceLimitExceeded`，且**不读符号体** |
/// | F | `K` 取最大值、`count` 极小 | 不崩、不超时、报 INCOMPLETE |

///|
/// 拼一个 43 字节的 LTC2 头。所有值按大端写入，与 `container.mbt` 的布局一致。
fn lt41_header(
  k : UInt64,
  symbol_len : UInt64,
  payload_len : UInt64,
  count : UInt64,
  c_q : Int32,
  delta_q : Int32,
  seed : UInt64,
) -> Bytes {
  let out : Array[Byte] = []
  out.push(b'L')
  out.push(b'T')
  out.push(b'C')
  out.push(b'2')
  out.push(2)
  out.push(c_q.to_byte())
  out.push(delta_q.to_byte())
  lt41_push_u32(out, k)
  lt41_push_u64(out, seed)
  lt41_push_u32(out, symbol_len)
  lt41_push_u64(out, payload_len)
  lt41_push_u64(out, 0x408f149e6f4ea445UL)
  lt41_push_u32(out, count)
  Bytes::from_array(out)
}

///|
fn lt41_push_u32(out : Array[Byte], v : UInt64) -> Unit {
  for shift in [24, 16, 8, 0] {
    out.push(((v >> shift) & 0xFFUL).to_byte())
  }
}

///|
fn lt41_push_u64(out : Array[Byte], v : UInt64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    out.push(((v >> shift) & 0xFFUL).to_byte())
  }
}

///|
/// 一个符号体（index + body），用于拼出「刚好 n 个符号」的文件。
fn lt41_symbol(index : UInt64, symbol_len : Int32, fill : Byte) -> Bytes {
  let out : Array[Byte] = []
  lt41_push_u32(out, index)
  for _ in 0..<symbol_len {
    out.push(fill)
  }
  Bytes::from_array(out)
}

///|
/// 把若干段拼成一个 `Bytes`。
fn lt41_cat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for p in parts {
    for b in p {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// A 组：字段互相矛盾的头部，全部必须在**分配前**被判为头部非法。
///
/// 这里只给 43 字节头（或极短体），所以任何"先分配再报错"的实现会在这些
/// 例子上直接暴露成内存放大或 crash。
test "LT41-A: contradictory header fields are rejected as InvalidHeaderField" {
  let cases : Array[(String, Bytes)] = [
    ("count = 2^31", lt41_header(10UL, 1UL, 10UL, 0x80000000UL, 10, 50, 1UL)),
    ("count = 2^32-1", lt41_header(10UL, 1UL, 10UL, 0xFFFFFFFFUL, 10, 50, 1UL)),
    (
      "payload_len = 2^64-1",
      lt41_header(10UL, 1UL, 0xFFFFFFFFFFFFFFFFUL, 0UL, 10, 50, 1UL),
    ),
    (
      "payload_len > K*symbol_len",
      lt41_header(10UL, 1UL, 11UL, 0UL, 10, 50, 1UL),
    ),
    ("payload_len = 0", lt41_header(10UL, 1UL, 0UL, 0UL, 10, 50, 1UL)),
    (
      "symbol_len = 2^31",
      lt41_header(10UL, 0x80000000UL, 10UL, 0UL, 10, 50, 1UL),
    ),
    ("K = 0", lt41_header(0UL, 1UL, 1UL, 0UL, 10, 50, 1UL)),
    (
      "K > max_source_symbols",
      lt41_header(
        @src.max_source_symbols().to_uint64() + 1UL,
        1UL,
        1UL,
        0UL,
        10,
        50,
        1UL,
      ),
    ),
    ("c_q = 0", lt41_header(10UL, 1UL, 10UL, 0UL, 0, 50, 1UL)),
    ("delta_q = 101", lt41_header(10UL, 1UL, 10UL, 0UL, 10, 101, 1UL)),
  ]
  for entry in cases {
    let (name, data) = entry
    let outcome = try {
      let _ = @src.unpack_container(data)
      "UNPACKED"
    } catch {
      e => @src.error_text(e)
    }
    assert_true(outcome != "UNPACKED")
    // 必须是「头部字段非法」这一族，不能冒充截断/尾部/体积超限。
    assert_true(outcome.contains("invalid container header"))
    ignore(name)
  }
}

///|
/// B 组：`count_max` 的向下取整边界。
///
/// `count_max = remaining / (4 + symbol_len)`。`count == count_max` 必须放行，
/// `count_max + 1` 必须是 `TruncatedSymbol`。差一就会把「最后一个符号读不全」
/// 说成「读全了」。
test "LT41-B: count_max floor boundary accepts exactly and rejects one more" {
  let sl = 4
  let body = 4 + sl
  for n in [0, 1, 2, 3] {
    let syms : Array[Bytes] = []
    for i in 0..<n {
      syms.push(lt41_symbol(i.to_uint64(), sl, b'\x41'))
    }
    let payload = 1UL << 20 // K*sl 之内，p_len 非零
    // 恰好 n 个符号：必须能 unpack
    let exact = lt41_cat(
      [
        lt41_header(
          1UL << 20,
          sl.to_uint64(),
          payload,
          n.to_uint64(),
          10,
          50,
          1UL,
        ),
        ..syms,
      ],
    )
    let ok = try {
      let c = @src.unpack_container(exact)
      c.symbols.length() == n
    } catch {
      _ => false
    }
    assert_true(ok)
    // 声明 n+1 个但只给 n 个：必须是 TruncatedSymbol
    let over = lt41_cat(
      [
        lt41_header(
          1UL << 20,
          sl.to_uint64(),
          payload,
          (n + 1).to_uint64(),
          10,
          50,
          1UL,
        ),
        ..syms,
      ],
    )
    let msg = try {
      let _ = @src.unpack_container(over)
      "UNPACKED"
    } catch {
      e => @src.error_text(e)
    }
    // **只断言 "truncated" 太弱**：`count_max` 差一会把
    // "got 4 of 5" 变成 "got 0 of 4" —— 两者都含 "truncated"，子串断言抓不住。
    // 这里锁住**具体数值**：声明 n+1 条、实有 n 条时，报错必须点名
    // 「够读 n 条、头部声明 n+1 条」。
    //
    // LT42（2026-11-28 审计）：这个分支现在报 `TruncatedSymbolRecords`
    // （量纲 = 符号条数），文案是 `got {n} of {n+1} symbol(s)`。旧文案
    // `got {n} bytes` 把条数说成字节，已改。
    assert_true(msg.contains("truncated symbol records"))
    assert_true(msg.contains("got \{n} of \{n + 1} symbol(s)"))
    ignore(body)
  }
}

///|
/// C 组：符号体短一个字节 —— `TruncatedSymbol`，不能是「读到了短符号」。
test "LT41-C: a symbol body shorter by one byte is a truncated symbol" {
  let sl = 4
  let parts : Array[Bytes] = [
    lt41_header(1UL << 20, sl.to_uint64(), 1UL << 20, 1UL, 10, 50, 1UL),
    lt41_symbol(0UL, sl, b'\x41'),
  ]
  let full = lt41_cat(parts)
  // 砍掉最后一个字节
  let short = full.clamped_view(start=0, end=full.length() - 1).to_owned()
  let msg = try {
    let _ = @src.unpack_container(short)
    "UNPACKED"
  } catch {
    e => @src.error_text(e)
  }
  assert_true(msg.contains("truncated symbol"))
}

///|
/// D 组：合法符号集之后多一个字节 —— `TrailingBytes`，与截断**分开**。
test "LT41-D: one extra byte after the last symbol is trailing bytes" {
  let sl = 4
  let parts : Array[Bytes] = [
    lt41_header(1UL << 20, sl.to_uint64(), 1UL << 20, 1UL, 10, 50, 1UL),
    lt41_symbol(0UL, sl, b'\x41'),
    lt41_cat([Bytes::from_array([b'\x00'])]),
  ]
  let data = lt41_cat(parts)
  let msg = try {
    let _ = @src.unpack_container(data)
    "UNPACKED"
  } catch {
    e => @src.error_text(e)
  }
  assert_true(msg.contains("trailing bytes"))
}

///|
/// E 组：体积超 1 GiB 但头部自洽 —— `ResourceLimitExceeded`，且**不读符号体**。
///
/// 关键在「不读」：文件只有 43 字节，若实现先按 `count` 循环读符号，会在
/// 第一个符号上就报 `TruncatedSymbol`；报体积超限说明**分配前**就拒了。
test "LT41-E: an over-budget body is rejected before any symbol is read" {
  let data = lt41_header(1UL << 20, 2000UL, 1UL << 20, 1000000UL, 10, 50, 1UL)
  let msg = try {
    let _ = @src.unpack_container(data)
    "UNPACKED"
  } catch {
    e => @src.error_text(e)
  }
  assert_true(msg.contains("resource limit exceeded"))
  assert_true(msg.contains("container_bytes"))
}

///|
/// F 组：`K` 取最大值、符号极少 —— 不崩、报 INCOMPLETE。
///
/// `peel` 里 `counts`/`offsets`/`fill` 都是按 `k+1` 分配的（12 MB @ K=1M），
/// 而 `n` 极小。这条锁的是「K 驱动的分配有上界且不会因 n 小而失控」。
test "LT41-F: K at the maximum with one symbol decodes to INCOMPLETE, not a crash" {
  let sl = 1
  let data = lt41_cat([
    lt41_header(
      @src.max_source_symbols().to_uint64(),
      sl.to_uint64(),
      @src.max_source_symbols().to_uint64(),
      1UL,
      10,
      50,
      1UL,
    ),
    lt41_symbol(0UL, sl, b'\x41'),
  ])
  let ct = @src.unpack_container(data) catch {
    e => abort("LT41-F unpack failed: \{@src.error_text(e)}")
  }
  assert_eq(ct.symbols.length(), 1)
  let result = @src.decode_verified(ct) catch {
    _ => abort("LT41-F decode raised unexpectedly")
  }
  assert_false(result.is_complete())
  assert_eq(result.missing_indices().length(), @src.max_source_symbols())
}

///|
/// A 组的**反例**：`symbol_len = Int32.MAX` 配上 `count = 0` 是**合法**头部。
///
/// 这条不是凑数 —— 它记录了「上界在哪」这件事。`symbol_len` 的域是
/// `1 ..= 2147483647`（`unpack_container` 里对 `u32` 的直接域检查），
/// 而 `payload_len <= K * symbol_len` 在这里轻松成立（10 <= 10 * 2^31-1）。
/// 于是它 unpack 成功、`count = 0`、解码报 INCOMPLETE —— 完全符合契约。
///
/// 之所以要专门锁一下：它看起来像"离谱参数"，实际是本仓**允许**的最大
/// `symbol_len`。如果哪天有人把上界收紧，这条会红，提醒他那是契约变更。
test "LT41-A-reverse: symbol_len = Int32.MAX with count = 0 is a legal header" {
  let data = lt41_header(10UL, 2147483647UL, 10UL, 0UL, 10, 50, 1UL)
  let ct = @src.unpack_container(data) catch {
    e => abort("expected a legal header, got: \{@src.error_text(e)}")
  }
  assert_eq(ct.symbol_len, 2147483647)
  assert_eq(ct.k, 10)
  assert_eq(ct.symbols.length(), 0)
  // 零符号必然解不出东西 —— 正常业务状态，不是错误。
  let result = @src.decode_verified(ct) catch {
    _ => abort("decode raised on a legal zero-symbol container")
  }
  assert_false(result.is_complete())
}
