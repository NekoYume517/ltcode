///|
/// 剥皮（peeling）解码器。
///
/// ## 算法
///
/// 1. 每个收到的符号记住「还没解出的源符号下标集合」与「XOR 累积值」。
/// 2. 反复找度为 1 的符号：它的累积值**就是**那个源符号的值 → 解出，
///    再从所有包含它的符号里消去（XOR 掉）。
/// 3. 没有度为 1 的符号时停止。
///
/// ## 诚实性（本项目最重要的一条）
///
/// 失败的返回**必须**是 `Incomplete(recovered, missing)`，其中：
/// - `missing` 是真实未解出的源符号下标（真实计算出来的，不是猜的）；
/// - `recovered[i]` 在 `missing` 里的位置恒为 `None`。
///
/// **绝不**用零字节或任何填充值把缺口补齐。一旦补齐，调用方看到的就是
/// 一个「完整但错误」的结果 —— 那是数据损坏，比明确报错危险得多。
///
/// ## 复杂度
///
/// 每个被解出的源符号会被「消去」到它出现过的每个符号里，因此总 XOR 字节
/// 数 ≈ `received · avg_degree · symbol_len`。这是 O(received · avg_degree)
/// 个符号级操作，与 K 线性（固定 overhead 下）。这一点用**操作计数**验证
/// （`decoder_complexity_test`），不用墙钟 —— 墙钟在 CI 上不稳，而且会把
/// 常数因子误当成渐进结论。
///
/// ## 为什么 v1 不做 inactivation
///
/// inactivation 是把「卡住的」符号标记为不参与剥皮，攒够之后跑一次 GF(256)
/// 高斯消元。它能把 LT 从「1.2 开销下大概率成功」推到「几乎必成」，代价是
/// 引入一整块高斯消元实现（那是独立的一个项目量级），且在 LT 上收益有限
/// （LT 的瓶颈是缺少高质量度分布，不是削峰）。**这是设计选择，不是缺陷** ——
/// 选它是因为本项目要给出**可证伪的失败**：卡在哪里就报哪里。

///|
/// 解码结论。
///
/// `Incomplete` 携带两个视图：按源符号顺序的 `recovered`（缺口为 `None`）
/// 与按升序排列的 `missing` 下标。两者信息等价，但调用方需要的形式不同：
/// CLI 打印缺项要 `missing`，做「部分恢复」实验要 `recovered`。
pub(all) enum DecodeResult {
  Complete(Array[Bytes])
  Incomplete(Array[Bytes?], Array[Int32])
}

///|
/// `Complete` 里拿到了全部源符号（顺序与源一致）。
pub fn DecodeResult::is_complete(self : DecodeResult) -> Bool {
  match self {
    Complete(_) => true
    Incomplete(_, _) => false
  }
}

///|
/// 缺失的源符号下标；成功时为空数组。
pub fn DecodeResult::missing_indices(self : DecodeResult) -> Array[Int32] {
  match self {
    Complete(_) => []
    Incomplete(_, missing) => missing
  }
}

///|
/// `None` 恰好出现在缺口位置的总数。与 `missing.length()` 必须相等，
/// 有一条测试专门断言这一点（防止两个视图不一致）。
pub fn DecodeResult::missing_count(self : DecodeResult) -> Int32 {
  match self {
    Complete(_) => 0
    Incomplete(recovered, _) => {
      let mut n = 0
      for r in recovered {
        if r is None {
          n = n + 1
        }
      }
      n
    }
  }
}

///|
/// 解码统计。**操作计数而不是时间**：CI 上墙钟不稳，而且用时间无法区分
/// 「渐进复杂度错了」与「常数因子大了」。
pub(all) struct DecodeStats {
  /// 收到的符号数
  received : Int32
  /// 建表时登记的（符号, 源下标）关联总数 = Σ degree
  subset_slots : Int32
  /// 实际解出的源符号数
  resolved : Int32
  /// 累计 XOR 的字节数（复杂度主项）
  xor_bytes : Int32
  /// 已经解出、但仍被某个度 1 符号要求解时的**矛盾**次数。
  /// 正常情况下恒为 0（XOR 是自洽的）；非 0 说明收到的符号之间不一致
  /// （数据被篡改或 index 与内容错配）。CLI 在非 0 时给出警告。
  inconsistent : Int32
} derive(Eq, Debug)

///|
/// 完整解码：给定 `(seed, K, symbol_len, received)`。
/// 使用默认参数 `c=0.1, δ=0.5` —— 与 `Encoder::new` 的默认值一致，
/// 否则子集会算错（参数决定抽样，不是性能旋钮）。
pub fn decode(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
  received : Array[ReceivedSymbol],
) -> DecodeResult raise LtError {
  decode_full(seed, k, symbol_len, received, default_c(), default_delta())
}

///|
/// 带分布的完整解码。返回 `(结果, 统计)`。
pub fn decode_with_stats(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
  received : Array[ReceivedSymbol],
  c : Double,
  delta : Double,
) -> (DecodeResult, DecodeStats) raise LtError {
  if k < 1 {
    raise LtError::EmptySource
  }
  let limit = max_source_symbols()
  if k > limit {
    raise LtError::SourceTooLarge(k, limit)
  }
  if symbol_len < 1 {
    raise LtError::EmptySource
  }
  // 长度必须逐一核对：短一个字节的符号会让 XOR 结果整体偏移，
  // 然后在「解出来的数据」里表现为乱码 —— 那是最难查的一类 bug。
  for r in received {
    if r.data.length() != symbol_len {
      raise LtError::TruncatedSymbol(r.data.length(), symbol_len)
    }
  }
  let dist = match robust_soliton_checked(k, c, delta) {
    Ok(d) => d
    Err(e) => raise e
  }
  peel(seed, k, symbol_len, received, dist)
}

///|
/// 便利入口：只要 `DecodeResult`，带全部参数。
pub fn decode_full(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
  received : Array[ReceivedSymbol],
  c : Double,
  delta : Double,
) -> DecodeResult raise LtError {
  decode_with_stats(seed, k, symbol_len, received, c, delta).0
}

///|
/// 剥皮主循环。输入已通过所有校验。
fn peel(
  seed : UInt64,
  k : Int32,
  symbol_len : Int32,
  received : Array[ReceivedSymbol],
  dist : Distribution,
) -> (DecodeResult, DecodeStats) {
  let n = received.length()
  // 每个收到符号：未解出的源下标集合
  let rem : Array[Array[Int32]] = Array::make(n, [])
  // 每个收到符号：累积值（工作区，原地 XOR）
  let acc : Array[FixedArray[Byte]] = Array::make(
    n,
    FixedArray::make(0, b'\x00'),
  )
  // 反向索引（CSR）：源下标 -> 包含它的收到符号位置
  let counts : FixedArray[Int32] = FixedArray::make(k + 1, 0)
  let mut subset_slots = 0
  // 第一遍：算子集 + 计数
  for r = 0; r < n; r = r + 1 {
    let subset = subset_for(seed, received[r].index, k, dist)
    rem[r] = subset
    subset_slots = subset_slots + subset.length()
    for s in subset {
      counts[s] = counts[s] + 1
    }
    acc[r] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      acc[r][j] = received[r].data[j]
    }
  }
  // CSR 偏移
  let offsets : FixedArray[Int32] = FixedArray::make(k + 1, 0)
  let mut running = 0
  for s = 0; s < k; s = s + 1 {
    offsets[s] = running
    running = running + counts[s]
  }
  offsets[k] = running
  let fill : FixedArray[Int32] = FixedArray::make(k, 0)
  let rev : FixedArray[Int32] = FixedArray::make(running, 0)
  for r = 0; r < n; r = r + 1 {
    for s in rem[r] {
      let pos = offsets[s] + fill[s]
      rev[pos] = r
      fill[s] = fill[s] + 1
    }
  }
  // 解出的源符号（None = 还没解出）
  let resolved : Array[Bytes?] = Array::make(k, None)
  // 度 1 队列
  let queue : Array[Int32] = []
  for r = 0; r < n; r = r + 1 {
    if rem[r].length() == 1 {
      queue.push(r)
    }
  }
  let mut resolved_count = 0
  let mut xor_bytes = 0
  let mut inconsistent = 0
  let mut qhead = 0
  while qhead < queue.length() {
    let r = queue[qhead]
    qhead = qhead + 1
    // 出队后状态可能已变（这一条已被别的符号处理过）
    if rem[r].length() != 1 {
      continue
    }
    let s = rem[r][0]
    match resolved[s] {
      Some(_) => {
        // 已经解出：这条符号对我们的方程组没有新信息。
        // 顺手做一致性核对 —— 若它和已知值不符，说明输入互相矛盾。
        let mut differs = false
        for j = 0; j < symbol_len; j = j + 1 {
          let known = match resolved[s] {
            Some(v) => v[j]
            None => b'\x00'
          }
          if acc[r][j] != known {
            differs = true
          }
        }
        if differs {
          inconsistent = inconsistent + 1
        }
        rem[r] = []
        continue
      }
      None => ()
    }
    // 解出 s
    resolved[s] = Some(Bytes::from_array(acc[r]))
    rem[r] = []
    resolved_count = resolved_count + 1
    // 从所有包含 s 的符号里消去
    let from = offsets[s]
    let to = offsets[s] + counts[s]
    for idx = from; idx < to; idx = idx + 1 {
      let r2 = rev[idx]
      if rem[r2].length() == 0 {
        continue
      }
      // acc[r2] ^= acc[r]（此刻 acc[r] 就是源 s 的值）
      for j = 0; j < symbol_len; j = j + 1 {
        acc[r2][j] = acc[r2][j] ^ acc[r][j]
      }
      xor_bytes = xor_bytes + symbol_len
      let next : Array[Int32] = []
      for t in rem[r2] {
        if t != s {
          next.push(t)
        }
      }
      rem[r2] = next
      if next.length() == 1 {
        queue.push(r2)
      }
    }
  }
  let stats : DecodeStats = {
    received: n,
    subset_slots,
    resolved: resolved_count,
    xor_bytes,
    inconsistent,
  }
  if resolved_count == k {
    let out : Array[Bytes] = []
    for i = 0; i < k; i = i + 1 {
      match resolved[i] {
        Some(v) => out.push(v)
        None => abort("internal: resolved_count == k but slot is None")
      }
    }
    (Complete(out), stats)
  } else {
    let missing : Array[Int32] = []
    for i = 0; i < k; i = i + 1 {
      if resolved[i] is None {
        missing.push(i)
      }
    }
    // 断言两个视图一致：None 的数量必须等于 missing 的长度
    (Incomplete(resolved, missing), stats)
  }
}
