///|
/// LT27（2026-11-20）：container/decode 的资源算术必须在任何大分配前完成。
/// 这些用例只构造标量和 43 字节头，不申请大 buffer。

///|
test "LT27: container body/file sizes use checked Int64 arithmetic" {
  assert_eq(@src.container_body_bytes(0, 1_000_000L), 0L)
  assert_eq(@src.container_file_bytes(0, 1_000_000L), 43L)
  assert_eq(@src.container_body_bytes(100, 40L), 4400L)
  assert_eq(@src.container_file_bytes(100, 40L), 4443L)
  assert_eq(@src.container_body_bytes(1_000_000L, 4L), 8_000_000L)
}

///|
test "LT27: one-gibibyte container boundary is bidirectional" {
  let limit = 1_073_741_824L
  // floor((1 GiB - 43) / 44) = 24_403_222；body 与 file 不能混用。
  assert_eq(@src.container_body_bytes(24_403_222L, 40L), 1_073_741_768L)
  assert_eq(@src.container_file_bytes(24_403_222L, 40L), 1_073_741_811L)
  @src.check_container_budget(24_403_222L, 40L)
  assert_eq(@src.container_file_bytes(24_403_223L, 40L), limit + 31L)
  // 步长 631 能整除 1 GiB - 43，精确覆盖 file == limit。
  assert_eq(@src.container_file_bytes(1_701_651L, 627L), limit)
  @src.check_container_budget(1_701_651L, 627L)
  assert_eq(@src.container_file_bytes(1_701_652L, 627L), limit + 631L)
  let result = Ok(@src.check_container_budget(1_701_652L, 627L)) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => abort("container larger than 1 GiB accepted")
    Err(e) =>
      match e {
        @src.ResourceLimitExceeded(name, actual, actual_limit) => {
          assert_eq(name, "container_bytes")
          assert_eq(actual, limit + 631L)
          assert_eq(actual_limit, limit)
        }
        other => abort("wrong error: \{@src.error_text(other)}")
      }
  }
}

///|
test "LT27: header scalars outside Int32 are rejected before multiplication" {
  for
    input in [
      (2_147_483_648L, 1L),
      (1L, 2_147_483_648L),
      (-1L, 1L),
      (1L, -1L),
      (1L, 0L),
    ] {
    let result = Ok(@src.container_body_bytes(input.0, input.1)) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => abort("out-of-Int32 scalar accepted")
      Err(_) => ()
    }
  }
  // Int32 两个最大值相乘仍可由 Int64 表示，但明显超容器预算。
  let result = Ok(@src.check_container_budget(2_147_483_647L, 2_147_483_647L)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "LT27: subset slot accumulator checks the public CSR Int32 domain" {
  let max = 2_147_483_647L
  assert_eq(@src.checked_subset_slots(max - 1L, 1), max)
  assert_eq(@src.checked_subset_slots(max, 0), max)
  let result = Ok(@src.checked_subset_slots(max, 1)) catch { e => Err(e) }
  match result {
    Ok(_) => abort("subset_slots overflow accepted")
    Err(e) =>
      match e {
        @src.ResourceLimitExceeded(name, actual, limit) => {
          assert_eq(name, "subset_slots")
          assert_eq(actual, 2_147_483_648L)
          assert_eq(limit, max)
        }
        other => abort("wrong error: \{@src.error_text(other)}")
      }
  }
}

///|
test "LT27: decoded output allocation checks Int32 before conversion" {
  assert_eq(@src.checked_allocation_length("decoded_bytes", 43L), 43)
  let result = Ok(
    @src.checked_allocation_length("decoded_bytes", 2_147_483_648L),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
fn resource_test_header(symbol_len : Int32, count : Int32) -> Bytes {
  let out : Array[Byte] = []
  out.append(b"LTC2".to_array())
  out.push(b'\x02')
  out.push(b'\x0a')
  out.push(b'\x32')
  fn push_u32(v : Int32) {
    let u = v.reinterpret_as_uint()
    out.push((u >> 24).to_byte())
    out.push((u >> 16).to_byte())
    out.push((u >> 8).to_byte())
    out.push(u.to_byte())
  }
  fn push_u64(v : UInt64) {
    for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
      out.push((v >> shift).to_byte())
    }
  }
  push_u32(1)
  push_u64(0UL)
  push_u32(symbol_len)
  push_u64(1UL)
  push_u64(0UL)
  push_u32(count)
  Bytes::from_array(out)
}

///|
test "LT27: unpack rejects an over-budget body before reading a symbol" {
  // 只有一个 43 字节头；声明的单个符号体为 1 GiB。旧实现会落入
  // count/截断检查，新实现必须先报告声明资源超限，且不分配符号体。
  let bytes = resource_test_header(1_073_741_824, 1)
  assert_eq(bytes.length(), 43)
  let result = Ok(@src.unpack_container(bytes)) catch { e => Err(e) }
  match result {
    Ok(_) => abort("over-budget container accepted")
    Err(e) =>
      match e {
        @src.ResourceLimitExceeded(name, _, _) =>
          assert_eq(name, "container_bytes")
        other => abort("wrong error: \{@src.error_text(other)}")
      }
  }
}
