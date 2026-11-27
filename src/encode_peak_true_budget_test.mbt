///|
/// LT47（2026-11-27 审计）：`check_encode_budget` 的判据**低估实测峰值 3.06 倍**。
///
/// ## 现象（修复前）
///
/// `encode_peak_bytes` 的文档说它是「`encode` / `pack_container` 一次调用的
/// **峰值工作集**」，公式是 `payload + 43 + count × (4 + symbol_len)`。
/// 本轮用 PSAPI `GetProcessMemoryInfo` 逐样本实测（native release，
/// Windows 11，`examples/payload.bin` = 4000 B）：
///
/// ```text
///   --symbols 1 --count   10000   peak  125.7 MiB   声明  38.2 MiB   3.29x
///   --symbols 1 --count   40000   peak  475.6 MiB   声明 152.7 MiB   3.11x
///   --symbols 1 --count  100000   peak 1174.7 MiB   声明 381.9 MiB   3.08x
///   --symbols 1 --count  268000   peak 3131.7 MiB   声明 1023.4 MiB  3.06x
///   --symbols 1 --count  268137   peak 3134.0 MiB   声明 1023.9 MiB  3.06x
/// ```
///
/// 最后一行是**闸门边界内**的最大取值：闸门放行了它，而真实峰值
/// **3134 MiB ≈ 3.06 GiB**。这与 `MAX_CONTAINER_BYTES`（1 GiB）声明的
/// 「峰值预算」相差 2.9 倍 —— 换句话说，这条闸门不是"堵住了大分配"，
/// 而是"把可分配量放大了 3 倍"。
///
/// 小 `count` 时比值更高（125.7/38.2 = 3.29x），但那是进程基线（约 9 MiB）
/// 被摊薄的效果，不是常数因子变大：`count=100000` 起比值稳定在 3.06–3.11。
///
/// ## 根因
///
/// `Encoder::symbol` 每个符号分配两块：`work: FixedArray[Byte]`（XOR 工作区）
/// 与 `Bytes::from_array(work)`（出参，**又拷一份**）。而 `pack_container`
/// 还要为整个符号区再建一份 `out`。于是同一时刻活着的字节数 ≈
/// `payload + 3 × count × (4 + symbol_len)`，不是 1×。
///
/// 公式只数了一份容器，于是判据允许的 `count` 是安全值的 3 倍。
///
/// ## 判据
///
/// 1. `encode_peak_bytes` 必须**至少**是旧公式的 3 倍（守住真实内存布局）。
/// 2. 边界必须仍然**精确**：恰好等于上限时放行，多 1 字节就拒。
/// 3. 300 个符号、40 字节这种文档里的正常命令必须**仍然放行**
///    （否则修复变成了"拒绝一切"，那是另一种坏）。
/// 4. 绝对上界：任何被放行的组合，其声明峰值不得超过 1 GiB。
test "LT47: encode_peak_bytes counts the three live copies, not one" {
  let payload : Int64 = 4000L
  let count : Int64 = 100000L
  let symbol_len : Int64 = 4000L
  let peak = @src.encode_peak_bytes(payload, count, symbol_len) catch {
    e => abort("encode_peak_bytes failed: \{@src.error_text(e)}")
  }
  // 实测比值 3.06–3.11；判据取 3 倍下界（保守）
  assert_true(peak > 3L * (count * (4L + symbol_len)))
  // 精确形状：payload 活一份 + 43 字节头一份 + 三段 count×(4+symbol_len)
  assert_eq(peak, payload + 43L + 3L * count * (4L + symbol_len))
  // 数值锚点：旧公式 400404043，新公式 1201204043（比值 3.00）
  assert_eq(peak, 1_201_204_043L)
}

///|
/// LT47：闸门边界仍然精确（放行 `limit`、拒绝 `limit + 1`）。
///
/// 这条与上一条配对：增加常数因子**不许**顺手把边界变成 `>=` / `>` 混用。
test "LT47: budget boundary is exact under the corrected peak" {
  let limit = 1_073_741_824L
  // 找到声明峰值恰好等于 limit 的 count（symbol_len=1 -> 每符号 5 字节 + 头）
  // peak = payload + 43 + 3*count*5；取 payload 使 peak 精确落在 limit 上
  // 3*count*5 = limit - 43 - payload。令 count = 71_582_785 得 1_073_741_775
  let count : Int64 = 71_582_785L
  let payload : Int64 = limit - 43L - 3L * count * 5L
  assert_true(payload >= 0L)
  let peak = @src.encode_peak_bytes(payload, count, 1L) catch {
    e => abort("encode_peak_bytes failed: \{@src.error_text(e)}")
  }
  assert_eq(peak, limit)
  // 恰好等于上限：放行
  @src.check_encode_budget(payload, count, 1L)
  // 多 1 字节：拒绝
  let result = Ok(@src.check_encode_budget(payload + 1L, count, 1L)) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => abort("peak = limit + 1 was accepted")
    Err(e) =>
      match e {
        @src.ResourceLimitExceeded(name, actual, lim) => {
          assert_eq(name, "encode_peak_bytes")
          assert_eq(actual, limit + 1L)
          assert_eq(lim, limit)
        }
        other => abort("wrong error: \{@src.error_text(other)}")
      }
  }
}

///|
/// LT47：文档里的正常命令必须仍然放行。
///
/// 修复前这几条都能过闸门；改成 3 倍之后**必须**仍然能过 —— 否则就是
/// 用一个过紧的判据换掉了过松的判据，README 里的示例全部失效。
test "LT47: documented encode commands still pass the corrected budget" {
  // README / DEMO 的示例形状：4 KB payload、K=100、300 或 151 个符号
  @src.check_encode_budget(4000L, 300L, 40L)
  @src.check_encode_budget(4000L, 151L, 40L)
  @src.check_encode_budget(4000L, 0L, 40L)
  @src.check_encode_budget(0L, 0L, 1L)
  // 8 MiB 输入、K=1、count=2（LT30 里实测峰值 73.2 MiB 的那条）
  @src.check_encode_budget(8_388_608L, 2L, 8_388_608L)
}
