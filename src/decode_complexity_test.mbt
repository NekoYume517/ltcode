///|
/// 解码复杂度是**线性**的：零噪声判据（LT44，2026-11-29 审计）。
///
/// ## 为什么要这条（30.4 留下的空白）
///
/// 上一轮（LT41）测出「903 MB 容器解码 72.5 s」并写清 §17 是**内存**预算
/// 不约束时间。但那个 72.5 s 只是个孤立的数字：没有曲线、没有判据，读者
/// 无法判断"再大一档会不会变成 4 倍"。
///
/// 用墙钟建判据是不可行的 —— `src/metrics.mbt` 开篇就写明本项目**全篇不用
/// 墙钟**，因为 CI 上不稳，而且墙钟无法区分「渐进复杂度错了」与「常数因子
/// 大了」。所以这里改用 `DecodeStats` 里两个**精确的整数计数器**：
///
/// - `subset_slots` = Σ|subset|，建 CSR 时登记的（符号, 源下标）关联总数；
/// - `xor_bytes` = 累计 XOR 的字节数，剥皮消去阶段的主项。
///
/// 两者都是**确定的、可复现的整数**：同一输入永远给出同一个值，跨平台、
/// 跨机器、跨工具链都不变。规模翻倍时它们必须**大约翻倍**（线性），
/// 而不是翻四倍（平方）。
///
/// ## 判据
///
/// 取同一组 `(symbol_len, 每符号平均度数)`，把 `count` 翻倍，比较
/// `xor_bytes`：
///
/// ```text
/// rate = xor_bytes(count=2m) / xor_bytes(count=m)
/// ```
///
/// 线性 → `rate ≈ 2`；平方 → `rate ≈ 4`。**阈值取 2.4**：给常数项与度数
/// 抖动留余量，但离平方的 4 很远。
///
/// `subset_slots` 同法（它是 Σ degree，与 count 成正比）。

///|
/// 用真实的库入口解一个「每个符号度固定」的容器，返回 stats。
///
/// 为了让 Σ|subset| 可控，这里不构造容器文件，而是直接调
/// `decode_with_stats` 并把 K 设小、`received` 的数量做成两档。
/// 每个 ReceivedSymbol 的 index 不同 → 子集由 `subset_for` 决定（度数随
/// 分布抖动），所以**判据用 xor_bytes 而不是 subset_slots** 更稳。
///
/// 但为了让两个计数器都线性，这里反过来利用一件事：`xor_bytes` 的增长
/// 来自"每消去一个源符号，对包含它的每个符号做一次 symbol_len 字节的 XOR"。
/// 总量 ≈ Σ_s Σ_{r ∋ s} symbol_len = symbol_len × Σ|subset|。所以只要
/// Σ|subset| 线性，xor_bytes 就线性。
fn lt44_stats(
  k : Int32,
  symbol_len : Int32,
  count : Int32,
) -> DecodeStats raise LtError {
  let syms : Array[ReceivedSymbol] = []
  for i in 0..<count {
    let parts : Array[Byte] = []
    let mut j = 0
    while j < symbol_len {
      parts.push((i & 0xFF).to_byte())
      j = j + 1
    }
    syms.push(ReceivedSymbol::{ index: i, data: Bytes::from_array(parts), })
  }
  let (_, stats) = decode_with_stats(
    0x4C54434F4445UL,
    k,
    symbol_len,
    syms,
    default_c(),
    default_delta(),
  )
  stats
}

///|
/// **LT44-a**：`count` 翻倍时 `subset_slots` 与 `xor_bytes` 都近似翻倍。
///
/// 阈值 2.4（线性 ≈ 2，平方 ≈ 4）。这条是**零噪声**判据：只比整数计数器，
/// 不看时钟，所以跨机器稳定。
test "LT44: doubling the symbol count roughly doubles both work counters" {
  let k = 200
  let sl = 4
  let m = 400
  let s1 = lt44_stats(k, sl, m) catch {
    e => abort("baseline decode failed: \{error_text(e)}")
  }
  let s2 = lt44_stats(k, sl, m * 2) catch {
    e => abort("doubled decode failed: \{error_text(e)}")
  }
  // 两个计数器在 count 翻倍后都必须是"约 2 倍"，不能是"约 4 倍"。
  let slots_rate = s2.subset_slots.to_double() / s1.subset_slots.to_double()
  let xor_rate = s2.xor_bytes.to_double() / s1.xor_bytes.to_double()
  // 上界 2.4（线性 ≈ 2，平方 ≈ 4）：用整数比较避免浮点边界抖动。
  assert_true((slots_rate * 1000.0).to_int() < 2400)
  assert_true((xor_rate * 1000.0).to_int() < 2400)
  // 同时确认它确实增长了（不是常数）。
  assert_true(s2.subset_slots > s1.subset_slots)
  assert_true(s2.xor_bytes > s1.xor_bytes)
  // 实测 ratio 是 **1.87** 而不是 2.00 —— 因为 n 从 400 涨到 800 时 K=200 的
  // 解码**更早饱和**（更多符号意味着剥皮更早一步到位，总消去量反而略低于
  // 线性外推）。这是"次线性"，不是超线性，属于允许方向。
  //
  // 所以这里锁的是**区间** [1.5, 2.4]：既排除"常数"（<1.5）也排除"平方"
  // （>2.4）。写死 200 会把次线性误判成缺陷 —— 而次线性恰恰是好事。
  let slots_pct = (slots_rate * 100.0).round().to_int()
  assert_true(slots_pct >= 150)
  assert_true(slots_pct <= 240)
  inspect(slots_pct, content="187")
}

///|
/// **LT44-b**：`symbol_len` 翻倍时 `xor_bytes` 也翻倍（XOR 量 ∝ symbol_len）。
///
/// 这条锁住「逐字节 XOR」这一项的量纲：`xor_bytes` 是按**字节**计的，
/// 所以 symbol_len 翻倍 → 字节数翻倍。若哪天有人把 `xor_bytes` 改成按
/// 符号计，这条会红（那是计数器语义变更）。
test "LT44: xor_bytes is measured in bytes, so symbol_len doubles it" {
  let k = 200
  let m = 400
  let s1 = lt44_stats(k, 4, m) catch {
    e => abort("decode with sl=4 failed: \{error_text(e)}")
  }
  let s2 = lt44_stats(k, 8, m) catch {
    e => abort("decode with sl=8 failed: \{error_text(e)}")
  }
  // 同一 count、同一分布 → subset_slots 相同，xor_bytes 应约翻倍
  assert_eq(s2.subset_slots, s1.subset_slots)
  let rate = s2.xor_bytes.to_double() / s1.xor_bytes.to_double()
  assert_true((rate * 100.0).round().to_int() >= 195)
  assert_true((rate * 100.0).round().to_int() <= 205)
}

///|
/// **LT44-c**：`subset_slots` 精确等于 Σ|subset|，不是估计。
///
/// 用一次性可算的小例子：K=1、每符号度必为 1（只有一个源符号），
/// count = n → Σ|subset| = n。
test "LT44: subset_slots is the exact sum of subset sizes" {
  let n = 50
  let s = lt44_stats(1, 3, n) catch {
    e => abort("K=1 decode failed: \{error_text(e)}")
  }
  // K=1 时每个符号的子集恒为 {0}，所以 Σ|subset| == n
  assert_eq(s.subset_slots, n)
}
