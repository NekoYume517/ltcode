///|
/// LT30（2026-11-21 审计）：`encode` 的峰值预算算术。
///
/// 这里的用例只跑标量与抛错，不申请任何大 buffer：判据必须在
/// `SourceBlock::from_bytes` / `Encoder::symbols` / `pack_container`
/// 之前就给出结论，这正是它的价值。
///
/// **LT47（2026-11-27）改过公式**：原来的 `payload + container_file_bytes`
/// 只数了一份符号区，实测峰值是它的 3.06 倍。现在的式子是
/// `payload + 43 + 3 × count × (4 + symbol_len)`。下面这些数值随公式一起
/// 更新 —— 它们不是"放宽到能过"，而是**新公式下的精确值**。
test "LT30/LT47: encode peak = payload + 43 + 3 copies of the symbol area" {
  assert_eq(@src.encode_peak_bytes(0L, 0L, 1L), 43L)
  // 4000 + 43 + 3 × 300 × 44 = 4000 + 43 + 39600
  assert_eq(@src.encode_peak_bytes(4000L, 300L, 40L), 43_643L)
  assert_eq(@src.encode_peak_bytes(4000L, 0L, 40L), 4043L)
  // payload 只活一份：同一组 count/symbol_len 下，峰值与容器轴的差不再是
  // payload，而是 `payload + 2 × 符号区`（多出来的两份是 work 与 out）。
  assert_eq(
    @src.encode_peak_bytes(1_000L, 16L, 250L) -
    @src.container_file_bytes(16L, 250L),
    1_000L + 2L * 16L * 254L,
  )
}

///|
test "LT30: check_encode_budget accepts the documented encode commands" {
  @src.check_encode_budget(4000L, 300L, 40L)
  @src.check_encode_budget(4000L, 0L, 40L)
  @src.check_encode_budget(4000L, 151L, 40L)
  @src.check_encode_budget(0L, 0L, 1L)
}

///|
test "LT30: check_encode_budget rejects both measured blowups" {
  // encode --count 0 --input <1.1 GiB>（修复前放行，峰值 2219.5 MiB）
  let result = Ok(@src.check_encode_budget(1_153_433_600L, 0L, 11_534_336L)) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => abort("1.1 GiB payload with --count 0 accepted")
    Err(e) =>
      match e {
        @src.ResourceLimitExceeded(name, actual, limit) => {
          assert_eq(name, "encode_peak_bytes")
          // payload + 43 + 3 × 0 × symbol_len = 1_153_433_600 + 43
          assert_eq(actual, 1_153_433_643L)
          assert_eq(limit, 1_073_741_824L)
        }
        other => abort("wrong error: \{@src.error_text(other)}")
      }
  }
  // encode --symbols 1 --count 2 --input <500 MiB>（修复前放行，峰值 4009.2 MiB）
  let result = Ok(@src.check_encode_budget(524_288_000L, 2L, 524_288_000L)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
/// LT30 / LT47：峰值闸门的边界精确且双向。
///
/// 新公式是 `payload + 43 + 3 × count × (4 + symbol_len)`。取
/// `count = 1, symbol_len = 1`（符号区 3 × 5 = 15 字节），
/// `payload = limit - 43 - 15` 时**恰好**等于上限 → 放行；
/// `payload + 1` → 拒绝。
test "LT30/LT47: encode peak boundary is exact and bidirectional" {
  let limit = 1_073_741_824L
  let exact_payload = limit - 43L - 15L
  assert_eq(
    @src.encode_peak_bytes(exact_payload, 1L, 1L) catch {
      e => abort("encode_peak_bytes failed: \{@src.error_text(e)}")
    },
    limit,
  )
  @src.check_encode_budget(exact_payload, 1L, 1L)
  let result = Ok(@src.check_encode_budget(exact_payload + 1L, 1L, 1L)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "LT30: encode peak rejects negative and out-of-Int32 scalars" {
  for
    input in [
      (-1L, 1L, 1L), // payload_len < 0
      (0L, -1L, 1L), // count < 0
      (0L, 1L, 0L), // symbol_len < 1
      (0L, 2_147_483_648L, 1L), // count 出 Int32
      (2_147_483_648L, 0L, 1L), // payload_len 出 Int32
    ] {
    let result = Ok(@src.check_encode_budget(input.0, input.1, input.2)) catch {
      e => Err(e)
    }
    assert_true(result is Err(_))
  }
}
