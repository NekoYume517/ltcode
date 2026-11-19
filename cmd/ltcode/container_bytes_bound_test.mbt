///|
/// LT9（2026-11-17 审计）：`--count` 的量级上限只按**个数**，不看容器字节数。
///
/// `LT_MAX_COUNT = 1_000_000` 的注释依据写「百万符号容器（每符号约 5+
/// 字节，数十 MB）」，而真实公式是 `count × (4 + symbol_len)`，其中
/// `symbol_len = ceil(payload/K)` —— 与输入文件大小成正比。于是 K=1 时
/// 一个 4 KB 的 payload 就让 `symbol_len=4000`，容器是
/// `1e6 × 4004 ≈ 4.1 GB`。
///
/// 实测（release native，4000 字节 payload、`--symbols 1 --count 1000000`）：
/// 60.07 s 仍在跑、RSS **5772 MB**、stdout/stderr 全空 —— 既不报错也不退出，
/// 属于「合法输入 + 大参数」那一族挂死（§17.3-3）。HANDOVER §19.6 早在
/// 2026-11-13 就把这条记成遗留（「`LT_MAX_COUNT` 的上限依据与实测不符，
/// 4 GB 档没真跑」），一直没修。
///
/// 修法：加一条按**字节**的用量上限 `count × (4 + symbol_len) ≤ 1 GiB`
/// （容器 4.1 GB 时实测 RSS 5.8 GB，放大 ≈ 1.4×；1 GiB 容器对应 ≈ 1.4 GB
/// RSS，安全）。判据在 `read_file` 之后、`SourceBlock::from_bytes` 之前，
/// 因此是**立即拒绝且不做任何分配**。
///
/// 红测试先于实现存在：修复前 `container_bytes_bound_msg` 不存在
/// （`moon test` 编译期即红），也没有任何守卫拦住这个组合。
test "LT9: count x (4 + symbol_len) above 1 GiB is rejected" {
  // 4000 字节 payload、K=1 → symbol_len=4000 → 1e6 x 4004 ≈ 4.1 GB
  let msg = container_bytes_bound_msg(1000000, 4000)
  assert_true(!msg.is_empty())
  // 文案必须点名 --count 与真实公式（用户要改的是 count 或 K）
  assert_true(msg.contains("--count"))
  assert_true(msg.contains("symbol_len"))
  // 同一 count 在 4 字节符号下只有 4 MB，必须放行 —— 守卫量是乘积不是个数
  inspect(container_bytes_bound_msg(1000000, 4), content="")
}

///|
/// 边界精确：预算含 43 字节头。`symbol_len=40` 时步长 44，
/// `floor((1073741824 - 43) / 44) = 24403222`。
test "LT9: the 1 GiB boundary is exact" {
  assert_true(container_size_bytes(24403222, 40) == 1073741768L)
  inspect(container_bytes_bound_msg(24403222, 40), content="")
  assert_true(!container_bytes_bound_msg(24403223, 40).is_empty())
  // 步长 631 整除 1 GiB - 43，验证 file == limit 仍放行。
  inspect(container_bytes_bound_msg(1701651, 627), content="")
  assert_true(!container_bytes_bound_msg(1701652, 627).is_empty())
}

///|
/// 零符号容器不受影响：`--count 0` 只写 43 字节头，与 symbol_len 无关
/// （README「`--count 0` 的语义」那条契约必须继续成立）。
test "LT9: the symbol-free container is unaffected" {
  inspect(container_size_bytes(0, 1000000), content="0")
  inspect(container_bytes_bound_msg(0, 1000000), content="")
}

///|
/// README / DEMO 里最大的合法 encode 命令必须继续 exit 0。K 越大符号越
/// 短，所以域内最大用途（K ≈ 1e6、4 字节符号）离上限三个数量级。
test "LT9: documented encode commands stay inside the container budget" {
  // README：4000 字节 + --symbols 100 --count 300 → symbol_len=40
  inspect(container_bytes_bound_msg(300, 40), content="")
  // README：--symbols 10 --seed 3 → default count 16 → symbol_len=400
  inspect(container_bytes_bound_msg(16, 400), content="")
  // README：--symbols 100 --count 100 → symbol_len=40
  inspect(container_bytes_bound_msg(100, 40), content="")
  // 域内最大 K：K=1e6 on 4 MB → symbol_len=4
  inspect(container_bytes_bound_msg(1000000, 4), content="")
  // LT_MAX_COUNT 本身在 4 字节符号下合法
  inspect(container_bytes_bound_msg(1000000, 4), content="")
}
