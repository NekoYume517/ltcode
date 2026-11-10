///|
/// `Reader::bytes` 的长度检查在 `Int32` 上回绕（LT-C，2026-11-10 审计）。
///
/// ## 缺陷形态（修复前）
///
/// ```moonbit
/// if n < 0 || self.pos + n > self.data.length() { ... }
/// ```
///
/// `pos` 已经是 47（头部读完），`n = 0x7FFFFFFF`（头部 `symbol_len` 字段），
/// 于是 `pos + n = 2147483694` 在 Int32 上**回绕成负数** —— 比较恒为
/// false，长度检查被绕过。接着 `FixedArray::make(n, ...)` 试图分配 2GB，
/// 进程直接 `PanicError`：
///
/// ```
/// $ ltcode decode --input slen_huge.ltc --out o.bin
/// PanicError
///     at moonbit_panic
/// exit -1073740791   (0xC0000409)
/// ```
///
/// 对一个**不可信输入**来说，"崩溃"和"报错"不是同一种失败：调用方
/// （脚本、CI、未来的服务）只准备了 0/1/2/3 四个码，崩溃码不在契约里，
/// 而且没有任何可读诊断。
///
/// ## 修法
///
/// 先算差再比：`n > data.length() - pos`。`data.length() - pos` 在
/// `pos <= data.length()` 时恒非负且 ≤ `Int32` 上限，因此与 `n` 的比较
/// 不会回绕。`n < 0` 仍需单独挡（`n` 为负时 `n > 差` 为 false）。
/// 报错里携带的"实得/期望"也改成**剩余字节数 / 请求字节数**，
/// 否则 `pos + n` 在报错路径上又会溢出一次。
///
/// ## 这层与 LT-A 的域校验**都**要留
///
/// 域校验挡的是"字段值离谱"（`symbol_len` 超过文件长度），读取器挡的是
/// "字段值在域内但数据不够"（`count` 声称还剩很多符号，实际数据不够）。
/// 两层都能拦住 0x7FFFFFFF 这一个用例，但漏掉哪一层都会留下一类输入：
/// 只有域校验，`Reader` 仍是任何新调用方的地雷；只有读取器，错误文本就
/// 只会说"截断"而说不出"哪个字段非法"。

///|
/// 把 `unpack_container` 的结论压成一行文本；错误一律渲染成
/// `error_text` 的形式。抽成函数是为了让 `try` 的错误类型显式落到
/// `LtError`（直接在 `catch` 里绑 `e` 会拿到抽象的 `Error`）。
fn unpack_outcome(data : Bytes) -> String raise LtError {
  let c = unpack_container(data)
  "unpacked symbol_len=\{c.symbol_len} symbols=\{c.symbols.length()}"
}

///|
/// 造一个 `symbol_len = 0x7FFFFFFF` 的容器（K=4，单个符号体真实存在）。
fn container_with_huge_symbol_len() -> Bytes {
  let block = sample_block(4, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [
    Symbol::{ index: 0, data: b"\x01\x02", },
    Symbol::{ index: 1, data: b"\x03\x04", },
  ]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  let arr = packed.to_array()
  // 偏移 19..23 是 symbol_len
  arr[19] = b'\x7F'
  arr[20] = b'\xFF'
  arr[21] = b'\xFF'
  arr[22] = b'\xFF'
  Bytes::from_array(arr)
}

///|
/// **核心回归**：`symbol_len = 0x7FFFFFFF` 必须以**分类错误**收场，
/// 而不是 `PanicError`。
///
/// 修复前实测：`PanicError` / `exit -1073740791 (0xC0000409)`。
/// 修复后：要么 `TruncatedSymbol`（读取器守住），要么
/// `InvalidHeaderField`（域校验守住）—— 两者都是可读诊断 + 退出码 3。
test "LT-C: a 0x7FFFFFFF symbol_len yields a classified error, never a panic" {
  let bad = container_with_huge_symbol_len()
  let outcome = unpack_outcome(bad) catch {
    e => "classified: \{error_text(e)}"
  }
  // 绝不能"成功"解出一个 21 亿字节的符号长度
  assert_true(outcome != "unpacked symbol_len=2147483647 symbols=2")
  assert_true(!outcome.contains("Panic"))
  // 诊断必须可读（不是空串，也不是一句 `???`）
  assert_true(outcome.has_prefix("classified: "))
  assert_true(outcome.length() > 20)
}

///|
/// 同一层的**正向边界**：`symbol_len` 恰好等于文件剩余可容纳的值时，
/// 读取器必须正常读到最后一个字节，不能把合法读取也拒掉。
///
/// 这条防止"修回绕"被写成"n >= 剩余就拒绝"那种 off-by-one。
test "LT-C: exact-fit symbol bodies still read successfully" {
  let block = sample_block(2, 3)
  let payload = sample_payload(block)
  // 3 个符号，每个体 3 字节：总量 = 43 + 3*(4+3) = 64
  let symbols : Array[Symbol] = [
    Symbol::{ index: 0, data: b"\x01\x02\x03", },
    Symbol::{ index: 1, data: b"\x04\x05\x06", },
    Symbol::{ index: 2, data: b"\x07\x08\x09", },
  ]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  inspect(packed.length(), content="64")
  let c = unpack_container(packed) catch { _ => abort("exact-fit rejected") }
  inspect(c.symbols.length(), content="3")
  assert_eq(c.symbols[2].data, b"\x07\x08\x09")
}

///|
/// 截断到"最后一个符号体少一个字节"时必须报 `TruncatedSymbol`，
/// 且报出的数字必须是**可理解**的剩余量与请求量（不含回绕后的负数）。
test "LT-C: a body short by one byte reports sane byte counts" {
  let block = sample_block(2, 3)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [Symbol::{ index: 0, data: b"\x01\x02\x03", }]
  let packed = pack_container(block, 1UL, payload, 0.1, 0.5, symbols)
  let cut = packed.clamped_view(end=packed.length() - 1).to_owned()
  try {
    let _ = unpack_container(cut)
    abort("expected TruncatedSymbol")
  } catch {
    TruncatedSymbol(actual, wanted) => {
      // 实得 = 剩余字节（1 字节不够读 3），期望 = 请求的 3 字节
      assert_true(actual >= 0)
      assert_true(wanted > 0)
      // 报错文本里不能出现负数（回绕的痕迹）
      assert_true(!error_text(TruncatedSymbol(actual, wanted)).contains("-"))
    }
    _ => abort("wrong variant for a short body")
  }
}
