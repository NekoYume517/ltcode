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
/// `encode` / `pack_container` 一次调用的**峰值工作集**。
///
/// LT30（2026-11-21 审计）：容器字节不是峰值。同一次调用里同时活着
/// payload（输入文件）、每个符号的 body（`Encoder::symbols` 的产物）与最终
/// 容器（`pack_container` 的 `out`），于是实测 `--symbols 1 --count 2`
/// 加 500 MiB 输入给出**合法**容器 1,048,576,051 字节、峰值 4009.2 MiB。
///
/// LT47（2026-11-27 审计）：上面那句话是对的，但**公式没有兑现它**。
/// 旧式子是 `payload + 43 + count × (4 + symbol_len)` —— 只数了**一份**
/// 符号区。实测（PSAPI `GetProcessMemoryInfo`，native release）：
///
/// ```text
///   --symbols 1 --count   10000   peak  125.7 MiB   旧声明  38.2 MiB   3.29x
///   --symbols 1 --count   40000   peak  475.6 MiB   旧声明 152.7 MiB   3.11x
///   --symbols 1 --count  100000   peak 1174.7 MiB   旧声明 381.9 MiB   3.08x
///   --symbols 1 --count  268137   peak 3134.0 MiB   旧声明 1023.9 MiB  3.06x
/// ```
///
/// 最后一行是**闸门边界内**的最大取值：闸门放行了它，真实峰值 3134 MiB，
/// 是 `MAX_CONTAINER_BYTES`（1 GiB）的 2.9 倍。**闸门不是堵住了大分配，
/// 而是把可分配量放大了 3 倍。**
///
/// 3 倍的来源是 `Encoder::symbol` 的两块分配：
/// `work: FixedArray[Byte]`（XOR 工作区）与 `Bytes::from_array(work)`
/// （出参，**又拷一份**），再加 `pack_container` 的 `out` 一份：
///
/// ```text
///   payload  +  count × (4 + symbol_len)   ← work（每符号一次）
///            +  count × (4 + symbol_len)   ← Bytes 出参
///            +  count × (4 + symbol_len)   ← pack_container 的 out
/// ```
///
/// 小 `count`（10000 以下）比值更高（3.29x），那是进程基线（约 9 MiB）
/// 被摊薄的效果，不是常数变大；判据只认 3 倍，不去追这个尾巴。
///
/// 三个量都是 Int64：`count`/`symbol_len` 先被 `container_body_bytes`
/// 约束到非负 Int32 域，乘积 ≤ `(2^31-1)×(2^31+3)`，乘以 3 后仍远小于
/// Int64 上限（约 9.2e18），加 `payload`（≤ `2^31-1`）不会先回绕再检查。
pub fn encode_peak_bytes(
  payload_len : Int64,
  count : Int64,
  symbol_len : Int64,
) -> Int64 raise LtError {
  check_nonnegative_int32("payload_len", payload_len, 0L)
  payload_len +
  CONTAINER_HEADER_BYTES +
  3L * container_body_bytes(count, symbol_len)
}

///|
/// `encode` 的峰值闸门：判据是 `encode_peak_bytes`，上限与容器同一个
/// （1 GiB）。**必须在** `SourceBlock::from_bytes` / `Encoder::symbols` /
/// `pack_container` 分配之前调用 —— 拒绝的价值就是一次都不分配。
///
/// LT30 之前 encode 只量 `43 + count × (4 + symbol_len)`，于是 `--count 0`
/// 让这条轴恒等于 43：1.1 GiB 输入照样放行（实测峰值 2219.5 MiB、写出一个
/// 永远读不回的 43 字节头）；`--symbols 1 --count 2` 加 500 MiB 输入则给出
/// 「合法容器」但峰值 4009.2 MiB。峰值轴把它们都拦在同一条判据上。
pub fn check_encode_budget(
  payload_len : Int64,
  count : Int64,
  symbol_len : Int64,
) -> Unit raise LtError {
  let peak = encode_peak_bytes(payload_len, count, symbol_len)
  if peak > MAX_CONTAINER_BYTES {
    raise LtError::ResourceLimitExceeded(
      "encode_peak_bytes",
      peak,
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
