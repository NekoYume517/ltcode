///|
/// LTC2 容器固定头部：magic 4 + version/c/delta 3 + K/seed/symbol_len/
/// payload_len/payload_hash/count 36。
pub const CONTAINER_HEADER_BYTES : Int64 = 43L

///|
/// 容器完整文件（头部与符号区合计）的既有上限：1 GiB。
pub const MAX_CONTAINER_BYTES : Int64 = 1_073_741_824L

///|
/// Array/FixedArray 的公开索引与长度域，以及 CSR rev 的可表示上限。
pub const MAX_ARRAY_LENGTH : Int64 = 2_147_483_647L

///|
fn check_nonnegative_int32(
  name : String,
  value : Int64,
  minimum : Int64,
) -> Unit raise LtError {
  if value < minimum || value > MAX_ARRAY_LENGTH {
    raise LtError::ResourceLimitExceeded(name, value, MAX_ARRAY_LENGTH)
  }
}

///|
/// `count × (4 + symbol_len)`，只含符号区，不含 43 字节头。
///
/// 两个乘数先约束到非负 Int32 域，因此乘积最多 `(2^31-1)×(2^31+3)`，
/// 仍远小于 Int64 上限；这里不会先回绕再检查。
pub fn container_body_bytes(
  count : Int64,
  symbol_len : Int64,
) -> Int64 raise LtError {
  check_nonnegative_int32("count", count, 0L)
  check_nonnegative_int32("symbol_len", symbol_len, 1L)
  count * (4L + symbol_len)
}

///|
/// 完整 LTC2 文件字节数：`43 + count × (4 + symbol_len)`。
pub fn container_file_bytes(
  count : Int64,
  symbol_len : Int64,
) -> Int64 raise LtError {
  CONTAINER_HEADER_BYTES + container_body_bytes(count, symbol_len)
}

///|
/// 读写共用的完整容器体积闸门。调用方必须在分配、读符号体或写盘前调用。
pub fn check_container_budget(
  count : Int64,
  symbol_len : Int64,
) -> Unit raise LtError {
  let size = container_file_bytes(count, symbol_len)
  if size > MAX_CONTAINER_BYTES {
    raise LtError::ResourceLimitExceeded(
      "container_bytes",
      size,
      MAX_CONTAINER_BYTES,
    )
  }
}

///|
/// 将 `Σ|subset|` 累加到 CSR 槽数。内部始终用 Int64，进入 Int32 长度的
/// `FixedArray` 前验证可表示域，避免 Int32 回绕成负容量。
pub fn checked_subset_slots(
  running : Int64,
  degree : Int32,
) -> Int64 raise LtError {
  if running < 0L || running > MAX_ARRAY_LENGTH || degree < 0 {
    raise LtError::ResourceLimitExceeded(
      "subset_slots",
      running,
      MAX_ARRAY_LENGTH,
    )
  }
  let next = running + degree.to_int64()
  if next > MAX_ARRAY_LENGTH {
    raise LtError::ResourceLimitExceeded("subset_slots", next, MAX_ARRAY_LENGTH)
  }
  next
}

///|
/// 在任何 `Bytes::make` / `FixedArray::make` 的 Int64→Int32 转换前验证长度。
pub fn checked_allocation_length(
  name : String,
  value : Int64,
) -> Int32 raise LtError {
  if value < 0L || value > MAX_ARRAY_LENGTH {
    raise LtError::ResourceLimitExceeded(name, value, MAX_ARRAY_LENGTH)
  }
  value.to_int()
}
