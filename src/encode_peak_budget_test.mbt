///|
/// LT30（2026-11-21 审计）：`encode` 的峰值预算算术（`payload + 43 +
/// count × (4 + symbol_len)`）。
///
/// 这里的用例只跑标量与抛错，不申请任何大 buffer：判据必须在
/// `SourceBlock::from_bytes` / `Encoder::symbols` / `pack_container`
/// 之前就给出结论，这正是它的价值。

///|
test "LT30: encode peak = payload + container file bytes" {
  assert_eq(@src.encode_peak_bytes(0L, 0L, 1L), 43L)
  assert_eq(@src.encode_peak_bytes(4000L, 300L, 40L), 17_243L)
  assert_eq(@src.encode_peak_bytes(4000L, 0L, 40L), 4043L)
  // 与容器轴的差就是 payload：同一组 count/symbol_len 下只差 payload 项。
  assert_eq(
    @src.encode_peak_bytes(1_000L, 16L, 250L) -
    @src.container_file_bytes(16L, 250L),
    1_000L,
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
test "LT30: encode peak boundary is exact and bidirectional" {
  let limit = 1_073_741_824L
  @src.check_encode_budget(limit - 48L, 1L, 1L)
  let result = Ok(@src.check_encode_budget(limit - 47L, 1L, 1L)) catch {
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
