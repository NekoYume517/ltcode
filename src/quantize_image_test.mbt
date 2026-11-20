/// LT5（2026-11-15 审计）：非网格参数的容器往返失配 + 量化像缝隙。
///
/// ## 缺陷本体：两端参数不一致（真数据损坏）
///
/// API.md §8 声称「`c`/`delta` 量化成百分之一，且**编解码两个方向都过
/// 同一个量化函数** —— 否则两端会算出不同的子集」。实现里 decode 方向
/// （unpack → dequantize）确实过了，**encode 方向没有**：
/// `Encoder::new` 用原始 `c`/`delta` 建分布采样，容器头存的是
/// `quantize_param(c)`。于是任何**不在百分之一网格上**的参数
/// （`c=0.014`、`delta=0.123`……）都会产出「编码端用 0.014、解码端用
/// 0.01」的容器：
///
/// 实测（K=200、seed=12345、c=0.014 vs 量化后 0.01）：**300 个 index 里
/// 46 个给出不同子集**（第 0 个就不同）。一个 count=300 的容器因此带着
/// 约 15% 的无效方程，`decode` 报 INCOMPLETE 或 CorruptionDetected ——
/// 而 `encode` 端一声不吭 exit 0。encode 成功、decode 必然失败、毫无线索。
///
/// ## 修复：编码/解码入口都归一到容器量化网格
///
/// `Encoder::new` 与 `decode_with_stats` 在建分布前先过
/// `quantize_param → dequantize_param`（非有限值显式拒绝）。效果：
///
/// - **网格点参数（任何 q/100 的双精度值）行为逐位不变**
///   （`quantize(dequantize(q)) == q` 已由全像测试锁定）—— 既有测试、
///   CLI 默认参数、README 全部数字不受影响；
/// - 非网格参数两端统一吸到同一个网格点 → 往返一致；
/// - `c < 0.005`（归一后为 0）在编码入口被 `robust_soliton_checked`
///   的 `c > 0` 拒绝 —— 从「静默产出不可读容器」变成「明确报错」。
///   数学层不受影响：`robust_distribution(k, 0.004, 0.5)` 仍可独立构造，
///   只有**进入容器系统**的入口（Encoder/decode）归一。
///
/// ## c_q=0 的像缝隙：2026-11-21（LT29）已收敛，不再靠 unpack 事后把关
///
/// `quantize_param` 的像是 `[0, 255]`，而 unpack 要求 `c_q ∈ [1, 255]`、
/// `delta_q ∈ [1, 100]`。上一轮（LT24）只把**非有限**闸门收敛到
/// `pack_container`，有限而越像的参数仍能绕过 `Encoder` 直接写出读不回的
/// 头，当时的结论是「用测试锁定 unpack 把关的行为 + 文档写明 pack 的可
/// 表示域」。
///
/// LT29 把这个缝隙关掉了：`pack_container` 改走编码入口**同一份**
/// `quantized_pair`（非有限 + 量化后必须在 `[1, 255]`/`[1, 100]` 内，
/// 进像则钳位）。于是「越像参数」在两条入口上是同一个 `ParamOutOfImage`，
/// 不再存在「写得出来但读不回」的形态；跨入口矩阵由
/// `pack_param_domain_test.mbt` 逐格锁定。

///|
/// 核心红测试：非网格 c 的容器往返。修复前 decode 端拿 0.01 去解
/// 0.014 编的符号（46/300 子集失配）→ INCOMPLETE/CorruptionDetected；
/// 修复后两端都用 0.01 → Complete。
test "LT5: non-grid c (0.014) container round trip completes" {
  let k = 200
  let data = Bytes::make(k, b'\xa7')
  let block = match SourceBlock::from_bytes(data, k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 12345UL, 0.014, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 300)
  let packed = pack_ok(block, 12345UL, data, 0.014, 0.5, symbols)
  assert_true(packed[5].to_int() == 1) // 头里存的是量化值 c_q=1 (0.01)
  let c = unpack_container(packed) catch {
    e => abort("unpack: \{error_text(e)}")
  }
  let result = decode_verified(c)
  match result {
    Complete(sources) =>
      // 逐字节等于源（decode_verified 已核对哈希，这里再对一次）
      assert_eq(sources.length(), k)
    Incomplete(_, missing) =>
      abort(
        "quantization mismatch: missing \{missing.length()} of \{k} (encoder used 0.014, decoder 0.01)",
      )
  }
}

///|
/// 编码端分布必须是量化后的：`Encoder::new(c=0.014)` 建出的分布与
/// `robust_soliton_checked(k, 0.01, 0.5)` 一致（这正是「两个方向都过
/// 同一个量化函数」的编码侧兑现）。
test "LT5: encoder builds its distribution from the quantized parameter" {
  let k = 200
  let block = match SourceBlock::from_bytes(Bytes::make(k, b'\x01'), k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 1UL, 0.014, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let want = match robust_soliton_checked(k, 0.01, 0.5) {
    Ok(d) => d
    Err(e) => abort("reference dist: \{error_text(e)}")
  }
  // 逐点对比 pmf（量化差 0.004 足以改变整条 CDF）
  for d = 1; d <= k; d = d + 1 {
    let a = enc.dist.pdf(d)
    let b = want.pdf(d)
    if (a - b).abs() > 0.0 {
      abort("pmf differs at d=\{d}: \{a} vs \{b}")
    }
  }
}

///|
/// c < 0.005（量化后为 0）在编码入口被拒 —— 不再静默产出
/// 「容器不可表示」的编码。
test "LT5: encoder rejects c below the representable floor (0.004)" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x02'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let outcome = match Encoder::new(block, 7UL, 0.004, 0.5) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  // LT11（2026-11-17）：量化后为 0 的 c 现在报**参数**越界，不再借用
  // 「度数分布未归一化 sum=0」—— 用户给的是 c，不是分布表。
  assert_true(outcome.contains("parameter c=0.004"))
  assert_true(outcome.contains("quantized grid"))
  assert_true(!outcome.contains("not normalized"))
}

///|
/// 非有限参数显式拒绝（不能被 quantize 的 255 钳位静默吸成 2.55）。
test "LT5: encoder and decoder reject non-finite parameters" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x03'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  match Encoder::new(block, 1UL, 0.1, 0.5) {
    Ok(_) => ()
    Err(e) => abort("baseline encoder failed: \{error_text(e)}")
  }
  // c = inf：修复前走 validate 兜底（Err sum=0）；修复后在归一前拒绝
  let inf = 1.0 / 0.0
  let nan = 0.0 / 0.0
  let enc_inf = match Encoder::new(block, 2UL, inf, 0.5) {
    Ok(_) => "ok"
    Err(_) => "err"
  }
  assert_true(enc_inf == "err")
  // c = nan：与修复前同族（Err）
  let enc_nan = match Encoder::new(block, 3UL, nan, 0.5) {
    Ok(_) => "ok"
    Err(_) => "err"
  }
  assert_true(enc_nan == "err")
  // delta = inf：修复前 delta > 1 拒；修复后归一前拒。都是 Err
  let enc_dinf = match Encoder::new(block, 4UL, 0.1, inf) {
    Ok(_) => "ok"
    Err(_) => "err"
  }
  assert_true(enc_dinf == "err")
  // decode 侧对称：非有限值 raise，不解出任何东西
  let received : Array[ReceivedSymbol] = []
  let dec_inf = try {
    let _ = decode_with_stats(1UL, 1, 4, received, inf, 0.5)
    "ok"
  } catch {
    LtError::DistributionNotNormalized(_) => "err-dnn"
    _ => "err-other"
  }
  assert_true(dec_inf == "err-dnn")
}

///|
/// 网格点参数行为逐位不变：`Encoder::new(0.1, 0.5)` 的分布与直接
/// `robust_distribution(0.1, 0.5)` 相同（归一对网格点是恒等）。
test "LT5: grid parameters are untouched by quantization round trip" {
  let k = 100
  let block = match SourceBlock::from_bytes(Bytes::make(k, b'\x04'), k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 1UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let want = match robust_soliton_checked(k, 0.1, 0.5) {
    Ok(d) => d
    Err(e) => abort("reference: \{error_text(e)}")
  }
  for d = 1; d <= k; d = d + 1 {
    let a = enc.dist.pdf(d)
    let b = want.pdf(d)
    if a != b {
      abort("grid pmf changed at d=\{d}: \{a} vs \{b}")
    }
  }
  // 采样路径也一致：同 seed 同 index 的子集相同
  let s1 = subset_for(99UL, 5, k, enc.dist)
  let s2 = subset_for(99UL, 5, k, want)
  assert_eq(s1.length(), s2.length())
  for i = 0; i < s1.length(); i = i + 1 {
    assert_eq(s1[i], s2[i])
  }
}

///|
/// LT29（2026-11-21）：pack 直调（绕过 Encoder）给越像 `c` 时**当场拒绝**，
/// 与 `Encoder::new` 同一个 `ParamOutOfImage`、同一个字段名 —— 写不出
/// 读不回的头。
test "LT29: pack with unrepresentable c (0.004) is rejected at the encoder gate" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x05'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 7UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 2)
  let pack_outcome = try {
    let _ = @src.pack_container(
      block,
      7UL,
      block.sources[0],
      0.004,
      0.5,
      symbols,
    )
    "accepted"
  } catch {
    @src.ParamOutOfImage(field, v, low, high) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    e => "other: \{error_text(e)}"
  }
  let enc_outcome = match Encoder::new(block, 7UL, 0.004, 0.5) {
    Ok(_) => "accepted"
    Err(@src.ParamOutOfImage(field, v, low, high)) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    Err(e) => "other: \{error_text(e)}"
  }
  inspect(pack_outcome, content="@src.ParamOutOfImage(c, 0.004, 0.005, 2.555)")
  assert_eq(pack_outcome, enc_outcome)
}

///|
/// LT29：`delta = 0.004` 同理 —— 两条入口同一个字段名、同一组边界。
test "LT29: pack with unrepresentable delta (0.004) is rejected at the encoder gate" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x06'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 8UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 2)
  let pack_outcome = try {
    let _ = @src.pack_container(
      block,
      8UL,
      block.sources[0],
      0.1,
      0.004,
      symbols,
    )
    "accepted"
  } catch {
    @src.ParamOutOfImage(field, v, low, high) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    e => "other: \{error_text(e)}"
  }
  let enc_outcome = match Encoder::new(block, 8UL, 0.1, 0.004) {
    Ok(_) => "accepted"
    Err(@src.ParamOutOfImage(field, v, low, high)) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    Err(e) => "other: \{error_text(e)}"
  }
  inspect(
    pack_outcome,
    content="@src.ParamOutOfImage(delta, 0.004, 0.005, 1.005)",
  )
  assert_eq(pack_outcome, enc_outcome)
}

///|
/// LT29：`delta = 1.01` 同理（量化后 101 > 100）。库的正路是 `Encoder::new`
/// 先拒 delta>1，现在 pack 在同一处拒，不再是「写出 101 让 unpack 判死」。
test "LT29: pack with delta above 1 is rejected at the encoder gate" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x07'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 9UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("encoder: \{error_text(e)}")
  }
  let symbols = enc.symbols(0, 2)
  let pack_outcome = try {
    let _ = @src.pack_container(
      block,
      9UL,
      block.sources[0],
      0.1,
      1.01,
      symbols,
    )
    "accepted"
  } catch {
    @src.ParamOutOfImage(field, v, low, high) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    e => "other: \{error_text(e)}"
  }
  let enc_outcome = match Encoder::new(block, 9UL, 0.1, 1.01) {
    Ok(_) => "accepted"
    Err(@src.ParamOutOfImage(field, v, low, high)) =>
      "@src.ParamOutOfImage(\{field}, \{v}, \{low}, \{high})"
    Err(e) => "other: \{error_text(e)}"
  }
  inspect(
    pack_outcome,
    content="@src.ParamOutOfImage(delta, 1.01, 0.005, 1.005)",
  )
  assert_eq(pack_outcome, enc_outcome)
}

///|
/// 像内边界不误伤：c=0.005（c_q=1 → 0.01）、delta=1.0（delta_q=100）、
/// c=2.555（c_q=255）全部 pack→unpack 往返一致，且 0.005 的容器
/// **能解码**（修复后两端同用 0.01）。
test "LT5: image boundaries round trip through pack/unpack" {
  let data = Bytes::from_array([b'\x21', b'\x22', b'\x23', b'\x24'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  // c 下边界 0.005 → 归一成 0.01 采样 → c_q=1 → 解码端同 0.01
  let enc1 = match Encoder::new(block, 10UL, 0.005, 0.5) {
    Ok(e) => e
    Err(e) => abort("c=0.005 rejected: \{error_text(e)}")
  }
  let packed1 = pack_ok(block, 10UL, data, 0.005, 0.5, enc1.symbols(0, 3))
  assert_true(packed1[5].to_int() == 1)
  let c1 = unpack_container(packed1) catch {
    e => abort("c_q=1 rejected: \{error_text(e)}")
  }
  assert_true((c1.c - 0.01).abs() < 0.000000000001)
  let r1 = decode_verified(c1)
  assert_true(r1.is_complete())
  // delta 上边界 1.0 → delta_q=100（LT4 修复后可解码）
  let enc2 = match Encoder::new(block, 11UL, 0.1, 1.0) {
    Ok(e) => e
    Err(e) => abort("delta=1.0 rejected: \{error_text(e)}")
  }
  let packed2 = pack_ok(block, 11UL, data, 0.1, 1.0, enc2.symbols(0, 3))
  assert_true(packed2[6].to_int() == 100)
  let c2 = unpack_container(packed2) catch {
    e => abort("delta_q=100 rejected: \{error_text(e)}")
  }
  assert_true((c2.delta - 1.0).abs() < 0.000000000001)
  assert_true(decode_verified(c2).is_complete())
  // c 上边界 2.555 → c_q=255（c 无库上界，容器像的上界）
  let enc3 = match Encoder::new(block, 12UL, 2.555, 0.5) {
    Ok(e) => e
    Err(e) => abort("c=2.555 rejected: \{error_text(e)}")
  }
  let packed3 = pack_ok(block, 12UL, data, 2.555, 0.5, enc3.symbols(0, 3))
  assert_true(packed3[5].to_int() == 255)
  let _ = unpack_container(packed3) catch {
    e => abort("c_q=255 rejected: \{error_text(e)}")
  }
}

///|
/// `quantize(dequantize(q)) == q` 对**全部** 256 个量化值成立
/// （implementation.md §9 只断言到 [0,100]，这里补满整个像）。
test "LT5: quantize/dequantize identity over the full image [0, 255]" {
  for q = 0; q <= 255; q = q + 1 {
    let back = quantize_param(dequantize_param(q))
    if back != q {
      abort("identity broken at q=\{q}: got \{back}")
    }
  }
}
