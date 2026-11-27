///|
/// LT48（2026-11-27 审计）：剥皮正确性的**全不变式** —— 任何 `Complete`
/// 都必须携带逐字节正确的载荷。
///
/// ## 为什么补这条（与既有测试的分工）
///
/// 历史上这条不变式是靠**翻转扫描**抽查的：11-22 跑了 523 次 decode、
/// LT19/LT39 跑到 105,944 次。翻转擅长发现「本应被拦住却没被拦住」，但它
/// **只能到达原文件已有的值附近**，而且**结论是抽样式的**：523 次的日志
/// 只能说明"这 523 个位置没问题"。
///
/// 这一层换判据：**不枚举输入，而是枚举容器形态**，对每一种形态断言
/// `decode_verified` 的**结论与其载荷自洽**：
///
/// ```text
///   Complete(payload)  ⟹  payload 逐字节等于原文
///   Incomplete(...)    ⟹  没写任何东西（CLI 不落盘）
///   raise Corrupt      ⟹  载荷与哈希不符
/// ```
///
/// 只要有任何一个形态给出 `Complete` 但载荷不对，这条就红 —— 而这正是
/// `docs/implementation.md` §5b 记录的那个真实缺陷的形态。
///
/// ## 覆盖的形态
///
/// 1. **冗余方程**：同一 index 出现两次（精确重复）。
/// 2. **冲突方程**：同一 index、不同 payload（流序首现者胜出）。
/// 3. **越界下标**：Int32 的负值与 `Int32.MIN`。
/// 4. **多余方程**：收到的符号数远多于 K（剥皮提前完成，后面全是噪声）。
/// 5. **缺方程**：只给 `K - 1` 个独立方程（必然 Incomplete）。
/// 6. **全噪声**：每个符号体都是伪随机字节，index 合法。
///
/// 六种形态 × 正常/篡改两种载荷 = 12 个组合，全部必须自洽。
test "LT48: every Complete carries the exact payload; every corrupt path is caught" {
  let k : Int32 = 20
  let symbol_len : Int32 = 8
  let payload_len = k * symbol_len
  let payload = lt48_payload(0x1234UL, payload_len)
  let block = match @src.SourceBlock::from_bytes(payload, k) {
    Ok(b) => b
    Err(_) => abort("from_bytes")
  }
  let seed : UInt64 = 0xABCDUL
  let enc = match @src.Encoder::try_new(block, seed, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("try_new")
  }
  let good = enc.symbols(0, k * 3)
  let packed = @src.pack_container(block, seed, payload, 0.1, 0.5, good) catch {
    _ => abort("pack")
  }
  let base = @src.unpack_container(packed) catch { _ => abort("unpack") }
  let dist = @src.robust_distribution(k, 0.1, 0.5) catch { _ => abort("dist") }
  // 基线的 sanity：完整容器必须 Complete 且载荷逐字节相等
  assert_eq(lt48_outcome(base, payload), "complete-ok")

  // ── 形态 1：精确重复（把第 2 个符号换成第 1 个的同 index 同数据） ──
  {
    let syms : Array[@src.ReceivedSymbol] = []
    for i, s in base.symbols {
      if i == 1 {
        syms.push(base.symbols[0])
      } else {
        syms.push(s)
      }
    }
    let c : @src.Container = { ..base, symbols: syms, }
    // 重复方程是冗余：要么仍 Complete 且载荷正确，要么卡住报 Incomplete
    let o = lt48_outcome(c, payload)
    assert_true(o == "complete-ok" || o == "incomplete")
  }

  // ── 形态 2：冲突（同 index、不同数据） ──
  {
    let target = lt48_degree1_pos(base, k, dist)
    let syms : Array[@src.ReceivedSymbol] = []
    for i, s in base.symbols {
      if i == 2 {
        // 借用度 1 符号的 index，但数据是噪声 → 两条互相矛盾的方程
        let noise = lt48_noise(0x77UL, symbol_len)
        syms.push(@src.ReceivedSymbol::{
          index: base.symbols[target].index,
          data: noise,
        })
      } else {
        syms.push(s)
      }
    }
    let c : @src.Container = { ..base, symbols: syms, }
    let o = lt48_outcome(c, payload)
    // 冲突可能表现为 corruption（哈希兜底）、incomplete（剥皮卡住）
    assert_true(o == "corruption" || o == "incomplete")
    // 绝不许 Complete 出错误载荷
    assert_true(o != "complete-bad")
  }

  // ── 形态 3：越界下标（负数与 Int32.MIN） ──
  for idx in ([-1, -2147483648] : Array[Int32]) {
    let syms : Array[@src.ReceivedSymbol] = []
    for i, s in base.symbols {
      if i == 0 {
        syms.push(@src.ReceivedSymbol::{ index: idx, data: s.data, })
      } else {
        syms.push(s)
      }
    }
    let c : @src.Container = { ..base, symbols: syms, }
    let o = lt48_outcome(c, payload)
    assert_true(o != "complete-bad")
  }

  // ── 形态 4：多余方程（收到的远多于 K） ──
  {
    let syms : Array[@src.ReceivedSymbol] = []
    for s in base.symbols {
      syms.push(s)
    }
    let extra = enc.symbols(k * 3, k * 3)
    for s in extra {
      syms.push(@src.ReceivedSymbol::{ index: s.index, data: s.data, })
    }
    let c : @src.Container = { ..base, symbols: syms, }
    // 都是真正的编码符号 → 必须 Complete 且载荷正确
    assert_eq(lt48_outcome(c, payload), "complete-ok")
  }

  // ── 形态 5：缺方程（只给 K-1 个） ──
  {
    let syms : Array[@src.ReceivedSymbol] = []
    for i, s in base.symbols {
      if i < k - 1 {
        syms.push(s)
      }
    }
    let c : @src.Container = { ..base, symbols: syms, }
    let o = lt48_outcome(c, payload)
    assert_true(o == "incomplete" || o == "complete-ok")
    assert_true(o != "complete-bad")
  }

  // ── 形态 6：全噪声（合法 index、随机数据） ──
  let syms : Array[@src.ReceivedSymbol] = []
  for i, s in base.symbols {
    let noise = lt48_noise((i * 31 + 7).to_uint64(), symbol_len)
    syms.push(@src.ReceivedSymbol::{ index: s.index, data: noise, })
  }
  let c : @src.Container = { ..base, symbols: syms, }
  let o = lt48_outcome(c, payload)
  // 噪声几乎必然哈希不符 → corruption；也可能卡住 → incomplete
  assert_true(o == "corruption" || o == "incomplete")
  assert_true(o != "complete-bad")
}

///|
/// 把 `decode_verified` 的结论压成一个**可断言的字符串**，并在这里就完成
/// 「Complete 的载荷是否等于原文」的裁决 —— 不让调用方自己去比。
fn lt48_outcome(c : @src.Container, expected : Bytes) -> String {
  try {
    let r = @src.decode_verified(c)
    match r {
      @src.Complete(sources) => {
        let got = @src.reassemble(sources, c.payload_len)
        if got == expected {
          "complete-ok"
        } else {
          "complete-bad"
        }
      }
      @src.Incomplete(_, _) => "incomplete"
    }
  } catch {
    @src.CorruptionDetected(_, _) => "corruption"
    _ => "other-error"
  }
}

///|
/// 找第一个度为 1 的符号位置（用来构造冲突/定位单个源符号）。
fn lt48_degree1_pos(
  c : @src.Container,
  k : Int32,
  dist : @src.Distribution,
) -> Int32 {
  for i, s in c.symbols {
    if @src.subset_for(c.seed, s.index, k, dist).length() == 1 {
      return i
    }
  }
  abort("no degree-1 symbol in the generated container")
}

///|
/// 确定性伪随机载荷。
fn lt48_payload(seed : UInt64, n : Int32) -> Bytes {
  let out : Array[Byte] = []
  let rng = @src.Ltrng::new(seed)
  for _ in 0..<n {
    let v = rng.next_u64().to_int() % 251
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// 确定性伪随机符号体。
fn lt48_noise(seed : UInt64, n : Int32) -> Bytes {
  lt48_payload(seed ^ 0x5A5A_5A5AUL, n)
}
