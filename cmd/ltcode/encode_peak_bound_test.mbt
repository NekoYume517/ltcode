///|
/// LT30（2026-11-21 审计）：`encode` 的预算轴必须是**峰值工作集**
/// （`payload + 43 + count × (4 + symbol_len)`），不能只是容器字节。
///
/// 修复前 `encode` 只调 `container_bytes_bound_msg(count, symbol_len)`，
/// 于是 `--count 0` 把这条轴钉死在 43 字节：`encode --count 0 --input
/// <1.1 GiB>` 一路放行，实测峰值 RSS 2219.5 MiB、写出 43 字节的头，
/// 而这个头**永远读不回来**（一个符号都没有）。同一族最强的一档是
/// `--symbols 1 --count 2` 加 500 MiB 输入：容器 1,048,576,051 字节
/// 「合法」，峰值 4009.2 MiB。
///
/// 这些断言只用标量跑：守卫的判据全在 Int64 算术里，不需要真造 GB 级输入。

///|
/// 1.1 GiB 输入 + `--count 0`：修复前 msg 为空（放行），现在必须拒，且
/// 文案要点出三条轴（payload / count / symbol_len）和真实公式。
test "LT30: --count 0 does not bypass the encode budget" {
  // K=100 → symbol_len = ceil(1.1 GiB / 100)
  let msg = encode_peak_bound_msg(1_153_433_600, 0, 11_534_336)
  inspect(
    msg,
    content="--payload 1153433600 with --count 0 and symbol_len=11534336 needs 1153433643 bytes of working set (payload + 43 + count x (4 + symbol_len)), above the limit of 1073741824; encode a smaller payload, lower --count, or raise --symbols so that each symbol is shorter",
  )
  // 文档里那条 43 字节的 `--count 0`（4000 字节 payload）必须继续放行。
  inspect(encode_peak_bound_msg(4000, 0, 40), content="")
}

///|
/// 500 MiB payload + `--symbols 1 --count 2`：容器字节合法（1,048,576,051
/// < 1 GiB），峰值却不合法（2,548,576,051）—— 这正是修复前放行的最强一档。
test "LT30: --symbols 1 --count 2 on a 500 MiB payload is rejected by the peak axis" {
  assert_true(!encode_peak_bound_msg(524_288_000, 2, 524_288_000).is_empty())
  // 同样的参数配小 payload（K=1 → symbol_len = payload）必须放行。
  inspect(encode_peak_bound_msg(13_243, 2, 13_243), content="")
  // 默认 count（ceil(1.5K)+1）配 500 MiB 也不再是漏网的：容器 1.57 GB。
  assert_true(!encode_peak_bound_msg(524_288_000, 3, 524_288_000).is_empty())
}

///|
/// 双向核：README / DEMO 里每一条 `encode` 命令的 `(payload, count,
/// symbol_len)` 代进去都必须是空串（守卫不许误伤文档用法）。
test "LT30: every documented encode command fits the peak budget" {
  // README §用法 1：--symbols 100 --count 300
  inspect(encode_peak_bound_msg(4000, 300, 40), content="")
  // README §用法 2（tight）：--symbols 100 --count 100
  inspect(encode_peak_bound_msg(4000, 100, 40), content="")
  // 小 K 表：K=2 → count 4 / symbol_len 2000
  inspect(encode_peak_bound_msg(4000, 4, 2000), content="")
  // 小 K 表：K=4 → count 7 / symbol_len 1000
  inspect(encode_peak_bound_msg(4000, 7, 1000), content="")
  // 小 K 表：K=10 → count 16 / symbol_len 400
  inspect(encode_peak_bound_msg(4000, 16, 400), content="")
  // 小 K 表：K=100 → count 151 / symbol_len 40
  inspect(encode_peak_bound_msg(4000, 151, 40), content="")
}

///|
/// 边界双向：峰值**恰好** 1 GiB 放行，超 1 字节必拒。
test "LT30: peak budget boundary is bidirectional" {
  let limit = 1_073_741_824L
  // count=1、symbol_len=1 → 头部 43 + 5 = 48；payload = limit - 48。
  assert_eq(@lib.encode_peak_bytes(limit - 48L, 1L, 1L), limit)
  inspect(encode_peak_bound_msg((limit - 48L).to_int(), 1, 1), content="")
  assert_eq(@lib.encode_peak_bytes(limit - 47L, 1L, 1L), limit + 1L)
  assert_true(!encode_peak_bound_msg((limit - 47L).to_int(), 1, 1).is_empty())
}
