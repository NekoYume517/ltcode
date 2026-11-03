///|
/// 解码器测试。
///
/// 纪律：**先写失败用例，再实现**。本文件的每条测试对应
/// `decoder.mbt` 里的一个具体设计决定。
///
/// `decode` 的签名按 PLAN.md §6 是 `decode(...) -> DecodeResult`，
/// 错误通过 `raise LtError` 抛出（而不是 `Result`）——
/// 「解不出」是 `Incomplete` 这个正常返回值，不是错误。

///|
fn rand_bytes(seed : UInt64, len : Int32) -> Bytes {
  let rng = Ltrng::new(seed)
  let out : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    out[i] = rng.next_below(256).to_byte()
  }
  Bytes::from_array(out)
}

///|
fn block_of(k : Int32, symbol_len : Int32, seed : UInt64) -> SourceBlock {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    sources.push(rand_bytes(seed + i.to_uint64(), symbol_len))
  }
  match SourceBlock::new(sources) {
    Ok(b) => b
    Err(_) => abort("block_of failed")
  }
}

///|
fn encode_n(
  enc : Encoder,
  k : Int32,
  overhead : Double,
  first : Int32,
) -> Array[ReceivedSymbol] {
  let count = (k.to_double() * overhead).to_int()
  let out : Array[ReceivedSymbol] = []
  for i = 0; i < count; i = i + 1 {
    let s = enc.symbol(first + i)
    out.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  out
}

///|
fn build_encoder(block : SourceBlock, seed : UInt64) -> Encoder {
  match Encoder::new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("encoder build failed")
  }
}

///|
test "decoder: K=10 overhead=2.0 must succeed and recover byte-exactly" {
  let k = 10
  let block = block_of(k, 16, 0x1111UL)
  let enc_ = build_encoder(block, 0xA5UL)
  let received = encode_n(enc_, k, 2.0, 0)
  inspect(received.length(), content="20")
  let r = decode(0xA5UL, k, 16, received) catch { _ => abort("decode raised") }
  match r {
    Complete(sources) => {
      inspect(sources.length(), content="10")
      for i = 0; i < k; i = i + 1 {
        assert_eq(sources[i], block.sources[i])
      }
    }
    Incomplete(_, _) => abort("expected complete")
  }
}

///|
/// **核心诚实性测试**：失败时必须如实报缺。
///
/// 关键断言不是「失败了」，而是：
/// 1. `missing` 非空且每个下标都在 `[0,K)`
/// 2. `recovered[i] is None` 当且仅当 `i` 在 `missing` 里（两个视图一致）
/// 3. 已解出的那些 `recovered[i]` **逐字节等于真实源符号**
///    —— 这一条排除了「用填充值凑数」：如果实现补了零，这里会对不上。
test "decoder: failure reports honest missing indices and no fabricated bytes" {
  let k = 10
  let block = block_of(k, 8, 0x2222UL)
  let enc_ = build_encoder(block, 0xBEEFUL)
  let received = encode_n(enc_, k, 1.0, 0)
  inspect(received.length(), content="10")
  let r = decode(0xBEEFUL, k, 8, received) catch { _ => abort("decode raised") }
  match r {
    Complete(sources) =>
      // 这条 seed 下恰巧成功：仍然要逐字节核对
      for i = 0; i < k; i = i + 1 {
        assert_eq(sources[i], block.sources[i])
      }
    Incomplete(recovered, missing) => {
      assert_true(missing.length() > 0)
      for m in missing {
        assert_true(m >= 0 && m < k)
      }
      // 两个视图一致：None 的位置集合 == missing（升序）
      let none_positions : Array[Int32] = []
      for i = 0; i < recovered.length(); i = i + 1 {
        if recovered[i] is None {
          none_positions.push(i)
        }
      }
      assert_eq(none_positions, missing)
      // **没有填充值**：已解出的每一字节都必须等于真实源
      for i = 0; i < recovered.length(); i = i + 1 {
        match recovered[i] {
          Some(v) => assert_eq(v, block.sources[i])
          None => ()
        }
      }
    }
  }
}

///|
/// 跨多条 seed 的诚实性断言：**只要**报告 Incomplete，
/// 那么每一个「已解出」的槽位都必须与真实源逐字节相同。
///
/// 这条是「绝不填假数据」的**结构性**证据：它不依赖任何具体成功率，
/// 而是断言「凡声称解出的，必须真的是对的」。
test "decoder: every claimed-recovered slot is byte-true across 200 seeds" {
  let k = 24
  let block = block_of(k, 6, 0x3333UL)
  let mut incomplete_runs = 0
  let mut complete_runs = 0
  let mut lies = 0
  // overhead 1.5 在 K=24 下给出混合结局（实测 133/200 成功）。
  // 用 1.05 时全部失败、用 2.0 时几乎全部成功，两条分支只覆盖一条。
  for s = 0; s < 200; s = s + 1 {
    let seed = s.to_uint64() * 2654435761UL + 7UL
    let enc_ = build_encoder(block, seed)
    let received = encode_n(enc_, k, 1.5, 0)
    let r = decode(seed, k, 6, received) catch { _ => abort("decode raised") }
    match r {
      Complete(sources) => {
        complete_runs = complete_runs + 1
        for i = 0; i < k; i = i + 1 {
          if sources[i] != block.sources[i] {
            lies = lies + 1
          }
        }
      }
      Incomplete(recovered, missing) => {
        incomplete_runs = incomplete_runs + 1
        for i = 0; i < k; i = i + 1 {
          match recovered[i] {
            Some(v) => if v != block.sources[i] { lies = lies + 1 }
            None => ()
          }
        }
        if r.missing_count() != missing.length() {
          lies = lies + 1
        }
      }
    }
  }
  inspect(lies, content="0")
  // 两种结局都应该出现（1.5 开销下确实有成功有失败）；
  // 若某一侧为 0，说明这条测试没有覆盖到两条分支。
  assert_true(complete_runs > 0)
  assert_true(incomplete_runs > 0)
}

///|
test "decoder: missing indices are sorted ascending" {
  let k = 30
  let block = block_of(k, 4, 0x4444UL)
  let enc_ = build_encoder(block, 0x1234UL)
  let received = encode_n(enc_, k, 0.9, 0)
  let r = decode(0x1234UL, k, 4, received) catch { _ => abort("decode raised") }
  match r {
    Complete(_) => abort("overhead 0.9 should not succeed")
    Incomplete(_, missing) =>
      for i = 1; i < missing.length(); i = i + 1 {
        assert_true(missing[i - 1] < missing[i])
      }
  }
}

///|
/// 采样型断言：小 K 下「充裕 overhead」**也不是必然成功**。
///
/// 这是本项目的一个实测结论，不是猜测 —— 下面这张表是用 200 trials
/// （seed 步长 2654435761）跑出来的：
///
/// ```
/// K=10 oh=3.0 → 196/200        K=10 oh=2.0 → 175/200
/// K=17 oh=2.0 → 183/200        K=40 oh=2.0 → 194/200
/// K=64 oh=2.0 → 196/200
/// ```
///
/// 原因不是「overhead 不够」，而是**剥皮需要至少一个度为 1 的符号**：
/// 失败的样本里 `resolved == 0` 占了绝大多数 —— 整组符号里一个度 1 都没有，
/// 剥皮根本无法启动。K 很小时 μ(1) ≈ 0.147，30 个符号全不为 1 的概率是
/// `(1-0.147)^30 ≈ 0.9%`，实测 zero-progress 比例与之相符。
///
/// 因此断言写成「成功率 >= 阈值」，阈值取实测值向下取整。
/// **不做「必然成功」的断言** —— 那会变成一条关于运气的测试。
test "decoder: small K at ample overhead succeeds at the measured rate" {
  for
    _, (k, oh, floor_pct) in [
      (10, 3.0, 0.95),
      (10, 2.0, 0.80),
      (17, 2.0, 0.85),
      (40, 2.0, 0.92),
      (64, 2.0, 0.93),
    ] {
    let trials = 100
    let mut ok = 0
    for s = 0; s < trials; s = s + 1 {
      let seed = s.to_uint64() * 2654435761UL + k.to_uint64()
      let block = block_of(k, 5, seed)
      let enc_ = build_encoder(block, seed)
      let received = encode_n(enc_, k, oh, 0)
      let r = decode(seed, k, 5, received) catch { _ => abort("decode raised") }
      match r {
        Complete(sources) => {
          // 成功时必须逐字节正确 —— 这一条不可让步
          for i = 0; i < k; i = i + 1 {
            if sources[i] != block.sources[i] {
              abort("complete but wrong bytes")
            }
          }
          ok = ok + 1
        }
        Incomplete(recovered, _) =>
          // 失败时也不许编造：已解出的必须为真
          for i = 0; i < k; i = i + 1 {
            match recovered[i] {
              Some(v) =>
                if v != block.sources[i] {
                  abort("incomplete with fabricated bytes")
                }
              None => ()
            }
          }
      }
    }
    let rate = ok.to_double() / trials.to_double()
    if rate < floor_pct {
      println("K=\{k} oh=\{oh}: rate=\{rate} < floor=\{floor_pct}")
    }
    assert_true(rate >= floor_pct)
  }
}

///|
/// **结构性**断言：剥皮卡死的典型形态是「整组符号里一个度 1 都没有」，
/// 此时 `resolved == 0`（不是解出一半）。这条把上面那张表的原因固定下来，
/// 而不是让「失败」变成一个没有解释的黑箱。
test "decoder: no degree-one symbol means zero progress, honestly reported" {
  let k = 10
  let dist = robust_distribution(k, 0.1, 0.5)
  // **不硬编码某个 seed**：遍历一批 seed，取第一个「整组 30 个符号里
  // 一个度 1 都没有」的。这样测试不依赖 seed 派生细节（那可能在修 bug
  // 时合法地改变），而依赖真正的结构性质。
  let mut found_seed = 0UL
  let mut found = false
  for s = 0; s < 400; s = s + 1 {
    let seed = s.to_uint64() * 65537UL + 10UL
    let mut d1 = 0
    for i = 0; i < 30; i = i + 1 {
      if subset_for(seed, i, k, dist).length() == 1 {
        d1 = d1 + 1
      }
    }
    if d1 == 0 && !found {
      found_seed = seed
      found = true
    }
  }
  // 这条前提本身是有概率的：P(30 个都不是度 1) = (1-0.147)^30 ≈ 0.9%，
  // 400 个 seed 里出现至少一个的概率 > 97%。若确实没有，说明分布变了。
  assert_true(found)
  let seed = found_seed
  let block = block_of(k, 5, seed)
  let enc_ = build_encoder(block, seed)
  let received : Array[ReceivedSymbol] = []
  for i = 0; i < 30; i = i + 1 {
    let s = enc_.symbol(i)
    received.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let (res, stats) = decode_with_stats(seed, k, 5, received, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  inspect(stats.resolved, content="0")
  inspect(stats.xor_bytes, content="0")
  match res {
    Complete(_) => abort("no degree-one symbol cannot complete")
    Incomplete(recovered, missing) => {
      assert_eq(missing, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
      for i = 0; i < k; i = i + 1 {
        assert_true(recovered[i] is None)
      }
    }
  }
}

///|
test "decoder: K=1 degenerate always completes with one symbol" {
  let block = block_of(1, 9, 0x7777UL)
  let enc_ = build_encoder(block, 3UL)
  let received = [ReceivedSymbol::{ index: 0, data: enc_.symbol(0).data, }]
  let r = decode(3UL, 1, 9, received) catch { _ => abort("decode raised") }
  match r {
    Complete(sources) => {
      inspect(sources.length(), content="1")
      assert_eq(sources[0], block.sources[0])
    }
    Incomplete(_, _) => abort("K=1 with 1 symbol must complete")
  }
}

///|
test "decoder: empty input reports all K indices missing, no fabrication" {
  let k = 5
  let received : Array[ReceivedSymbol] = []
  let r = decode(0UL, k, 4, received) catch { _ => abort("decode raised") }
  match r {
    Complete(_) => abort("empty input cannot complete")
    Incomplete(recovered, missing) => {
      inspect(recovered.length(), content="5")
      assert_eq(missing, [0, 1, 2, 3, 4])
      // 全部槽位必须是 None，不能是零字节
      for i = 0; i < k; i = i + 1 {
        assert_true(recovered[i] is None)
      }
    }
  }
}

///|
test "decoder: duplicate indices are harmless (rank deficiency, not crash)" {
  let k = 8
  let block = block_of(k, 4, 0x8888UL)
  let enc_ = build_encoder(block, 55UL)
  // 同一个 index 重复 20 次 → 方程全是同一行，必然解不出全部
  let received : Array[ReceivedSymbol] = []
  for i = 0; i < 20; i = i + 1 {
    let s = enc_.symbol(3)
    received.push(ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let r = decode(55UL, k, 4, received) catch { _ => abort("decode raised") }
  match r {
    Complete(_) => abort("duplicate equations must not complete")
    Incomplete(recovered, missing) => {
      assert_true(missing.length() > 0)
      for i = 0; i < k; i = i + 1 {
        match recovered[i] {
          Some(v) => assert_eq(v, block.sources[i])
          None => ()
        }
      }
    }
  }
}

///|
test "decoder: symbol length mismatch is a hard error, not silent" {
  let k = 4
  let received = [
    ReceivedSymbol::{ index: 0, data: b"\x01\x02", },
    ReceivedSymbol::{ index: 1, data: b"\x01\x02\x03", },
  ]
  try {
    let _ = decode(0UL, k, 3, received)
    abort("expected TruncatedSymbol")
  } catch {
    TruncatedSymbol(actual, wanted) => {
      inspect(actual, content="2")
      inspect(wanted, content="3")
    }
    _ => abort("wrong error variant")
  }
}

///|
test "decoder: empty source / oversized K are rejected" {
  try {
    let _ = decode(0UL, 0, 4, [])
    abort("expected EmptySource")
  } catch {
    EmptySource => ()
    _ => abort("wrong variant for K=0")
  }
  try {
    let _ = decode(0UL, max_source_symbols() + 1, 4, [])
    abort("expected SourceTooLarge")
  } catch {
    SourceTooLarge(k, limit) => {
      inspect(k, content="\{max_source_symbols() + 1}")
      inspect(limit, content="\{max_source_symbols()}")
    }
    _ => abort("wrong variant for oversized K")
  }
  try {
    let _ = decode(0UL, 4, 0, [])
    abort("expected EmptySource")
  } catch {
    EmptySource => ()
    _ => abort("wrong variant for symbol_len=0")
  }
}

///|
test "decoder: decode_with_stats reports operation counts" {
  let k = 50
  let block = block_of(k, 7, 0x9999UL)
  let enc_ = build_encoder(block, 77UL)
  let received = encode_n(enc_, k, 2.0, 0)
  let (r, stats) = decode_with_stats(77UL, k, 7, received, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  assert_true(r.is_complete())
  inspect(stats.received, content="100")
  assert_true(stats.resolved == k)
  assert_true(stats.subset_slots > 0)
  assert_true(stats.xor_bytes > 0)
  // 正常输入下不应出现矛盾
  inspect(stats.inconsistent, content="0")
}

///|
/// **复杂度用操作计数断言**：固定 overhead 下，`subset_slots` 与 `xor_bytes`
/// 随 K 近似线性增长，而不是平方。
///
/// 平方实现会让比值随 K 翻倍。比较 K=200 与 K=400：
/// 若线性，比值 ≈ 2；若平方，比值 ≈ 4。断言 < 2.6 足以区分。
/// 用操作计数而不是墙钟 —— CI 上墙钟不稳，且时间无法区分渐进错误与常数因子。
fn count_ops(k : Int32) -> (Int32, Int32) {
  let block = block_of(k, 2, 0xAAAAUL + k.to_uint64())
  let enc_ = build_encoder(block, 5UL)
  let received = encode_n(enc_, k, 2.0, 0)
  let (_, stats) = decode_with_stats(5UL, k, 2, received, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  (stats.subset_slots, stats.xor_bytes)
}

///|
test "decoder: operation counts grow linearly in K, not quadratically" {
  let small = count_ops(200)
  let big = count_ops(400)
  let slots_ratio = big.0.to_double() / small.0.to_double()
  let xor_ratio = big.1.to_double() / small.1.to_double()
  if slots_ratio > 2.6 || xor_ratio > 2.6 {
    println("slots ratio=\{slots_ratio} xor ratio=\{xor_ratio}")
  }
  assert_true(slots_ratio < 2.6)
  assert_true(xor_ratio < 2.6)
}
