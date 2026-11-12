// ============================================================================
// LT1（2026-11-12 followup）：`encode` 末尾的可解性验算
//
// ## 缺陷形态（修复前，真实输出）
//
// `encode` 的默认 `--count` 是 `ceil(1.5K)+1`，这个倍数对小 K **不保证**可解：
// 剥皮需要的度 1 符号数由 `ln(K/δ)·√K` 决定，与 K 不成正比。于是同一份输入、
// 同一个默认 count，只换个种子就解不出来 —— 而 `encode` 一声不吭：
//
//   $ ltcode encode --input examples/payload.bin --symbols 10 --seed 3
//   encoded 4000 bytes -> K=10 symbol_len=400 symbols=16 seed=3
//   out: k10.ltc (6507 bytes)                              ← exit 0，无任何提示
//   $ ltcode decode --input k10.ltc
//   decode INCOMPLETE: need more symbols (missing 6 of 10 source symbols)
//   missing indices: 1,2,5,6,7,8                            ← exit 1
//
// 用户拿到的是一份「encode 成功、decode 必然失败」的容器，且没有任何线索
// 说明是参数问题还是实现问题。默认种子下 K=10 恰好能解（所以只看文档里那条
// 命令永远发现不了这件事）：
//
//   $ ltcode encode --input examples/payload.bin --symbols 10   # 默认 seed
//   ... symbols=16 ...
//   $ ltcode decode --input payload.bin.ltc
//   decoded OK: K=10 ... (checksum verified)                ← 能解
//
// ## 修法（这一轮）
//
// `encode` 末尾用**同一个解码器**（`@lib.decode_full`，不新写剥皮）试解一次：
// 解不出就打印一行 note，说清「缺几个 / 当前 count / 该怎么办」。容器本身
// 完全合法，因此**退出码不变**（仍 0）—— 这一行是提示，不是错误。
//
// ## 为什么是 best-effort
//
// 验算 = 再解一遍，成本与编码同量级（同一个 `count × 平均度数 × symbol_len`
// XOR 量）。因此只在 `count <= LT_VERIFY_MAX_COUNT` 时做；超阈值跳过并且
// **什么都不打印**。边界写进 help 与 README：没打印 ≠ 已验证可解。
// ============================================================================

///|
/// 一个 1 字节全零符号。只用于构造「子集结构」，不关心数值 ——
/// 剥皮的成败只由 `(seed, index, K)` 决定的子集决定，与符号内容无关。
fn zero_symbol(index : Int32, len : Int32) -> @lib.Symbol {
  @lib.Symbol::{
    index,
    data: Bytes::from_array(FixedArray::make(len, b'\x00')),
  }
}

///|
/// 用**真的编码器**生成 `count` 个符号（与 `cmd_encode` 走同一条路径：
/// `SourceBlock::new` → `Encoder::new` → `Encoder::symbols`）。
fn encoded_symbols(
  k : Int32,
  count : Int32,
  seed : UInt64,
  symbol_len : Int32,
) -> Array[@lib.Symbol] {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let raw : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      raw[j] = (i * 31 + j).to_byte()
    }
    sources.push(Bytes::from_array(raw))
  }
  let block = match @lib.SourceBlock::new(sources) {
    Ok(b) => b
    Err(_) => abort("block build failed")
  }
  let enc = match
    @lib.Encoder::new(block, seed, @lib.default_c(), @lib.default_delta()) {
    Ok(e) => e
    Err(_) => abort("encoder build failed")
  }
  enc.symbols(0, count)
}

///|
/// 用例 1（核心）：`K=10, count=16, seed=3` 是真的解不出来 —— 验算必须说出来，
/// 而且要逐个字段对上（缺 6 个 / 当前 16 个 / K=10 / 下一步）。
///
/// `missing = 6` 不是猜的：`decode` 对该容器实测输出
/// `missing 6 of 10 source symbols`、缺项下标 `1,2,5,6,7,8`。
test "LT1: an unpeelable symbol set produces the note (K=10, count=16, seed=3)" {
  let symbols = encoded_symbols(10, 16, 3UL, 8)
  inspect(symbols.length(), content="16")
  let note = verify_solvability(3UL, 10, 8, symbols)
  inspect(
    note,
    content="note: these 16 symbols cannot recover all 10 source symbols (6 missing); decode will report INCOMPLETE - raise --count (the default is ceil(1.5K)+1)",
  )
  // 同一批符号用库里的解码器直接看，结论必须一致（避免验算函数自成一套口径）
  let received : Array[@lib.ReceivedSymbol] = []
  for s in symbols {
    received.push(@lib.ReceivedSymbol::{ index: s.index, data: s.data, })
  }
  let result = @lib.decode_full(
    3UL,
    10,
    8,
    received,
    @lib.default_c(),
    @lib.default_delta(),
  ) catch {
    _ => abort("decode_full raised")
  }
  match result {
    @lib.Complete(_) =>
      abort("expected Incomplete for seed 3 / K=10 / 16 symbols")
    @lib.Incomplete(_, missing) => inspect(missing.length(), content="6")
  }
}

///|
/// 用例 2：同一个 K、同一个种子，只要 `count` 够（40 ≥ 4×K），必须**一个字都不打印**
/// —— 修复前后的 stdout 逐字相同。
test "LT1: a solvable symbol set stays silent (K=10, count=40, seed=3)" {
  let symbols = encoded_symbols(10, 40, 3UL, 8)
  inspect(symbols.length(), content="40")
  inspect(verify_solvability(3UL, 10, 8, symbols), content="")
}

///|
/// 用例 3：`K=4, count=16`（4× 于 K）能解，因此不打印。
///
/// 这一条同时是「验算不是恒真」的对照：会话 1 里同一份 payload、同一个
/// `count=16` 在 K=10 上是解不出的。
test "LT1: K=4 with 16 symbols is solvable and prints nothing" {
  let symbols = encoded_symbols(4, 16, @lib.default_seed(), 8)
  inspect(verify_solvability(@lib.default_seed(), 4, 8, symbols), content="")
}

///|
/// 用例 4：阈值本身。`count > LT_VERIFY_MAX_COUNT` 不验算 —— 用**行为**证明
/// 「根本没跑」，而不是「跑了但没话可说」：
///
/// 4097 个 `index = 0` 的符号喂给 `K=1000`，如果真跑剥皮必然只剩度 1 的那一个
/// 源符号（或直接卡住），note 非空；返回空串只能是因为闸门先拦住了。
/// 紧随其后的对照组用**同一批符号的 16 个**（在闸门内），必须非空 ——
/// 否则上面那句空串断言就是恒真的。
test "LT1: over the gate the verification does not run at all" {
  assert_true(should_verify_solvability(1))
  assert_true(should_verify_solvability(16))
  assert_true(should_verify_solvability(LT_VERIFY_MAX_COUNT))
  assert_false(should_verify_solvability(LT_VERIFY_MAX_COUNT + 1))
  assert_false(should_verify_solvability(0))
  assert_false(should_verify_solvability(-1))
  // K=4000 的默认 count 是 6001，正好越过门槛（`ceil(1.5·4000)+1`）
  inspect(default_count(4000), content="6001")
  assert_false(should_verify_solvability(default_count(4000)))
  // K=2730 是「默认 count 仍落在闸门内」的最后一个 K（2731 就 4098 了）
  inspect(default_count(2730), content="4096")
  assert_true(should_verify_solvability(default_count(2730)))
  inspect(default_count(2731), content="4098")
  assert_false(should_verify_solvability(default_count(2731)))

  let over : Array[@lib.Symbol] = []
  for i = 0; i < LT_VERIFY_MAX_COUNT + 1; i = i + 1 {
    over.push(zero_symbol(0, 1))
  }
  inspect(verify_solvability(7UL, 1000, 1, over), content="")
  // 对照组：同样的符号，数量在闸门内 → 必然解不出 → note 非空
  let inside : Array[@lib.Symbol] = []
  for i = 0; i < 16; i = i + 1 {
    inside.push(zero_symbol(0, 1))
  }
  assert_true(!verify_solvability(7UL, 1000, 1, inside).is_empty())
}

///|
/// 用例 5：`--count 0` 的既有 note 优先，两条提示不会同时出现。
///
/// 结构上是 `cmd_encode` 里的 `if !note.is_empty() { ... } else if should_verify...`，
/// 这里锁定它的两个前提 + 两条文案可区分。
test "LT1: --count 0 keeps exactly its own note" {
  assert_false(should_verify_solvability(0))
  assert_eq(encode_note(0), symbol_free_note())
  let new_note = solvability_note(10, 16, 6)
  assert_true(new_note != symbol_free_note())
  // 新 note 不能说成「零符号容器」那件事，反之亦然
  assert_true(!new_note.contains("symbol-free"))
  assert_true(!symbol_free_note().contains("cannot recover"))
}

///|
/// 文案字段：缺几个、当前 count、K、默认值来源、下一步。成功时一律空串。
test "LT1: the note carries the shortfall, the count, K and the fix" {
  let note = solvability_note(10, 16, 6)
  assert_true(note.has_prefix("note: "))
  assert_true(note.contains("6 missing"))
  assert_true(note.contains("16 symbols"))
  assert_true(note.contains("10 source symbols"))
  assert_true(note.contains("--count"))
  assert_true(note.contains("1.5")) // 默认值来源，用户才能对上 README
  assert_true(note.contains("INCOMPLETE")) // 与 decode 的真实措辞对上
  // 单行：多行会被脚本当成第二条输出
  assert_true(!note.contains("\n"))
  // missing <= 0 一律什么都不说（成功路径逐字不变）
  assert_eq(solvability_note(10, 40, 0), "")
  assert_eq(solvability_note(4, 16, -1), "")
}
