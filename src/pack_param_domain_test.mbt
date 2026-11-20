///|
/// LT29（2026-11-21 审计）：`pack_container` 是 `(c, delta)` 的**第三条写入口**。
///
/// LT24 只把**非有限**闸门收敛到了这里（`non_finite_param`），有限但越像的
/// 参数仍然漏过去：`c = 0.004` → `c_q = 0`、`delta = 0.004` → `delta_q = 0`、
/// `delta = 1.01` → `delta_q = 101`。这些头被 `unpack_container` 明确拒绝，
/// 而同一个 `(c, delta)` 交给 `Encoder::new` 会当场 `ParamOutOfImage` ——
/// 也就是说**两条入口对同一组参数给出相反结论**，且 pack 的那一侧产出的
/// 是「写得出、读不回」的文件（与 LT20/LT23/LT24 同族）。
///
/// 下面两条测试把「同一份判断」变成可执行的断言：
/// 1. 接受/拒绝矩阵逐格一致（`Encoder::new` Ok ⟺ `pack_container` 不 raise）；
/// 2. pack 成功的容器一定 `unpack_container` 得回来，且头里的 `c_q`/`delta_q`
///    落在 unpack 的域内 —— 即「不再产出读不回的文件」。
///
/// 修复前 1 在 6 格上直接变红（0.004 / 0.0 / -1.0 / delta 0.004 / 1.01 / 1000）。

///|
/// `(c, delta)` 矩阵：覆盖网格点、非网格点、像的四个边界与六种越像形态。
fn param_domain_matrix() -> Array[(Double, Double)] {
  [
    (0.1, 0.5), // 默认参数
    (0.014, 0.5), // 非网格、但在像内（归一成 0.01）
    (0.005, 0.5), // c 下边界（0.005*100 恰好进位到 1）
    (2.555, 0.5), // c 上边界（钳位到 255）
    (1000.0, 0.5), // 越界但钳位进像：两条入口都必须接受 2.55
    (0.1, 1.0), // delta 上边界
    (0.004, 0.5), // 越像：c_q = 0
    (0.0, 0.5), // 越像：c_q = 0
    (-1.0, 0.5), // 负数：c_q = 0
    (0.1, 0.004), // 越像：delta_q = 0
    (0.1, 1.01), // 越像：delta_q = 101
    (0.1, 1000.0), // 越像：delta_q = 255
  ]
}

///|
/// 接受/拒绝矩阵：每格必须两入口同结论；pack 成功时头字段必须在 unpack 域内，
/// 且必须读得回来。
test "LT29: pack_container and Encoder::new agree on every (c, delta)" {
  let k = 4
  let data = Bytes::make(k, b'\x5a')
  let block = match @src.SourceBlock::from_bytes(data, k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{@src.error_text(e)}")
  }
  for pair in param_domain_matrix() {
    let (c, delta) = pair
    let label = "(c=\{c}, delta=\{delta})"
    let enc_ok = match @src.Encoder::new(block, 77UL, c, delta) {
      Ok(_) => true
      Err(_) => false
    }
    let packed : Bytes? = Some(
      @src.pack_container(block, 77UL, data, c, delta, []),
    ) catch {
      _ => None
    }
    let pack_ok = packed is Some(_)
    if pack_ok != enc_ok {
      abort(
        "LT29: entries disagree for \{label}: Encoder::new accepted=\{enc_ok}, pack_container accepted=\{pack_ok}",
      )
    }
    if packed is Some(bytes) {
      // pack 说「可以写」时，写出的头必须在 unpack 的域内。
      let c_q = bytes[5].to_int()
      let delta_q = bytes[6].to_int()
      assert_true(c_q >= 1 && c_q <= 255)
      assert_true(delta_q >= 1 && delta_q <= 100)
      let back = @src.unpack_container(bytes) catch {
        e =>
          abort(
            "LT29: pack_container wrote a container it cannot read back \{label}: \{@src.error_text(e)}",
          )
      }
      assert_true(back.k == k)
    }
  }
}

///|
/// 「写得出」必须等于「解得开」：对矩阵里 pack 接受的每一格，用**同一个**
/// 参数造编码器、生成符号、装容器、解回来，必须是 `Complete`。
///
/// K=1 时每个编码符号的度恒为 1，剥皮必然成功 —— 这一格把误差空间压成 0。
test "LT29: every accepted (c, delta) round trips to a complete decode" {
  let k = 1
  let data = Bytes::from_array([b'\x11', b'\x22'])
  let block = match @src.SourceBlock::from_bytes(data, k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{@src.error_text(e)}")
  }
  for pair in param_domain_matrix() {
    let (c, delta) = pair
    let label = "(c=\{c}, delta=\{delta})"
    let enc = match @src.Encoder::new(block, 5UL, c, delta) {
      Ok(e) => e
      Err(_) => continue // 越像格子：pack 也必须拒绝（上面那条已锁）
    }
    let packed = @src.pack_container(
      block,
      5UL,
      data,
      c,
      delta,
      enc.symbols(0, 3),
    ) catch {
      e =>
        abort(
          "LT29: pack rejected an accepted parameter \{label}: \{@src.error_text(e)}",
        )
    }
    let container = @src.unpack_container(packed) catch {
      e => abort("LT29: unpack failed for \{label}: \{@src.error_text(e)}")
    }
    match @src.decode_verified(container) {
      @src.Complete(sources) => assert_true(sources.length() == k)
      @src.Incomplete(_, missing) =>
        abort(
          "LT29: accepted \{label} produced a container whose decode is INCOMPLETE (missing \{missing.length()})",
        )
    }
  }
}
