///|
/// LT13（2026-11-17 审计）：`quantize_param` 的**进位规则**是可断言的契约。
///
/// `quantize_param(x) = round(x * 100)`，而 `round` 在中点上**远离零**进位
/// （half-away-from-zero），判据作用在 **binary64 的乘积** `x * 100` 上，
/// 不是十进制的中点。两条都由本测试锁定：
///
/// - `0.005 * 100` 在 binary64 里**恰好**是 `0.5`，half-up 才把它抬到 1。
///   API.md 把可表示域的下界写成 0.005、`quantized_pair_strict` 的严格域也
///   是 `[0.005, …)`，都**建立在 half-up 上**：换成 half-even 这个下界立刻
///   失效（`Encoder::try_new(0.005)` 会变成 `ParamOutOfImage`）。
/// - `0.015 * 100 == 1.5` 同样在中点上，于是 `0.015` 量化为 **2**（不是 1）；
///   而 `1.005 * 100 = 100.49999999999999` 在中点**之下**，于是 1.005 恰好
///   落在 delta 的严格域内（delta_q=100）。同是「结尾带 5」的两个十进制
///   数，一个进位一个不进位 —— 只看十进制会得出相反结论。
///
/// 之前这条语义没有任何断言（HANDOVER §20.5 记为「`round(0.5)` 的 half-up
/// 语义无单独契约锁定」），于是「0.005 可表示」这句文档是一个没人验证过的
/// 声明。
test "LT13: quantization ties go away from zero on the binary64 product" {
  // 恰好落在中点：half-away-from-zero 进位
  assert_eq(quantize_param(0.005), 1)
  assert_eq(quantize_param(0.015), 2)
  assert_eq(quantize_param(0.025), 3)
  assert_eq(quantize_param(0.045), 5)
  // 中点之下（1.005*100 = 100.49999999999999）：向下
  assert_eq(quantize_param(1.005), 100)
  // 中点之上（2.555*100 = 255.50000000000003）：进位到 256，再被钳到 255
  assert_eq(quantize_param(2.555), 255)
  // 负值钳到 0（钳位语义在 quantize_param 一侧，拒绝在 quantized_pair 一侧）
  assert_eq(quantize_param(-1.0), 0)
}

///|
/// 下界 0.005 的可表示性是**可断言**的（不是文档声明）：严格入口接受它、
/// 再小一点都不行。这条是 LT13 的落点 —— 把「half-up 是有契约含义的」
/// 变成一条会红的测试。
test "LT13: the documented floor 0.005 survives into the strict entry" {
  let block = match SourceBlock::from_bytes(Bytes::make(6, b'\x09'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  match Encoder::try_new(block, 1UL, 0.005, 0.5) {
    Ok(_) => ()
    Err(e) => abort("0.005 must be representable: \{error_text(e)}")
  }
  // 0.0049 * 100 = 0.49 → 0 → 越界
  assert_true(
    match Encoder::try_new(block, 2UL, 0.0049, 0.5) {
      Ok(_) => false
      Err(_) => true
    },
  )
}
