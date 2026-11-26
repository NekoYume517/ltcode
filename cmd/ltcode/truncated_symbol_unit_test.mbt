///|
/// `TruncatedSymbol` 的**单位歧义**回归锁（LT42，2026-11-28 审计）。
///
/// ## 现象
///
/// `error_text(TruncatedSymbol(a, b))` 一律渲染成
///
/// ```text
/// truncated symbol: got {a} bytes, expected {b}
/// ```
///
/// 但 `TruncatedSymbol` 的**两个字段在不同调用点有不同的量纲**：
///
/// | 调用点 | 第一个字段 | 第二个字段 | 实际量纲 |
/// |---|---|---|---|
/// | `Reader::u32_unsigned` / `u32` | `remaining` | `4` | **字节 / 字节** |
/// | `Reader::u64` | `remaining` | `8` | **字节 / 字节** |
/// | `Reader::byte` | `remaining` | `1` | **字节 / 字节** |
/// | `Reader::bytes` | `remaining` | `n` | **字节 / 字节** |
/// | `unpack_container`（头不足） | `data.length()` | `header_len()` | **字节 / 字节** |
/// | `decode_with_stats`（符号体短） | `data.length()` | `symbol_len` | **字节 / 字节** |
/// | **`unpack_container`（count 装不下）** | **`count_max`** | **`count_raw`** | **符号条数 / 符号条数** |
///
/// 最后一行就是缺陷：它报的是「文件够读 3 个符号、头部说要 4 个」，
/// 渲染成 `got 3 bytes, expected 4` 之后，读的人会以为单位是字节 ——
/// 而 `expected 4` 若真是字节，和 `symbol_len`（每符号字节数）放在同一句话里
/// 就更乱了。**两个不同量纲的数被并排写成同一单位**，用户会算错"还差多少"。
///
/// ## 这条锁什么
///
/// 1. **符号条数分支必须自带单位**：文案里必须出现 `symbol` 这个词，
///    不能只说 `bytes`。
/// 2. **字节分支仍然说 bytes**：不能为了修一个分支把另一个分支改坏。
/// 3. **`got` / `expected` 两个子串必须保留** —— `LT41-B` 与
///    `overflow_guard_test` / `cli_test` 都在用它们做锚点，改文案不能
///    把同批的锁撞塌。
/// 4. **两种量纲的文案必须不同**：如果实现只是把 `bytes` 删掉，两个分支
///    会撞成同一句话，那就等于没区分。

///|
/// 便利包装：**符号条数量纲**的入口（LT42 新增的变体）。
fn lt42_text(actual : Int32, wanted : Int32) -> String {
  @lib.error_text(@lib.TruncatedSymbolRecords(actual, wanted))
}

///|
/// **LT42-a**：`count` 装不下（符号条数量纲）的文案必须点名 `symbol`。
///
/// 这是缺陷的直接现场：`unpack_container` 在 `count_raw > count_max` 时
/// 传的是**符号条数**，而旧文案说 `bytes`。
test "LT42: the symbol-count branch names symbols, not bytes" {
  let msg = lt42_text(3, 4)
  assert_true(msg.contains("symbol"))
  // 量纲必须写出来：只说 "symbol" 但不说 "3 of 4 symbol(s)" 仍然含糊。
  assert_true(msg.contains("3"))
  assert_true(msg.contains("4"))
  // 锚点子串不能丢（LT41-B 在用 `got {n} of {n+1}`）。
  assert_true(msg.contains("got"))
  assert_true(msg.contains("of"))
  // 量纲词必须出现在数字旁边，不能被 "bytes" 顶替。
  assert_false(msg.contains("bytes"))
}

///|
/// **LT42-b**：字节量纲的分支仍然说 `bytes`。
///
/// `Reader::bytes` 之类传的是真字节数，改成「symbol」会把另一个分支改坏。
test "LT42: the byte branch still reports bytes" {
  let msg = @lib.error_text(@lib.TruncatedSymbol(7, 40))
  assert_true(msg.contains("bytes"))
  assert_true(msg.contains("got"))
  assert_true(msg.contains("expected"))
  // 字节分支**不许**改口径成条数。
  assert_false(msg.contains("symbol(s)"))
}

///|
/// **LT42-c**：两种量纲的文案必须**互不相同**。
///
/// 如果实现只是把 `bytes` 从统一渲染里删掉，两个分支会撞成同一句 ——
/// 那种"修复"等于没区分量纲。这里用同样的 (a,b) 造两遍，要求
/// 两个入口给出的文案不同。
///
/// 现实里调用方无法从 `(a,b)` 反推量纲，所以区分必须发生在**构造函数**
/// 上：`TruncatedSymbol` 保持字节语义（既有 6 个调用点全是字节），
/// 新增一个符号条数专用的变体。这条测试同时锁定"两个入口都存在且不同"。
test "LT42: byte-unit and record-unit truncations render differently" {
  let bytes_msg = @lib.error_text(@lib.TruncatedSymbol(3, 4))
  let records_msg = lt42_text(3, 4)
  assert_true(bytes_msg != records_msg)
}

///|
/// **LT42-d**：`LT41-B` 的锚点仍然成立 —— 符号条数分支必须点名
/// `got {n} of {n+1}` 这一对数值（LT41 就是靠它抓住 `count_max` 差一的）。
test "LT42: the symbol-count branch keeps the numeric anchors LT41-B relies on" {
  for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 4)] {
    let msg = lt42_text(a, b)
    assert_true(msg.contains("got \{a} of \{b} symbol(s)"))
  }
}
